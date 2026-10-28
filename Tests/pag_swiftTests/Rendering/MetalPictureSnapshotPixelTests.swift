#if os(macOS)
import AppKit
import Metal
import Synchronization
import Testing
@testable import pag_swift

/// Shape内容Picture首次生成、跨帧命中与DisableCache回退的真实窗口drawable金值。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalPictureSnapshotPixelTests {
    /// GPU完成后的播放撤销或显示换代均须拒绝旧提交；卸载清屏还须归零缓存。
    @MainActor @Test func revokedCompletionAndUnloadDoNotKeepPicture() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.wantsLayer = true
        window.contentView = view
        let box = DisplayTargetBox()
        let revoke = Mutex<PlaybackSubmissionGate?>(nil)
        let changeTarget = Mutex(false)
        let changedEpoch = Mutex<UUID?>(nil)
        let generations = Mutex(0)
        let owner = RenderOwner(device: try #require(MTLCreateSystemDefaultDevice()), observe: { event in
            if case .pictureReadyToPublish = event {
                generations.withLock { $0 += 1 }
                // 两种撤销分别落在GPU完成与双锁发布之间，不能被先前的validate掩盖。
                if changeTarget.withLock({ $0 }) {
                    let mutation = box.mailbox.beginMutation()
                    changedEpoch.withLock { $0 = mutation }
                } else {
                    let gate = revoke.withLock { current -> PlaybackSubmissionGate? in
                        defer { current = nil }
                        return current
                    }
                    gate?.revoke()
                }
            }
        })
        do {
            let epoch = try #require(box.mailbox.beginMutation())
            _ = try await owner.prepareTarget(box, mutation: epoch)
            let parent = try #require(view.layer)
            #expect(box.mount(to: parent, mutation: epoch))
            let geometry = try DisplayGeometry(size: PAGSize(width: 360, height: 640), scale: 1)
            #expect(box.resize(to: geometry, mutation: epoch))
            #expect(box.mailbox.finishMutation(epoch, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let first = request(scene, epoch: epoch)
            revoke.withLock { $0 = first.gate }
            await #expect(throws: CancellationError.self) { try await owner.submit(first) }
            #expect(generations.withLock { $0 } == 1)
            #expect(await owner.pictureCacheBytes().retained == 0)
            changeTarget.withLock { $0 = true }
            let second = request(scene, epoch: epoch)
            await #expect(throws: CancellationError.self) { try await owner.submit(second) }
            #expect(generations.withLock { $0 } == 2)
            #expect(await owner.pictureCacheBytes().retained == 0)
            changeTarget.withLock { $0 = false }
            let nextEpoch = try #require(changedEpoch.withLock { $0 })
            #expect(box.mailbox.finishMutation(nextEpoch, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            let third = request(scene, epoch: nextEpoch)
            guard case .submitted = try await owner.submit(third) else {
                Issue.record("两种撤销后的新请求应重新生成Picture")
                return
            }
            #expect(generations.withLock { $0 } == 3)
            #expect(await owner.pictureCacheBytes().retained > 0)
            let fourth = request(scene, epoch: nextEpoch)
            guard case .submitted = try await owner.submit(fourth) else {
                Issue.record("已完成的Picture应再次提交")
                return
            }
            #expect(generations.withLock { $0 } == 3)
            let clear = request(nil, epoch: nextEpoch)
            guard case .cleared = try await owner.submit(clear) else {
                Issue.record("卸载应提交透明清屏")
                return
            }
            let bytes = await owner.pictureCacheBytes()
            #expect(bytes.retained == 0 && bytes.active == 0)
        } catch {
            await box.shutdown()
            window.close()
            throw error
        }
        await box.shutdown()
        window.close()
    }

    /// 生成与清屏请求分别构造完整播放许可，避免测试绕过生产gate。
    private func request(_ scene: PreparedScene?, epoch: UUID) -> PlaybackFrameRequest {
        let gate = PlaybackSubmissionGate()
        let token = PlaybackRequestToken(documentID: scene?.composition.storage.identity,
            compositionRevision: 1, playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
        gate.allow(token)
        return PlaybackFrameRequest(scene: scene, time: .zero, scaleMode: .aspectFit,
                                    token: token, gate: gate, endsPlayback: false)
    }

    /// 0.5单位细线越过相邻八分倍率档时应重建Picture，并保留两种采样路径各自的边缘金值。
    @MainActor @Test func fineLineRebuildsAcrossAdjacentScaleBuckets() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 100, scale: 4)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 4),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let line: [SourceShape] = [
                .rectangle(reversed: false, size: ScenePoint(x: 0.5, y: 80),
                           position: ScenePoint(x: 50, y: 50), roundness: 0),
                .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)
            ]
            let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(line))])
            let scene = try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
            let normal = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 100, height: 100), scale: 4, mode: .none)
            let magnification = try SceneAffine.scale(x: 1.1, y: 1.1)
            let enlargedCommands = try normal.plan.commands.map { command -> FrameCommand in
                switch command {
                case .beginPicture(let picture):
                    return .beginPicture(FramePicture(document: picture.document, source: picture.source,
                        matrix: try picture.matrix.following(magnification)))
                case .shape(let paint):
                    return .shape(FrameShape(layerID: paint.layerID, geometryID: paint.geometryID,
                        matrix: try paint.matrix.following(magnification), material: paint.material,
                        opacity: paint.opacity))
                default:
                    return command
                }
            }
            let enlarged = PreparedFrame(plan: FramePlan(time: normal.plan.time,
                targetBounds: normal.plan.targetBounds, commands: enlargedCommands),
                images: normal.images, shapes: normal.shapes, texts: normal.texts)
            let basePoints = (198...203).map { SIMD2($0, 200) }
            let enlargedPoints = (218...223).map { SIMD2($0, 220) }
            let first = try await owner.pixels(normal, target: target, at: basePoints, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let hit = try await owner.pixels(normal, target: target, at: basePoints, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0 && hit == first)
            let baseFallback = try await owner.pixels(normal, target: target, at: basePoints,
                                                      enablePictures: true, disablePictureCache: true)
            let larger = try await owner.pixels(enlarged, target: target, at: enlargedPoints,
                                                enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let largerFallback = try await owner.pixels(enlarged, target: target, at: enlargedPoints,
                                                        enablePictures: true, disablePictureCache: true)
            let clear = SIMD4<UInt8>.zero
            let opaque = SIMD4<UInt8>(255, 0, 0, 255)
            let baseGold = [clear, opaque, opaque, clear, clear, clear]
            let snapshotGold = [SIMD4<UInt8>(64, 0, 0, 64), SIMD4<UInt8>(222, 0, 0, 222),
                                opaque, SIMD4<UInt8>(17, 0, 0, 17), clear, clear]
            let expandedGold = [SIMD4<UInt8>(26, 0, 0, 26), opaque, opaque,
                                SIMD4<UInt8>(25, 0, 0, 25), clear, clear]
            // 上档先按4.7568倍局部网格覆盖，再线性缩到4.4倍显示；逐draw直接在4.4倍网格覆盖。
            // 因而边缘预乘RGBA不同，不能把DisableCache回退误判成必须与成功快照逐像素相同。
            for (actual, expected) in [(first, baseGold), (baseFallback, baseGold),
                                       (larger, snapshotGold), (largerFallback, expandedGold)] {
                for (pixel, gold) in zip(actual, expected) {
                    for channel in 0..<4 {
                        #expect(abs(Int(pixel[channel]) - Int(gold[channel])) <= 1,
                                "细线实际\(pixel)，独立采样金值\(gold)")
                    }
                }
            }
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 正式Star和语义Shape在快照命中时保持外层、内部组及渐变映射，禁用时恢复逐draw。
    @MainActor @Test func realStarPictureGeneratesHitsAndFallsBack() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Shape Picture pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 360, height: 640, scale: 4)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 360, height: 640), scale: 4),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextDirection.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: 2_000_000),
                targetSize: try PAGSize(width: 360, height: 640), scale: 4, mode: .aspectFit)
            let root = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
                if case .beginGroup(let group) = command, group.layerID == nil { group } else { nil }
            }.first)
            let starAlpha = try #require(frame.plan.commands.compactMap { command -> FrameOpacityGroup? in
                if case .beginOpacityGroup(let group) = command, group.layerID.path == [63] { group } else { nil }
            }.first)
            let paints = frame.plan.commands.compactMap { command -> FrameShape? in
                if case .shape(let paint) = command, paint.layerID.path == [63] { paint } else { nil }
            }
            #expect(paints.count == 2)
            let first = try #require(paints.first)
            let picture = FramePicture(document: scene.composition.storage.identity,
                                       source: first.geometryID.source, matrix: first.matrix)
            // 正式整帧的后续文字会盖住Star细描边；隔离同一生产几何和组，不能放宽金值容差。
            let commands: [FrameCommand] = [.beginGroup(root), .beginOpacityGroup(starAlpha),
                                            .beginPicture(picture)] + paints.map { .shape($0) }
                + [.endPicture, .endOpacityGroup, .endGroup]
            let isolated = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: commands),
                images: [:], shapes: frame.shapes, texts: [:])
            let points = [SIMD2(520, 1400), SIMD2(420, 1344), SIMD2(200, 200)]
            let firstPixels = try await owner.pixels(isolated, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            #expect(await owner.retainedPictureCount == 1)
            let secondPixels = try await owner.pixels(isolated, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0)
            #expect(await owner.retainedPictureCount == 1)
            let fallback = try await owner.pixels(isolated, target: target, at: points,
                                                  enablePictures: true, disablePictureCache: true)
            #expect(await owner.lastPicturePasses == 0)
            let snapshotGold = [SIMD4<UInt8>(79, 65, 122, 127), SIMD4<UInt8>(0, 27, 105, 127), .zero]
            let fallbackGold = [SIMD4<UInt8>(79, 65, 122, 127), SIMD4<UInt8>(40, 60, 166, 191), .zero]
            for (actual, expected) in [(firstPixels, snapshotGold), (secondPixels, snapshotGold),
                                       (fallback, fallbackGold)] {
                for (pixel, gold) in zip(actual, expected) {
                    for channel in 0..<4 {
                        #expect(abs(Int(pixel[channel]) - Int(gold[channel])) <= 1,
                                "正式Shape快照像素\(pixel)，独立金值\(gold)")
                    }
                }
            }

            let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
                scale: .one, rotation: 0, opacity: 128))
            let left = SourceShape.group(StrokeShapeFixtures.transform(), [
                .rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                           position: ScenePoint(x: 30, y: 40), roundness: 0),
                .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)])
            let right = SourceShape.group(StrokeShapeFixtures.transform(), [
                .rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                           position: ScenePoint(x: 50, y: 40), roundness: 0),
                .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)])
            let overlapSource = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1,
                transform: half, content: .shape([left, right]))])
            let overlapScene = try await PreparedScene.prepare(SceneFixtures.build([overlapSource]).composition)
            let overlapFrame = try await FramePlanner.prepare(overlapScene, at: .zero,
                targetSize: try PAGSize(width: 360, height: 640), scale: 4, mode: .none)
            // 100×100源合成在360×640目标居中；4倍像素后把源点(20/40/60,40)映到(600/680/760,1240)。
            let overlapPoints = [SIMD2(600, 1240), SIMD2(680, 1240), SIMD2(760, 1240)]
            let combined = try await owner.pixels(overlapFrame, target: target, at: overlapPoints,
                                                   enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let expanded = try await owner.pixels(overlapFrame, target: target, at: overlapPoints,
                                                   enablePictures: true, disablePictureCache: true)
            #expect(combined == [SIMD4<UInt8>(128, 0, 0, 128), SIMD4<UInt8>(128, 0, 0, 128),
                                 SIMD4<UInt8>(128, 0, 0, 128)])
            #expect(expanded == [SIMD4<UInt8>(128, 0, 0, 128), SIMD4<UInt8>(192, 0, 0, 192),
                                 SIMD4<UInt8>(128, 0, 0, 128)])

            let groupedScene = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.mixedGroup())
            let groupedFrame = try await FramePlanner.prepare(groupedScene, at: .zero,
                targetSize: try PAGSize(width: 360, height: 640), scale: 4, mode: .none)
            let groupedPoints = [SIMD2(584, 1240), SIMD2(600, 1240), SIMD2(680, 1240), SIMD2(540, 1100)]
            let groupedPicture = try await owner.pixels(groupedFrame, target: target, at: groupedPoints,
                                                         enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let groupedFallback = try await owner.pixels(groupedFrame, target: target, at: groupedPoints,
                                                          enablePictures: true, disablePictureCache: true)
            let groupedGold = [SIMD4<UInt8>(128, 0, 0, 128), SIMD4<UInt8>(64, 32, 128, 224),
                               SIMD4<UInt8>(0, 128, 0, 128), .zero]
            #expect(groupedPicture == groupedGold && groupedFallback == groupedGold)

            let turned = SourceTransformProperties(constant: SourceTransform(
                anchor: ScenePoint(x: 50, y: 50), position: ScenePoint(x: 50, y: 50),
                scale: ScenePoint(x: 1.5, y: 1.5), rotation: 15, opacity: 255))
            let gradientSource = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1,
                transform: turned, content: .shape(MetalGradientFixtures.filled(MetalGradientFixtures.material())))])
            let gradientScene = try await PreparedScene.prepare(SceneFixtures.build([gradientSource]).composition)
            let gradientFrame = try await FramePlanner.prepare(gradientScene, at: .zero,
                targetSize: try PAGSize(width: 360, height: 640), scale: 4, mode: .none)
            let gradientPoints = [SIMD2(720, 1280), SIMD2(200, 200)]
            let gradientPicture = try await owner.pixels(gradientFrame, target: target, at: gradientPoints,
                                                          enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let gradientFallback = try await owner.pixels(gradientFrame, target: target, at: gradientPoints,
                                                           enablePictures: true, disablePictureCache: true)
            for (actual, baseline) in zip(gradientPicture, gradientFallback) {
                for channel in 0..<4 {
                    #expect(abs(Int(actual[channel]) - Int(baseline[channel])) <= 2,
                            "渐变局部快照必须保留源paint矩阵")
                }
            }
            #expect(gradientPicture[0].x > 110 && gradientPicture[0].z > 110
                    && gradientPicture[0].y == 0 && gradientPicture[0].w == 255)
            #expect(gradientPicture[1] == .zero)

            let turnedClip = FrameClip(size: try PAGSize(width: 160, height: 160),
                matrix: try SceneAffine.rotation(degrees: 30).following(.translation(x: 640, y: 1200)))
            let clipGroup = FrameGroup(layerID: nil, frame: 0, clip: turnedClip, opacity: 1)
            var clippedCommands = gradientFrame.plan.commands
            clippedCommands.insert(.beginGroup(clipGroup), at: 1)
            clippedCommands.insert(.endGroup, at: clippedCommands.count - 1)
            let clippedFrame = PreparedFrame(plan: FramePlan(time: gradientFrame.plan.time,
                targetBounds: gradientFrame.plan.targetBounds, commands: clippedCommands),
                images: gradientFrame.images, shapes: gradientFrame.shapes, texts: gradientFrame.texts)
            // 第二点落在旋转矩形的AABB内、真实四边形外；Picture绘回仍须由祖先精确裁掉。
            let clippedPoints = [SIMD2(720, 1280), SIMD2(760, 1220)]
            let clippedPicture = try await owner.pixels(clippedFrame, target: target, at: clippedPoints,
                                                         enablePictures: true, revision: 1)
            #expect(await owner.lastPicturePasses == 1)
            let clippedFallback = try await owner.pixels(clippedFrame, target: target, at: clippedPoints,
                                                          enablePictures: true, disablePictureCache: true, revision: 1)
            #expect(clippedPicture == clippedFallback)
            #expect(clippedPicture[0] == gradientPicture[0] && clippedPicture[1] == .zero)
            #expect(!target.mailbox.snapshot.hasLease)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }
}
#endif
