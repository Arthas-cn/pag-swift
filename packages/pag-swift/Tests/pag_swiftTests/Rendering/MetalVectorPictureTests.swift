#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// Vector父快照在真实Metal预算、drawable和外层alpha下的成功/命中/展开边界。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalVectorPictureTests {
    /// 父Vector先建一张局部纹理；DisableCache完整展开两个Solid且不产生Picture借用。
    @Test func parentAllocatesBeforeOriginalDraws() async throws {
        let scene = try await overlappingScene()
        let frame = try await plan(scene)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = MetalVectorPreparationOwner(device: device)
        try await owner.verifyParentAndFallback(frame)
    }

    /// 两个Shape本来各有内容候选；父Vector成功只建立父局部pass，不提前分配子纹理。
    @Test func parentSuccessSkipsChildShapePictures() async throws {
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .shape(shape(at: ScenePoint(x: 25, y: 30),
                                                           color: SceneColor(red: 255, green: 0, blue: 0)))),
            SceneFixtures.layer(11, content: .shape(shape(at: ScenePoint(x: 45, y: 30),
                                                           color: SceneColor(red: 0, green: 0, blue: 255))))
        ])
        let scene = try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
        let frame = try await plan(scene)
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyParentSkipsChildren(frame)
    }

    /// 父保守范围覆盖整屏时明确回退，子Shape仍可建立自己的局部快照。
    @Test func fullTargetParentMissKeepsChildEligibility() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .shape(shape(at: ScenePoint(x: 25, y: 30),
                                                           color: SceneColor(red: 255, green: 0, blue: 0)))),
            SceneFixtures.layer(11, content: .solid(size: size,
                color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let scene = try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
        let frame = try await plan(scene)
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyFullTargetFallback(frame)
    }

    /// 同定义双实例首帧共享父纹理；逐实例隐藏一片同尺寸Solid后必须分出两个内容键。
    @Test func repeatedDefinitionSharesUntilInstanceVisibilityEdit() async throws {
        let size = try PAGSize(width: 30, height: 30)
        let placed = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 20, y: 20), scale: .one, rotation: 0, opacity: 255))
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: placed, content: .solid(size: size,
                color: SceneColor(red: 255, green: 0, blue: 0))),
            SceneFixtures.layer(11, transform: placed, content: .solid(size: size,
                color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let rotation = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 30,
            startValue: 0.0, endValue: 1.0, easing: .linear, spatialCurve: nil)])
        let shifted = SourceTransformProperties(anchor: SourceProperty(constant: .zero),
            position: .combined(SourceProperty(constant: ScenePoint(x: 30, y: 0))),
            scale: SourceProperty(constant: .one), rotation: rotation,
            opacity: SourceProperty(constant: 255))
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, transform: shifted, content: .precomposition(id: 1, startFrame: 0))
        ])
        let file = try SceneFixtures.build([child, root])
        let original = try await plan(PreparedScene.prepare(file.composition))
        var edited = file.composition
        try edited.setVisibility(false, for: PAGLayerID(document: file.storage.identity, path: [21, 10]))
        let changed = try await plan(PreparedScene.prepare(edited))
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifySharedAndEditedInstances(original: original, edited: changed)
    }

    /// 嵌套Vector父成功时只建父；父因整屏Solid回退时更深Vector仍可建自己的纹理。
    @Test func nestedVectorUsesParentFirstAndRestoresChildOnMiss() async throws {
        let small = try PAGSize(width: 12, height: 12)
        let full = try PAGSize(width: 100, height: 100)
        let atLeft = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 20, y: 20), scale: .one, rotation: 0, opacity: 255))
        let atRight = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 35, y: 20), scale: .one, rotation: 0, opacity: 255))
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: atLeft, content: .solid(size: small,
                color: SceneColor(red: 255, green: 0, blue: 0))),
            SceneFixtures.layer(11, transform: atRight, content: .solid(size: small,
                color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let outer = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, content: .solid(size: small,
                color: SceneColor(red: 0, green: 255, blue: 0)))
        ])
        let fullOuter = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, content: .solid(size: full,
                color: SceneColor(red: 0, green: 255, blue: 0)))
        ])
        let file = try SceneFixtures.build([child, outer])
        let fullFile = try SceneFixtures.build([child, fullOuter])
        let parent = try await plan(PreparedScene.prepare(file.composition))
        let missed = try await plan(PreparedScene.prepare(fullFile.composition))
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyNestedParentAndFallback(parent: parent, missed: missed,
            parentIndex: file.storage.rootIndex, childIndex: 0)
    }

    /// 父命中也不能遮蔽错定义、缺终点或子Shape伪造源键，且非法计划不留活动借用。
    @Test func malformedParentAndChildRangesFailBeforeCacheLookup() async throws {
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .shape(shape(at: ScenePoint(x: 25, y: 30),
                                                           color: SceneColor(red: 255, green: 0, blue: 0)))),
            SceneFixtures.layer(11, content: .shape(shape(at: ScenePoint(x: 45, y: 30),
                                                           color: SceneColor(red: 0, green: 0, blue: 255))))
        ])
        let frame = try await plan(PreparedScene.prepare(SceneFixtures.build([source]).composition))
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyMalformedRanges(frame)
    }

    /// 父局部纹理超过独立池上限时只放弃父，较小的子Shape仍可在同帧建立纹理。
    @Test func parentPoolMissStillAllowsChildPicture() async throws {
        let tiny = try PAGSize(width: 10, height: 10)
        let far = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 85, y: 30), scale: .one, rotation: 0, opacity: 255))
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .shape(shape(at: ScenePoint(x: 15, y: 30),
                                                           color: SceneColor(red: 255, green: 0, blue: 0)))),
            SceneFixtures.layer(11, transform: far, content: .solid(size: tiny,
                color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let frame = try await plan(PreparedScene.prepare(SceneFixtures.build([source]).composition))
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyParentPoolMissAndChildSuccess(frame)
    }

    /// 全透明Shape作用域不扩大父边界；只有透明内容时不得借出空父纹理。
    @Test func transparentShapeScopesDoNotCreateEmptyOrOversizedPictures() async throws {
        let broad = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .shape([
                .rectangle(reversed: false, size: ScenePoint(x: 98, y: 98),
                           position: ScenePoint(x: 50, y: 50), roundness: 0),
                .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)])),
            SceneFixtures.layer(11, content: .shape(shape(at: ScenePoint(x: 30, y: 30),
                color: SceneColor(red: 0, green: 0, blue: 255))))
        ])
        let frame = try await plan(PreparedScene.prepare(SceneFixtures.build([broad]).composition))
        let partial = try transparentShape(sourceLayer: 0, in: frame.plan.commands)
        let partialFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: partial),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        let fullyTransparent = try transparentShape(sourceLayer: 1, in: partial)
        let emptyFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: fullyTransparent),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyTransparentScopes(partialFrame, empty: emptyFrame)
    }

    /// 将指定源Shape的完整内容Picture置于零透明度组，保持原始绘制和父Vector标记不变。
    private func transparentShape(sourceLayer: Int, in commands: [FrameCommand]) throws -> [FrameCommand] {
        let shapeIndex = try #require(commands.firstIndex { command in
            if case .shape(let shape) = command { shape.geometryID.source.layer == sourceLayer } else { false }
        })
        guard case .shape(let shape) = commands[shapeIndex] else { return commands }
        let begin = try #require(commands[..<shapeIndex].lastIndex {
            if case .beginPicture = $0 { true } else { false }
        })
        let end = try #require(commands[(shapeIndex + 1)...].firstIndex {
            if case .endPicture = $0 { true } else { false }
        })
        var result = commands
        result.insert(.endOpacityGroup, at: end + 1)
        result.insert(.beginOpacityGroup(FrameOpacityGroup(layerID: shape.layerID, opacity: 0)), at: begin)
        return result
    }

    /// 内容距边界仅1px时真实纹理还需AA余量，父候选必须按分配尺寸拒绝整屏中转。
    @Test func antialiasPaddingCannotTurnNearFullVectorIntoFullFrameCopy() async throws {
        let inset = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 1, y: 1), scale: .one, rotation: 0, opacity: 255))
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: inset, content: .solid(size: PAGSize(width: 98, height: 98),
                color: SceneColor(red: 255, green: 0, blue: 0))),
            SceneFixtures.layer(11, content: .solid(size: PAGSize(width: 2, height: 2),
                color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let frame = try await plan(PreparedScene.prepare(SceneFixtures.build([source]).composition))
        let owner = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyNearFullTargetMiss(frame)
    }

    /// 挂载窗口验证重叠SrcOver金值及旋转/1.2倍实例映射，父命中和逐draw回退各有独立RGBA。
    @MainActor @Test func parentHitAndDisabledFallbackHaveIndependentPixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 100, scale: 1)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let scene = try await overlappingScene()
            let frame = try await plan(scene)
            let point = [SIMD2(50, 35)]
            let first = try await owner.pixels(frame, target: target, at: point, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let hit = try await owner.pixels(frame, target: target, at: point, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0 && hit == first)
            let disabled = try await owner.pixels(frame, target: target, at: point,
                                                  enablePictures: true, disablePictureCache: true)
            #expect(await owner.lastPicturePasses == 0)
            // 源层按逆序展开：蓝底先画、红面后画。快照外层alpha只消费一次。
            let parentGold = SIMD4<UInt8>(128, 0, 0, 128)
            let fallbackGold = SIMD4<UInt8>(128, 0, 64, 191)
            for channel in 0..<4 {
                #expect(abs(Int(first[0][channel]) - Int(parentGold[channel])) <= 2)
                #expect(abs(Int(disabled[0][channel]) - Int(fallbackGold[channel])) <= 2)
            }
            let rotatedScene = try await overlappingScene(rotation: 90,
                scale: ScenePoint(x: 1.2, y: 1.2), position: ScenePoint(x: 90, y: 0))
            let rotated = try await plan(rotatedScene)
            let rotatedPoints = [SIMD2(40, 60), SIMD2(90, 10)]
            let turned = try await owner.pixels(rotated, target: target, at: rotatedPoints,
                                                enablePictures: true, revision: 2)
            #expect(await owner.lastPicturePasses == 1)
            let turnedHit = try await owner.pixels(rotated, target: target, at: rotatedPoints,
                                                   enablePictures: true, revision: 2)
            #expect(await owner.lastPicturePasses == 0 && turnedHit == turned)
            let turnedFallback = try await owner.pixels(rotated, target: target, at: rotatedPoints,
                enablePictures: true, disablePictureCache: true, revision: 2)
            for channel in 0..<4 {
                #expect(abs(Int(turned[0][channel]) - Int(parentGold[channel])) <= 2)
                #expect(abs(Int(turnedFallback[0][channel]) - Int(fallbackGold[channel])) <= 2)
            }
            #expect(turned[1] == .zero && turnedFallback[1] == .zero)

            let clipped = try await plan(ancestorClippedScene())
            let preparation = MetalVectorPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
            try await preparation.verifyTwoDrawVectorParent(clipped)
            let vectorBegin = try #require(clipped.plan.commands.firstIndex {
                if case .beginVectorPicture = $0 { true } else { false }
            })
            let ancestorIndex = try #require(clipped.plan.commands.firstIndex { command in
                if case .beginGroup(let group) = command { group.definitionIndex == 1 } else { false }
            })
            #expect(ancestorIndex < vectorBegin)
            guard case .beginGroup(let ancestor) = clipped.plan.commands[ancestorIndex] else { return }
            let inside = try ancestor.clip.matrix.applying(to: ScenePoint(x: 20, y: 25))
            let outside = try ancestor.clip.matrix.applying(to: ScenePoint(x: 60, y: 25))
            let clipPoints = [SIMD2(Int(inside.x), Int(inside.y)),
                              SIMD2(Int(outside.x), Int(outside.y))]
            let clippedFirst = try await owner.pixels(clipped, target: target, at: clipPoints,
                                                       enablePictures: true, revision: 3)
            #expect(await owner.lastPicturePasses == 1)
            let clippedHit = try await owner.pixels(clipped, target: target, at: clipPoints,
                                                     enablePictures: true, revision: 3)
            #expect(await owner.lastPicturePasses == 0)
            let clippedFallback = try await owner.pixels(clipped, target: target, at: clipPoints,
                enablePictures: true, disablePictureCache: true, revision: 3)
            #expect(clippedFirst == clippedHit)
            #expect(clippedFirst == [SIMD4<UInt8>(255, 0, 0, 255), .zero])
            #expect(clippedFallback == clippedFirst)

            let mixed = try await plan(solidTextScene())
            #expect(mixed.plan.commands.contains { if case .solid = $0 { true } else { false } })
            #expect(mixed.plan.commands.contains { if case .text = $0 { true } else { false } })
            try await preparation.verifyTwoDrawVectorParent(mixed)
            let mixPoints = [SIMD2(25, 25), SIMD2(55, 50), SIMD2(90, 90)]
            let mixFirst = try await owner.pixels(mixed, target: target, at: mixPoints,
                                                  enablePictures: true, revision: 4)
            #expect(await owner.lastPicturePasses == 1)
            let mixHit = try await owner.pixels(mixed, target: target, at: mixPoints,
                                                enablePictures: true, revision: 4)
            #expect(await owner.lastPicturePasses == 0)
            let mixFallback = try await owner.pixels(mixed, target: target, at: mixPoints,
                enablePictures: true, disablePictureCache: true, revision: 4)
            #expect(mixFirst == mixHit && mixFallback == mixFirst)
            #expect(mixFirst[0] == SIMD4<UInt8>(255, 0, 0, 255) && mixFirst[2] == .zero)
            // (55,50)只落在黑色字形的抗锯齿边缘，Solid位于另一处；它不能借红色点蒙混通过。
            #expect(mixFirst[1] == SIMD4<UInt8>(0, 0, 0, 106))
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 正式TextDirection文件经Loader和FramePlanner进入父Vector，窗口drawable验证生成、命中及展开。
    @MainActor @Test func realTextDirectionUsesVectorOnDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
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
                targetSize: PAGSize(width: 360, height: 640), scale: 4, mode: .aspectFit)
            #expect(frame.plan.commands.contains { if case .beginVectorPicture = $0 { true } else { false } })
            let points = [SIMD2(520, 1400), SIMD2(420, 1344), SIMD2(100, 100)]
            let first = try await owner.pixels(frame, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let hit = try await owner.pixels(frame, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0 && hit == first)
            let disabled = try await owner.pixels(frame, target: target, at: points,
                                                  enablePictures: true, disablePictureCache: true)
            #expect(await owner.lastPicturePasses == 0)
            let gold = [SIMD4<UInt8>(79, 65, 122, 127), SIMD4<UInt8>(42, 62, 167, 192), .zero]
            // 首点由Star源fill(159,130,244)和外层127/255得出；边缘点含后续文字覆盖。
            for pixels in [first, hit, disabled] {
                for (actual, expected) in zip(pixels, gold) {
                    for channel in 0..<4 {
                        #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 2,
                                "正式TextDirection完整帧像素\(actual)，固定参照\(expected)")
                    }
                }
            }
            let vectorBegin = try #require(frame.plan.commands.firstIndex {
                if case .beginVectorPicture = $0 { true } else { false }
            })
            let vectorEnd = try #require(MetalVectorPlan.validate(frame).endByBegin[vectorBegin])
            let textIndex = try #require(frame.plan.commands[(vectorBegin + 1)..<vectorEnd].firstIndex {
                if case .text = $0 { true } else { false }
            })
            guard case .text(let originalText) = frame.plan.commands[textIndex] else { return }
            var invalidCommands = frame.plan.commands
            invalidCommands[textIndex] = .text(FrameText(layerID: originalText.layerID,
                resourceID: originalText.resourceID, passIndex: Int.max, matrix: originalText.matrix))
            let invalid = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: invalidCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts)
            // 有已发布的同键父纹理也必须先校验原命令，不能把越界pass当缓存命中跳过。
            await #expect(throws: PAGError.renderingFailure("metalVectorTextIdentity")) {
                try await owner.pixels(invalid, target: target, at: points, enablePictures: true)
            }
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 两片不透明Solid位于40×40局部区域，外部预合成alpha为128/255；可指定实例变换。
    private func overlappingScene(rotation: Double = 0, scale: ScenePoint = .one,
                                  position: ScenePoint = .zero) async throws -> PreparedScene {
        let size = try PAGSize(width: 40, height: 40)
        let red = SceneColor(red: 255, green: 0, blue: 0)
        let blue = SceneColor(red: 0, green: 0, blue: 255)
        let left = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 20, y: 20), scale: .one, rotation: 0, opacity: 255))
        let right = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 40, y: 20), scale: .one, rotation: 0, opacity: 255))
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: left, content: .solid(size: size, color: red)),
            SceneFixtures.layer(11, transform: right, content: .solid(size: size, color: blue))
        ])
        let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: position, scale: scale, rotation: rotation, opacity: 128))
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, transform: half, content: .precomposition(id: 1, startFrame: 0))
        ])
        return try await PreparedScene.prepare(SceneFixtures.build([child, root]).composition)
    }

    /// 动态中间定义不建父快照，内层静态Vector的结果必须被外层45°真实矩形clip裁掉。
    private func ancestorClippedScene() async throws -> PreparedScene {
        let size = try PAGSize(width: 40, height: 40)
        let red = SceneColor(red: 255, green: 0, blue: 0)
        let blue = SceneColor(red: 0, green: 0, blue: 255)
        let left = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 10, y: 10), scale: .one, rotation: 0, opacity: 255))
        let right = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 30, y: 10), scale: .one, rotation: 0, opacity: 255))
        let leaf = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: left, content: .solid(size: size, color: red)),
            SceneFixtures.layer(11, transform: right, content: .solid(size: size, color: blue))
        ])
        let movingRotation = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 30,
            startValue: 0.0, endValue: 1.0, easing: .linear, spatialCurve: nil)])
        let moving = SourceTransformProperties(anchor: SourceProperty(constant: .zero),
            position: .combined(SourceProperty(constant: .zero)), scale: SourceProperty(constant: .one),
            rotation: movingRotation, opacity: SourceProperty(constant: 255))
        let middle = SourceComposition(id: 2, size: try PAGSize(width: 50, height: 50),
            durationFrames: 30, frameRate: 30, background: SceneColor(red: 0, green: 0, blue: 0),
            layers: [SceneFixtures.layer(20, transform: moving,
                                         content: .precomposition(id: 1, startFrame: 0))])
        let rotated = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 45, y: 10), scale: .one, rotation: 45, opacity: 255))
        let root = try SceneFixtures.composition(3, layers: [
            SceneFixtures.layer(30, transform: rotated,
                                content: .precomposition(id: 2, startFrame: 0))
        ])
        return try await PreparedScene.prepare(SceneFixtures.build([leaf, middle, root]).composition)
    }

    /// 一份静态定义同时含Solid与Text，父Vector必须合并两类原绘制并保留禁缓存路径。
    private func solidTextScene() async throws -> PreparedScene {
        let placedSolid = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 20, y: 20), scale: .one, rotation: 0, opacity: 255))
        let placedText = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 50, y: 65), scale: .one, rotation: 0, opacity: 255))
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: placedSolid, content: .solid(
                size: PAGSize(width: 20, height: 20), color: SceneColor(red: 255, green: 0, blue: 0))),
            SceneFixtures.layer(11, transform: placedText, content: .text(try TextFixtures.source("A")))
        ])
        return try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
    }

    /// 使用同一100×100显示网格，避免测试样本把几何倍率差异算作alpha错误。
    private func plan(_ scene: PreparedScene) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: .zero,
                                       targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
    }

    /// 20×20非零路径提供真实GPU网格，而非手工虚构的Shape命令边界。
    private func shape(at center: ScenePoint, color: SceneColor) -> [SourceShape] {
        [.rectangle(reversed: false, size: ScenePoint(x: 20, y: 20), position: center, roundness: 0),
         .fill(color: color, opacity: 255)]
    }
}

/// 系统Metal资源固定在单一测试域，批次只验证准备与释放而不提交GPU。
private actor MetalVectorPreparationOwner {
    /// 独占的真实设备，不将裸Metal对象返回给调用方。
    private let device: any MTLDevice

    /// 接收测试设备所有权，后续缓存/附件都留在此actor中。
    init(device: sending any MTLDevice) { self.device = device }

    /// 同一定义两类图元或祖先裁剪下，父Vector独占一张局部纹理并保留两条原始绘制。
    func verifyTwoDrawVectorParent(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, pictures: resources.pictures)
        #expect(batch.pictureWorks.count == 1)
        #expect(batch.pictureWorks.first?.lease.picture.key.vectorIndex != nil)
        #expect(batch.pictureWorks.first?.batch.passes.last?.draws.count == 2)
        batch.releaseTransients()
        let fallback = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, disablePictureCache: true, pictures: resources.pictures)
        #expect(fallback.pictureWorks.isEmpty)
        fallback.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 核对父级只有一个局部pass且禁用后两个原始Solid直接到根pass。
    func verifyParentAndFallback(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let first = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                                                      resources: resources, pictures: resources.pictures)
        #expect(first.pictureWorks.count == 1)
        #expect(first.passes.last?.draws.count == 1)
        #expect(first.pictureWorks.first?.lease.picture.key.vectorIndex != nil)
        first.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
        let disabled = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, disablePictureCache: true, pictures: resources.pictures)
        #expect(disabled.pictureWorks.isEmpty && disabled.passes.last?.draws.count == 2)
        #expect(disabled.pictureMisses.contains("vectorDisabled"))
        disabled.releaseTransients()
    }

    /// 一份父纹理内直接编码两片Shape，活动表和根pass均不含子Picture。
    func verifyParentSkipsChildren(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, pictures: resources.pictures)
        #expect(batch.pictureWorks.count == 1)
        #expect(batch.pictureWorks.first?.lease.picture.key.vectorIndex != nil)
        #expect(batch.pictureWorks.first?.batch.pictureWorks.isEmpty == true)
        #expect(batch.pictureWorks.first?.batch.passes.last?.draws.count == 2)
        #expect(batch.passes.last?.draws.count == 1)
        batch.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 父整屏防线只放弃父候选，子内容仍能命中并保留根Solid的逐draw结果。
    func verifyFullTargetFallback(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, pictures: resources.pictures)
        #expect(batch.pictureMisses.contains("vectorEmptyOrFullTarget"))
        #expect(batch.pictureWorks.count == 1)
        #expect(batch.pictureWorks.first?.lease.picture.key.vectorIndex == nil)
        #expect(batch.pictureWorks.first?.lease.picture.key.source != nil)
        #expect(batch.passes.last?.draws.count == 2)
        batch.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 没有可见性覆盖时同键pending只有一份；出现路径覆盖后两份相同网格也不能误共用像素。
    func verifySharedAndEditedInstances(original: PreparedFrame, edited: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let first = try MetalFramePreparation.prepare(original, width: 100, height: 100,
            resources: resources, revision: 1, pictures: resources.pictures)
        #expect(first.pictureWorks.count == 1 && first.passes.last?.draws.count == 2)
        #expect(first.pictureWorks.first?.lease.picture.key.vectorInstance == nil)
        first.releaseTransients()
        let changed = try MetalFramePreparation.prepare(edited, width: 100, height: 100,
            resources: resources, revision: 2, pictures: resources.pictures)
        #expect(changed.pictureWorks.count == 2 && changed.passes.last?.draws.count == 2)
        let variants = changed.pictureWorks.compactMap { $0.lease.picture.key.vectorInstance }
        #expect(variants.count == 2 && variants[0] != variants[1])
        changed.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 两层标记可分别替换，父成功跳过子；父拒绝整屏纹理后仍必须保留子候选。
    func verifyNestedParentAndFallback(parent: PreparedFrame, missed: PreparedFrame,
                                       parentIndex: Int, childIndex: Int) throws {
        let resources = try MetalResources(device: device)
        let first = try MetalFramePreparation.prepare(parent, width: 100, height: 100,
            resources: resources, revision: 1, pictures: resources.pictures)
        #expect(first.pictureWorks.count == 1 && first.passes.last?.draws.count == 1,
                "misses \(first.pictureMisses), draws \(String(describing: first.passes.last?.draws.count))")
        #expect(first.pictureWorks.first?.lease.picture.key.vectorIndex == parentIndex,
                "misses \(first.pictureMisses)")
        #expect(first.pictureWorks.first?.batch.pictureWorks.isEmpty == true)
        first.releaseTransients()
        let fallback = try MetalFramePreparation.prepare(missed, width: 100, height: 100,
            resources: resources, revision: 2, pictures: resources.pictures)
        #expect(fallback.pictureMisses.contains("vectorEmptyOrFullTarget"))
        #expect(fallback.pictureWorks.count == 1 && fallback.passes.last?.draws.count == 2)
        #expect(fallback.pictureWorks.first?.lease.picture.key.vectorIndex == childIndex)
        fallback.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 验证父缓存命中之前先检查整段嵌套结构，任何畸形输入均不产生局部纹理。
    func verifyMalformedRanges(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let begin = try #require(frame.plan.commands.firstIndex {
            if case .beginVectorPicture = $0 { true } else { false }
        })
        guard case .beginVectorPicture(let marker) = frame.plan.commands[begin] else { return }
        var wrongDefinition = frame.plan.commands
        wrongDefinition[begin] = .beginVectorPicture(FrameVectorPicture(document: marker.document,
            definitionIndex: marker.definitionIndex + 1, layerID: marker.layerID,
            cacheVariant: marker.cacheVariant, matrix: marker.matrix))
        let wrongFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: wrongDefinition),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalVectorIdentity")) {
            try MetalFramePreparation.prepare(wrongFrame, width: 100, height: 100,
                resources: resources, pictures: resources.pictures)
        }

        var missingEnd = frame.plan.commands
        missingEnd.removeLast()
        let openFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: missingEnd),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalUnbalancedVector")) {
            try MetalFramePreparation.prepare(openFrame, width: 100, height: 100,
                resources: resources, pictures: resources.pictures)
        }

        let pictureIndex = try #require(frame.plan.commands.firstIndex {
            if case .beginPicture = $0 { true } else { false }
        })
        guard case .beginPicture(let picture) = frame.plan.commands[pictureIndex] else { return }
        var wrongChild = frame.plan.commands
        wrongChild[pictureIndex] = .beginPicture(FramePicture(document: picture.document,
            source: SourceLayerReference(composition: picture.source.composition, layer: 999),
            matrix: picture.matrix, content: picture.content))
        let childFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: wrongChild),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalPictureShapeIdentity")) {
            try MetalFramePreparation.prepare(childFrame, width: 100, height: 100,
                resources: resources, pictures: resources.pictures)
        }

        // 即使没有起点，孤立终点也必须在任何绘制或缓存查找前失败。
        let orphan = MetalGroupFixtures.frame([.endVectorPicture])
        #expect(throws: PAGError.renderingFailure("metalUnbalancedVector")) {
            try MetalFramePreparation.prepare(orphan, width: 100, height: 100,
                resources: resources, pictures: resources.pictures)
        }

        // 资源键合法但属于同文档另一源定义时不能贴入当前Vector范围。
        let shapeIndex = try #require(frame.plan.commands.firstIndex {
            if case .shape = $0 { true } else { false }
        })
        guard case .shape(let original) = frame.plan.commands[shapeIndex] else { return }
        let foreignSource = SourceLayerReference(composition: original.geometryID.source.composition + 1,
                                                 layer: original.geometryID.source.layer)
        let foreignID = ShapeGeometryID(document: original.geometryID.document, source: foreignSource,
                                        index: original.geometryID.index)
        var foreignShapes = frame.shapes
        guard let originalGeometry = frame.shapes[original.geometryID] else {
            Issue.record("源Shape几何缺失，无法构造跨定义资源反例")
            return
        }
        foreignShapes[foreignID] = originalGeometry
        var foreignCommands = frame.plan.commands.filter {
            switch $0 { case .beginPicture, .endPicture: false; default: true }
        }
        let foreignIndex = try #require(foreignCommands.firstIndex {
            if case .shape = $0 { true } else { false }
        })
        foreignCommands[foreignIndex] = .shape(FrameShape(layerID: original.layerID,
            geometryID: foreignID, matrix: original.matrix, material: original.material,
            opacity: original.opacity))
        let foreign = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: foreignCommands),
            images: frame.images, shapes: foreignShapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalVectorShapeIdentity")) {
            try MetalFramePreparation.prepare(foreign, width: 100, height: 100,
                resources: resources, pictures: resources.pictures)
        }
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 一个透明Shape和一片可见Shape只建可见局部纹理；全部透明时不借出父资源。
    func verifyTransparentScopes(_ partial: PreparedFrame, empty: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let visible = try MetalFramePreparation.prepare(partial, width: 100, height: 100,
            resources: resources, pictures: resources.pictures)
        #expect(visible.pictureWorks.count == 1)
        #expect(visible.pictureWorks.first?.lease.picture.key.vectorIndex != nil,
                "misses \(visible.pictureMisses), works \(visible.pictureWorks.count)")
        visible.releaseTransients()
        let blank = try MetalFramePreparation.prepare(empty, width: 100, height: 100,
            resources: resources, pictures: resources.pictures)
        #expect(blank.pictureWorks.isEmpty)
        #expect(blank.pictureMisses.contains("vectorEmptyOrFullTarget"))
        blank.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// AA边缘将98×98源范围扩出100×100目标时，只走原始drawable绘制。
    func verifyNearFullTargetMiss(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, pictures: resources.pictures)
        #expect(batch.pictureWorks.isEmpty)
        #expect(batch.pictureMisses.contains("vectorEmptyOrFullTarget"))
        batch.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 用实际allocatedSize设池上限，排除设备页粒度差异对父miss/子成功的影响。
    func verifyParentPoolMissAndChildSuccess(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let begin = try #require(frame.plan.commands.firstIndex {
            if case .beginPicture = $0 { true } else { false }
        })
        let end = try #require(frame.plan.commands[(begin + 1)...].firstIndex {
            if case .endPicture = $0 { true } else { false }
        })
        guard case .beginPicture(let marker) = frame.plan.commands[begin] else { return }
        var budget = try MetalFrameBudget()
        let descriptor = try #require(MetalPictureDescriptor.make(marker,
            commands: frame.plan.commands[(begin + 1)..<end], frame: frame,
            resources: resources, revision: 1, budget: &budget))
        let childLease = try resources.pictures.allocate(descriptor.key, budget: &budget)
        let childCost = childLease.picture.byteCount
        resources.pictures.discard(childLease)
        let parent = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, revision: 1, pictures: resources.pictures)
        let parentCost = try #require(parent.pictureWorks.first?.lease.picture.byteCount)
        #expect(parentCost > childCost)
        parent.releaseTransients()

        let limited = try MetalPictureStore(device: device, activeLimit: childCost, retainedLimit: 0)
        let fallback = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, revision: 2, pictures: limited)
        #expect(fallback.pictureMisses.contains { $0.contains("maximumActiveMetalPictureBytes") })
        #expect(fallback.pictureWorks.count == 1)
        #expect(fallback.pictureWorks.first?.lease.picture.key.source != nil)
        #expect(fallback.passes.last?.draws.count == 2)
        fallback.releaseTransients()
        #expect(limited.activeBytes == 0)
    }
}
#endif
