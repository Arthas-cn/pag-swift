import Foundation
import Metal
import Testing
@testable import pag_swift

/// Shape/Text Picture的同帧共享、双预算与GPU完成前生命周期门禁。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalPicturePreparationTests {
    /// 空文字与完全透明文字不得分配或发布无效内容纹理，原计划仍可正常准备。
    @Test func emptyAndTransparentTextDoNotAllocatePicture() async throws {
        var emptyStyle = try TextFixtures.source("").style
        emptyStyle.text = ""
        var clearStyle = try TextFixtures.source("H").style
        clearStyle.fillColor = try PAGColor(red: 1, green: 0, blue: 0, alpha: 0)
        let positioned = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 25, y: 65), scale: .one, rotation: 0, opacity: 255))
        var frames: [PreparedFrame] = []
        for style in [emptyStyle, clearStyle] {
            let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1,
                transform: positioned, content: .text(try TextFixtures.source(style.text, style: style)))])
            let scene = try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
            frames.append(try await FramePlanner.prepare(scene, at: .zero, targetSize: source.size,
                                                         scale: 1, mode: .none))
        }
        try await MetalPicturePreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
            .verifyNoTextSnapshot(frames)
    }

    /// 同源文本双实例共享首帧局部纹理；错源与乱序pass即使禁用快照也必须拒绝。
    @Test func textInstancesSharePictureAndRejectMalformedRanges() async throws {
        var style = try TextFixtures.source("H").style
        style.fontSize = 40
        style.strokeWidth = 3
        style.strokeColor = try PAGColor(red: 1, green: 0, blue: 0)
        let positioned = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 25, y: 65), scale: .one, rotation: 0, opacity: 255))
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(10, transform: positioned,
            content: .text(try TextFixtures.source("H", style: style)))])
        // 根定义必须非静态，才能单独检验两个子Text内容Picture的pending共享。
        let shifted = try nonStaticPlacement(x: 50)
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, transform: shifted, content: .precomposition(id: 1, startFrame: 0))
        ])
        let scene = try await PreparedScene.prepare(SceneFixtures.build([child, root]).composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: root.size,
                                                   scale: 1, mode: .none)
        let owner = MetalPicturePreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyTextSharedAndFallback(frame)
        let realFile = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let realScene = try await PreparedScene.prepare(realFile.composition)
        let realFrame = try await FramePlanner.prepare(realScene, at: .zero,
            targetSize: realFile.composition.size, scale: 1, mode: .none)
        try await owner.verifyMalformedTextPictureRange(realFrame)
    }

    /// 相同源Shape双实例首帧只生成一个局部pass；尺度档、旋转共享及低预算回退均不污染活动借用。
    @Test func sameFrameInstancesSharePendingTextureAndBudgetMissFallsBack() async throws {
        let shape: [SourceShape] = [
            .rectangle(reversed: false, size: ScenePoint(x: 20, y: 20),
                       position: ScenePoint(x: 30, y: 30), roundness: 0),
            .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)
        ]
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(10, content: .shape(shape))])
        // 根定义必须非静态，才能单独检验两个子Shape内容Picture的pending共享。
        let shifted = try nonStaticPlacement(x: 50)
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, transform: shifted, content: .precomposition(id: 1, startFrame: 0))
        ])
        let scene = try await PreparedScene.prepare(SceneFixtures.build([child, root]).composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: root.size,
                                                   scale: 1, mode: .none)
        let owner = MetalPicturePreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifySharedAndFallback(frame)
        try await owner.verifyDescriptorScaleAndPlacement(frame)
        try await owner.verifyMalformedPictureRangeFails(frame)
    }

    /// 独立活动/保留预算以真实allocatedSize计费，GPU前丢弃、完成后LRU淘汰与清理均不泄漏。
    @Test func pictureStoreTracksActualAllocationAndLRU() async throws {
        try await MetalPicturePreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
            .verifyStoreBudgetAndLRU()
    }

    /// 只在后续帧轻微转动根实例；首帧位置不变，但根不再抢先于子内容建立Vector快照。
    private func nonStaticPlacement(x: Double) throws -> SourceTransformProperties {
        let rotation = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 30,
            startValue: 0.0, endValue: 1.0, easing: .linear, spatialCurve: nil)])
        return SourceTransformProperties(anchor: SourceProperty(constant: .zero),
            position: .combined(SourceProperty(constant: ScenePoint(x: x, y: 0))),
            scale: SourceProperty(constant: .one), rotation: rotation,
            opacity: SourceProperty(constant: 255))
    }
}

/// 每个测试独占裸Metal对象，避免测试并发越过RenderOwner式的隔离域。
private actor MetalPicturePreparationOwner {
    /// 由sending入口转交所有权的系统设备。
    private let device: any MTLDevice

    /// 接收设备，不把MTLTexture返回给测试调用域。
    init(device: sending any MTLDevice) { self.device = device }

    /// 空/透明输入允许有Text命令，但无实际draw时不得建立Picture活动借用。
    func verifyNoTextSnapshot(_ frames: [PreparedFrame]) throws {
        let resources = try MetalResources(device: device)
        for frame in frames {
            let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                resources: resources, pictures: resources.pictures)
            #expect(batch.pictureWorks.isEmpty && batch.passes.last?.draws.isEmpty == true)
            #expect(resources.pictures.activeBytes == 0 && resources.pictures.count == 0)
            batch.releaseTransients()
        }
    }

    /// 对同源文字两份实例核对pending复用和预算失败回退，原始轮次仍留在计划里。
    func verifyTextSharedAndFallback(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        var baseBudget = try MetalFrameBudget()
        let expanded = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, budget: &baseBudget, disablePictureCache: true,
            pictures: resources.pictures)
        #expect(expanded.passes.last?.draws.count == 4 && expanded.pictureWorks.isEmpty)
        #expect(expanded.pictureMisses == ["disabled", "disabled"])
        let baseCost = baseBudget.usedBytes
        expanded.releaseTransients()

        let created = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, revision: 1, pictures: resources.pictures)
        #expect(created.pictureWorks.count == 1 && created.passes.last?.draws.count == 2)
        let lease = try #require(created.pictureWorks.first?.lease)
        #expect(created.passes.last?.draws.allSatisfy { $0.texture === lease.picture.texture } == true)
        created.releaseTransients()
        #expect(resources.pictures.activeBytes == 0)

        // 只比原逐draw多给极小空间，局部纹理分配必miss，但应保留完整四次绘制。
        let constrained = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, maximumBytes: baseCost + 256, revision: 2,
            pictures: resources.pictures)
        defer { constrained.releaseTransients() }
        #expect(constrained.pictureWorks.isEmpty && constrained.passes.last?.draws.count == 4)
        #expect(constrained.pictureMisses.contains { $0.contains("maximumMetalFrameBytes") })
        #expect(resources.pictures.activeBytes == 0)
    }

    /// Text标记与实际源、实例、pass顺序不符时必须传播计划错误，不能伪装成资源miss。
    func verifyMalformedTextPictureRange(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let position = try #require(frame.plan.commands.firstIndex {
            if case .beginPicture = $0 { true } else { false }
        })
        guard case .beginPicture(let picture) = frame.plan.commands[position],
              case .text(let resourceID, let layerID) = picture.content else {
            Issue.record("TEXT04应生成Text Picture标记")
            return
        }
        var wrongSource = frame.plan.commands
        wrongSource[position] = .beginPicture(FramePicture(document: picture.document,
            source: SourceLayerReference(composition: picture.source.composition, layer: 999),
            matrix: picture.matrix, content: picture.content))
        var wrongInstance = frame.plan.commands
        wrongInstance[position] = .beginPicture(FramePicture(document: picture.document,
            source: picture.source, matrix: picture.matrix,
            content: .text(resourceID: resourceID,
                           layerID: PAGLayerID(document: layerID.document, path: [999]))))
        let firstPass = try #require(frame.plan.commands.firstIndex {
            if case .text = $0 { true } else { false }
        })
        var wrongPass = frame.plan.commands
        guard case .text(let pass) = wrongPass[firstPass] else { return }
        wrongPass[firstPass] = .text(FrameText(layerID: pass.layerID, resourceID: pass.resourceID,
                                               passIndex: 1, matrix: pass.matrix))
        var missingPass = frame.plan.commands
        missingPass.remove(at: firstPass)
        for commands in [wrongSource, wrongInstance, wrongPass, missingPass] {
            let malformed = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: commands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts)
            #expect(throws: PAGError.renderingFailure("metalPictureTextIdentity")) {
                try MetalFramePreparation.prepare(malformed, width: 188, height: 32,
                    resources: resources, disablePictureCache: true, pictures: resources.pictures)
            }
        }
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 检查一个源的两份实例首帧pending相同，而可选预算失败不改变基础draw。
    func verifySharedAndFallback(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        var baseBudget = try MetalFrameBudget()
        let expanded = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, budget: &baseBudget, disablePictureCache: true,
            pictures: resources.pictures)
        #expect(expanded.passes.last?.draws.count == 2 && expanded.pictureWorks.isEmpty)
        #expect(expanded.pictureMisses == ["disabled", "disabled"])
        let baseCost = baseBudget.usedBytes
        expanded.releaseTransients()

        let created = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, revision: 1, pictures: resources.pictures)
        #expect(created.pictureWorks.count == 1 && created.passes.last?.draws.count == 2)
        let lease = try #require(created.pictureWorks.first?.lease)
        let root = try #require(created.passes.last)
        #expect(root.draws.allSatisfy { $0.texture === lease.picture.texture })
        #expect(created.pictureWorks[0].batch.passes.last?.draws.count == 1)
        #expect(resources.pictures.activeBytes == lease.picture.byteCount)
        #expect(resources.pictures.count == 0)
        created.releaseTransients()
        #expect(resources.pictures.activeBytes == 0 && resources.pictures.count == 0)

        // 原逐draw帧的完整费用只增加少量空间，远低于一张真实Picture的预付占用。
        let constrained = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources, maximumBytes: baseCost + 256, revision: 2,
            pictures: resources.pictures)
        defer { constrained.releaseTransients() }
        #expect(constrained.pictureWorks.isEmpty && constrained.passes.last?.draws.count == 2)
        #expect(constrained.pictureMisses.contains { $0.contains("maximumMetalFrameBytes") })
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 平移/旋转共享局部内容，跨几何倍率档分键，过小缩放明确miss且不分配纹理。
    func verifyDescriptorScaleAndPlacement(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        var budget = try MetalFrameBudget()
        let original = try #require(frame.plan.commands.compactMap { command -> FramePicture? in
            if case .beginPicture(let picture) = command { picture } else { nil }
        }.first)
        let paints = frame.plan.commands.compactMap { command -> FrameCommand? in
            if case .shape(let paint) = command, paint.geometryID.source == original.source { command } else { nil }
        }
        let contents = ArraySlice(paints)
        let base = FramePicture(document: original.document, source: original.source, matrix: .identity)
        let identity = try #require(MetalPictureDescriptor.make(base, commands: contents, frame: frame,
            resources: resources, revision: 1, budget: &budget))
        let turnedMatrix = try SceneAffine.rotation(degrees: 90).following(.translation(x: 20, y: 50))
        let turned = try #require(MetalPictureDescriptor.make(FramePicture(document: original.document,
            source: original.source, matrix: turnedMatrix), commands: contents, frame: frame,
            resources: resources, revision: 1, budget: &budget))
        #expect(identity.key == turned.key && identity.textureToDisplay != turned.textureToDisplay)
        let larger = try #require(MetalPictureDescriptor.make(FramePicture(document: original.document,
            source: original.source, matrix: .scale(x: 1.08, y: 1.08)), commands: contents,
            frame: frame, resources: resources, revision: 1, budget: &budget))
        #expect(larger.key != identity.key)
        #expect(Double(bitPattern: larger.key.scaleBits) >= 1.08)
        let tiny = try MetalPictureDescriptor.make(FramePicture(document: original.document,
            source: original.source, matrix: .scale(x: 0.0005, y: 0.0005)), commands: contents,
            frame: frame, resources: resources, revision: 1, budget: &budget)
        #expect(tiny == nil)
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 错误源键或混入Solid的Picture范围必须作为非法计划失败，不能被可选资源回退吞掉。
    func verifyMalformedPictureRangeFails(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let position = try #require(frame.plan.commands.firstIndex {
            if case .beginPicture = $0 { true } else { false }
        })
        guard case .beginPicture(let picture) = frame.plan.commands[position] else {
            Issue.record("未找到生产Picture标记")
            return
        }
        var wrongSource = frame.plan.commands
        wrongSource[position] = .beginPicture(FramePicture(document: picture.document,
            source: SourceLayerReference(composition: picture.source.composition, layer: 999),
            matrix: picture.matrix))
        let wrongFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: wrongSource),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalPictureShapeIdentity")) {
            try MetalFramePreparation.prepare(wrongFrame, width: 100, height: 100, resources: resources)
        }
        var mixed = frame.plan.commands
        mixed.insert(try MetalGroupFixtures.solid(), at: position + 1)
        let mixedFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: mixed),
            images: frame.images, shapes: frame.shapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalPictureUnexpectedCommand")) {
            try MetalFramePreparation.prepare(mixedFrame, width: 100, height: 100, resources: resources)
        }
        #expect(resources.pictures.activeBytes == 0)
    }

    /// 活动占用不因重复丢弃变负；留存上限淘汰最久使用的真实纹理。
    func verifyStoreBudgetAndLRU() throws {
        let document = try DocumentIdentity(data: Data("picture LRU".utf8))
        let source = SourceLayerReference(composition: 0, layer: 0)
        let first = MetalPictureKey(document: document, source: source, textResource: nil, revision: 1,
                                    scaleBits: 1.0.bitPattern, originX: 0, originY: 0,
                                    width: 10, height: 10)
        let second = MetalPictureKey(document: document, source: source, textResource: nil, revision: 2,
                                     scaleBits: 1.0.bitPattern, originX: 0, originY: 0,
                                     width: 10, height: 10)
        let third = MetalPictureKey(document: document, source: source, textResource: nil, revision: 3,
                                    scaleBits: 1.0.bitPattern, originX: 0, originY: 0,
                                    width: 10, height: 10)
        var budget = try MetalFrameBudget()
        let probe = try MetalPictureStore(device: device)
        let measured = try probe.allocate(first, budget: &budget)
        let cost = measured.picture.byteCount
        #expect(cost >= measured.picture.texture.allocatedSize + 512)
        probe.discard(measured)
        let store = try MetalPictureStore(device: device, activeLimit: cost, retainedLimit: cost * 2)
        let one = try store.allocate(first, budget: &budget)
        #expect(store.activeBytes == cost && store.count == 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumActiveMetalPictureBytes")) {
            try store.allocate(second, budget: &budget)
        }
        store.discard(one)
        store.discard(one)
        #expect(store.activeBytes == 0)
        let a = try store.allocate(first, budget: &budget)
        store.publish(a)
        let b = try store.allocate(second, budget: &budget)
        store.publish(b)
        #expect(store.count == 2 && store.retainedBytes == cost * 2)
        var hitBudget = try MetalFrameBudget()
        #expect(try store.lookup(first, budget: &hitBudget)?.texture === a.picture.texture)
        let c = try store.allocate(third, budget: &budget)
        store.publish(c)
        #expect(store.count == 2 && store.retainedBytes == cost * 2)
        #expect(try store.lookup(second, budget: &hitBudget) == nil)
        #expect(try store.lookup(first, budget: &hitBudget) != nil)
        store.clear()
        #expect(store.count == 0 && store.retainedBytes == 0 && store.activeBytes == 0)
    }
}
