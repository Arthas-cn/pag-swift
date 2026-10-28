import Foundation
import Testing
@testable import pag_swift

/// bitmap 素材基底的覆盖、随机 seek、不可变保活、有限缓存和共同计划集成。
struct BitmapFrameTests {
    /// 四个完整样例的所选序列逐帧重建都成功，缓存始终只有一幅基底；不只验证首末帧。
    @Test(arguments: ["RootLayerBitmap.pag", "RootLayerBitmapFreeze.pag", "RootLayerBitmapOffset.pag", "small.pag"])
    func decodesEverySelectedRealBitmapFrame(_ name: String) async throws {
        let source = try await sequence(name)
        let store = BitmapFrameStore()
        for index in source.frames.indices {
            let image = try await store.frame(for: source, at: index)
            #expect(image.storage.pixels.count == source.byteCount)
            #expect(image.storage.identity == (try source.imageIdentity(at: index)))
            #expect(await store.retainedBytes() == source.byteCount)
        }
    }

    /// 首帧矩形外保持透明，矩形内与真实 WebP 解码一致；下一帧透明像素必须覆盖而非混合。
    @Test func reconstructsTransparentPatchesWithoutChangingOldFrame() async throws {
        let source = try await sequence("RootLayerBitmap.pag")
        let store = BitmapFrameStore()
        let first = try await store.frame(for: source, at: 0)
        let oldBytes = first.storage.pixels
        let patch = try #require(source.frames[0].patches.first)
        let decoded = try await PAGImage.load(data: patch.data)
        #expect(first.storage.pixels.prefix(patch.y * source.width * 4).allSatisfy { $0 == 0 })
        let start = (patch.y * source.width + patch.x) * 4
        #expect(first.storage.pixels[start..<(start + patch.width * 4)] == decoded.storage.pixels.prefix(patch.width * 4))
        let second = try await store.frame(for: source, at: 1)
        let nextPatch = try #require(source.frames[1].patches.first)
        let next = try await PAGImage.load(data: nextPatch.data)
        for y in 0..<nextPatch.height {
            let input = y * nextPatch.width * 4
            let output = ((y + nextPatch.y) * source.width + nextPatch.x) * 4
            #expect(second.storage.pixels[output..<(output + nextPatch.width * 4)]
                    == next.storage.pixels[input..<(input + nextPatch.width * 4)])
        }
        #expect(first.storage.pixels == oldBytes)
        #expect(first.storage.identity != second.storage.identity)
        #expect(await store.retainedBytes() == source.byteCount)
        // 语义测试：把真实文件里的透明1×1矩形移到已知有色像素上；不拼接或声称新的 PAG 字节有效。
        let freeze = try await sequence("RootLayerBitmapFreeze.pag")
        let empty = try #require(freeze.frames[1].patches.first)
        let opaque = try #require(stride(from: 3, to: oldBytes.count, by: 4).first { oldBytes[$0] > 0 }) / 4
        let eraser = SourceBitmapPatch(x: opaque % source.width, y: opaque / source.width,
                                      width: 1, height: 1, data: empty.data)
        let semantic = SourceBitmapSequence(identity: try DocumentIdentity(data: Data("bitmap overwrite semantics".utf8)),
            width: source.width, height: source.height, frameRate: source.frameRate,
            frames: [source.frames[0], SourceBitmapFrame(isKeyframe: false, patches: [eraser])],
            starts: [0, 0], maximumPatchBytes: source.maximumPatchBytes)
        let erased = try await store.frame(for: semantic, at: 1)
        #expect(erased.storage.pixels[opaque * 4 + 3] == 0)
    }

    /// 跨关键帧前进、倒退再前进与冷启动同帧一致；旧素材引用不能被新帧覆盖。
    @Test func seeksAcrossKeysAndReusesExactFrame() async throws {
        let source = try await sequence("RootLayerBitmap.pag")
        let store = BitmapFrameStore()
        for index in [0, 1, 60, 61, 130, 239, 59, 2] {
            let actual = try await store.frame(for: source, at: index)
            let cold = try await BitmapFrameStore().frame(for: source, at: index)
            #expect(actual.storage.pixels == cold.storage.pixels, "序列帧 \(index)")
            let hit = try await store.frame(for: source, at: index)
            #expect(hit.storage === actual.storage)
        }
    }

    /// 冻结序列在计划阶段折叠采样身份；根合成没有人工 image layer，尺寸与裁剪来自共同计划。
    @Test func frozenBitmapSharesInputAcrossRootTimes() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "RootLayerBitmapFreeze.pag"))
        // 文件还包含外层 vector 合成；直接使用已解码的原始 bitmap 源，单独验收根 bitmap 合同。
        let root = try SceneFixtures.build([#require(file.storage.compositions.first)])
        let scene = try await PreparedScene.prepare(root.composition)
        let first = try await plan(scene, frame: 0)
        let last = try await plan(scene, frame: 239)
        let a = try #require(first.images.values.first)
        let b = try #require(last.images.values.first)
        #expect(a.storage === b.storage)
        #expect(first.plan.commands.count == 3 && last.plan.commands.count == 3)
        guard case .image(let command) = first.plan.commands[1] else {
            Issue.record("bitmap 根合成未形成输入图像命令")
            return
        }
        #expect(command.layerID == nil)
        #expect(command.matrix == .identity)
        #expect(command.opacity == 1)
        #expect(root.storage.rootLayers.isEmpty)
    }

    /// 同一序列被两个预合成实例采样到不同时刻，必须保留两个稳定输入，不能共享可变画布。
    @Test func differentInstanceTimesKeepSeparateInputs() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "RootLayerBitmap.pag"))
        let bitmap = try #require(file.storage.compositions.first)
        let layers = [
            SceneFixtures.layer(901, duration: 240, content: .precomposition(id: bitmap.id, startFrame: 0)),
            SceneFixtures.layer(902, duration: 240, content: .precomposition(id: bitmap.id, startFrame: -10))
        ]
        let root = SourceComposition(id: 1000, size: bitmap.size, durationFrames: 240, frameRate: 24,
                                     background: bitmap.background, layers: layers)
        let nested = try SceneFixtures.build([bitmap, root])
        let scene = try await PreparedScene.prepare(nested.composition)
        let result = try await plan(scene, frame: 15)
        #expect(result.images.count == 2)
        let source = try #require(bitmap.bitmap?.sequences.last)
        #expect(result.images[try source.imageIdentity(at: 15)] != nil)
        #expect(result.images[try source.imageIdentity(at: 25)] != nil)
        let again = try await plan(scene, frame: 15)
        for (id, image) in result.images { #expect(image.storage.pixels == again.images[id]?.storage.pixels) }
    }

    /// 超限和已经取消的采样不能破坏已有完整基底；计划在分配多输入之前也检查保活预算。
    @Test func rejectsBudgetAndCancellationWithoutReplacingBase() async throws {
        let source = try await sequence("RootLayerBitmap.pag")
        let small = BitmapFrameStore(maximumBytes: 1)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumBitmapFrameBytes")) {
            try await small.frame(for: source, at: 0)
        }
        #expect(await small.retainedBytes() == 0)
        let store = BitmapFrameStore()
        let first = try await store.frame(for: source, at: 0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.frame(for: source, at: 1)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.frame(for: source, at: 0).storage === first.storage)
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "RootLayerBitmap.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size, scale: 1, mode: .none, maximumBytes: 1024)
        }
    }

    /// 多序列访问的缓存只保留至多四个基底，且同一素材不为每个请求积累历史帧。
    @Test func evictsOldSequencesWithinWorkingBudget() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "small.pag"))
        let variants = try #require(file.storage.compositions.first?.bitmap?.sequences)
        let store = BitmapFrameStore(maximumBytes: 32 * 1024 * 1024)
        for source in variants { _ = try await store.frame(for: source, at: 0) }
        let root = try await sequence("RootLayerBitmap.pag")
        _ = try await store.frame(for: root, at: 0)
        let expected = variants.dropFirst().reduce(root.byteCount) { $0 + $1.byteCount }
        #expect(await store.retainedBytes() == expected)
        _ = try await store.frame(for: root, at: 1)
        #expect(await store.retainedBytes() == expected)
        let largeVariant = try #require(variants.last)
        let working = root.byteCount * 2 + root.maximumPatchBytes * 3
        let constrained = BitmapFrameStore(maximumBytes: working)
        _ = try await constrained.frame(for: largeVariant, at: 0)
        _ = try await constrained.frame(for: root, at: 0)
        // 当前重建正好占完预算时，即使条目数没满，也必须先淘汰另一条序列。
        #expect(await constrained.retainedBytes() == root.byteCount)
    }

    /// 系统解码失败时仍保留之前成功的基底，下一次同帧可命中；坏输入不能混进后续增量帧。
    @Test func failedPatchDoesNotReplacePreviousImage() async throws {
        let source = try await sequence("RootLayerBitmap.pag")
        let store = BitmapFrameStore()
        let original = try await store.frame(for: source, at: 0)
        let patch = try #require(source.frames[1].patches.first)
        var bytes = patch.data
        bytes[0] = 0
        let damaged = SourceBitmapPatch(x: patch.x, y: patch.y, width: patch.width, height: patch.height, data: bytes)
        var frames = source.frames
        frames[1] = SourceBitmapFrame(isKeyframe: false, patches: [damaged])
        // 明确的内部故障注入：保留同一缓存键，破坏待解码帧，不把它发布成合法 PAG 文档。
        let invalid = SourceBitmapSequence(identity: source.identity, width: source.width, height: source.height,
            frameRate: source.frameRate, frames: frames, starts: source.starts, maximumPatchBytes: source.maximumPatchBytes)
        await #expect(throws: PAGError.self) { try await store.frame(for: invalid, at: 1) }
        #expect(try await store.frame(for: source, at: 0).storage === original.storage)
        #expect(await store.retainedBytes() == source.byteCount)
    }

    /// 序列帧率不等于合成帧率时，半帧向远离零方向取整，末端钳制到实际序列末帧。
    @Test func sequenceTimeUsesRoundedRateAndEndClamp() async throws {
        let source = try await sequence("RootLayerBitmap.pag")
        let slower = SourceBitmapSequence(identity: source.identity, width: source.width, height: source.height,
            frameRate: 12, frames: source.frames, starts: source.starts, maximumPatchBytes: source.maximumPatchBytes)
        let bitmap = try SourceBitmapComposition(sequences: [slower], frameRate: 24)
        #expect(try bitmap.frameIndex(at: 0, frameRate: 24) == 0)
        #expect(try bitmap.frameIndex(at: 1, frameRate: 24) == 1)
        #expect(try bitmap.frameIndex(at: 2, frameRate: 24) == 1)
        #expect(try bitmap.frameIndex(at: 477, frameRate: 24) == 239)
        #expect(try bitmap.frameIndex(at: 1_000, frameRate: 24) == 239)
    }

    /// 从真实已完整载入文件获得所选源序列，不手写二进制布局。
    private func sequence(_ name: String) async throws -> SourceBitmapSequence {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        return try #require(file.storage.compositions.first?.bitmap?.sequences.last)
    }

    /// 使用真实根帧率生成时间请求，直接复用共同计划入口。
    private func plan(_ scene: PreparedScene, frame: Int64) async throws -> PreparedFrame {
        let source = scene.composition.storage.compositions[scene.composition.storage.rootIndex]
        let time = try SceneValidator.time(frame: frame, rate: source.frameRate)
        return try await FramePlanner.prepare(scene, at: time, targetSize: source.size, scale: 1, mode: .none)
    }
}
