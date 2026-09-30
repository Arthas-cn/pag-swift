import CoreMedia
import Testing
import VideoToolbox
@testable import pag_swift

/// 真实视频内容的纯值计划、媒体owner与语义实例关系；不构造合法PAG二进制。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "需要H.264硬件解码"), .timeLimit(.minutes(1)))
struct VideoPlanningTests {
    /// 八个完整视频文件在首帧、中点、末帧都有有效视频输入，不能只靠独立子合成证明计划支持。
    @Test(arguments: ["RootLayerVideo.pag", "RootLayerVideoFreeze.pag", "RootLayerVideoOffset.pag",
                      "MultiVideoSequence.pag", "MultiVideoSequenceOffset.pag", "data_video.pag",
                      "particle_video.pag", "jisha.pag"])
    func plansCompleteVideoDocuments(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = file.storage.compositions[file.storage.rootIndex]
        for frame in [0, root.durationFrames / 2, root.durationFrames - 1] {
            let prepared = try await VideoPlanningFixtures.plan(scene, frame: frame)
            #expect(!prepared.videos.isEmpty)
            #expect(prepared.plan.commands.contains { if case .video = $0 { true } else { false } })
        }
    }

    /// 冻结区间折叠为同一实际PTS，根视频只有合成组和视频命令，没有人工图片层。
    @Test func frozenRootKeepsOneMediaFrame() async throws {
        let source = try await PAGVideoFixtures.source(in: "RootLayerVideoFreeze.pag")
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let first = try await VideoPlanningFixtures.plan(scene, frame: 0)
        let last = try await VideoPlanningFixtures.plan(scene, frame: 239)
        #expect(first.plan.commands.count == 3 && last.plan.commands.count == 3)
        let initial = try #require(first.videos.values.first), final = try #require(last.videos.values.first)
        #expect(initial.identity == final.identity && initial.identity.frame == 0)
        #expect(first.images.isEmpty && file.storage.rootLayers.isEmpty)
        #expect(await scene.videos?.decodedSampleCount == 1)
        guard case .video(let command) = last.plan.commands[1] else {
            Issue.record("根视频没有进入共同视频命令")
            return
        }
        #expect(command.layerID == nil && command.opacity == 1 && command.matrix == .identity)
    }

    /// 同序列三个实例的两个采样时刻保留两份独立输入，同PTS只请求一次，不改写较早的输入。
    @Test func instanceTimesDeduplicateOnlyEqualFrames() async throws {
        let file = try await VideoPlanningFixtures.nested(starts: [0, -10, 0])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await VideoPlanningFixtures.plan(scene, frame: 15)
        #expect(frame.videos.count == 2)
        #expect(Set(frame.videos.keys.map(\.frame)) == [15, 25])
        let commands = frame.plan.commands.compactMap { if case .video(let value) = $0 { value } else { nil } }
        #expect(commands.count == 3 && Set(commands.compactMap(\.layerID)).count == 3)
        #expect(commands.map(\.resourceID.frame).filter { $0 == 15 }.count == 2)
        let before = await scene.videos?.decodedSampleCount
        let later = try await VideoPlanningFixtures.plan(scene, frame: 16)
        #expect(Set(later.videos.keys.map(\.frame)) == [16, 26])
        #expect(Set(frame.videos.keys.map(\.frame)) == [15, 25])
        #expect(await scene.videos?.decodedSampleCount != before)
    }

    /// 紧计划预算在VT启动前失败；同文档同播放器可复用媒体owner，独立准备保持会话隔离。
    @Test func inputBudgetAndOwnerReuseFollowPreparedScene() async throws {
        let file = try SceneFixtures.build([await PAGVideoFixtures.source(in: "RootLayerVideo.pag")])
        let first = try await PreparedScene.prepare(file.composition)
        let reused = try await PreparedScene.prepare(file.composition, reusing: first)
        let other = try await PreparedScene.prepare(file.composition)
        #expect(first.videos === reused.videos && first.videos !== other.videos)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await FramePlanner.prepare(first, at: .zero, targetSize: file.composition.size,
                                            scale: 1, mode: .none, maximumBytes: 1024)
        }
        #expect(await first.videos?.decodedSampleCount == 0)
        let time = try SceneValidator.time(frame: 10, rate: 24)
        let offset = try SceneFixtures.build([await PAGVideoFixtures.source(in: "RootLayerVideoOffset.pag")])
        let offsetScene = try await PreparedScene.prepare(offset.composition)
        let frame = try await FramePlanner.prepare(offsetScene, at: time, targetSize: offset.composition.size, scale: 1, mode: .none)
        #expect(frame.videos.keys.first?.frame == 10)
    }

    /// 序列内容不能与人工图层或另一种序列混装；这属于语义校验，不依赖系统能否解码。
    @Test func rejectsMixedCompositionContent() async throws {
        let source = try await PAGVideoFixtures.source(in: "RootLayerVideo.pag")
        let mixed = SourceComposition(id: source.id, size: source.size, durationFrames: source.durationFrames,
            frameRate: source.frameRate, background: source.background,
            layers: [SceneFixtures.layer(999)], video: source.video)
        #expect(throws: PAGError.invalidFile(reason: "mixedCompositionContent", offset: nil)) { try SceneFixtures.build([mixed]) }
    }
}

/// 由真实视频块构建明确标注的语义图，只检验计划与渲染组合，不声称它是另一个导出的PAG文件。
enum VideoPlanningFixtures {
    /// 把同一视频放入多个实例，再用可选整体alpha的预合成包装，方便核对折叠和局部组语义。
    static func nested(starts: [Int64], opacity: UInt8 = 255) async throws -> PAGFile {
        let source = try await PAGVideoFixtures.source(in: "RootLayerVideo.pag")
        let layers = starts.enumerated().map { index, start in
            SceneFixtures.layer(UInt32(index + 900), duration: source.durationFrames,
                                content: .precomposition(id: source.id, startFrame: start))
        }
        let inner = SourceComposition(id: 1000, size: source.size, durationFrames: source.durationFrames,
            frameRate: source.frameRate, background: source.background, layers: layers)
        let transform = SourceTransform(anchor: .zero, position: .zero, scale: .one, rotation: 0, opacity: opacity)
        let layer = SceneFixtures.layer(1100, duration: source.durationFrames,
            transform: SourceTransformProperties(constant: transform), content: .precomposition(id: inner.id, startFrame: 0))
        let root = SourceComposition(id: 1001, size: source.size, durationFrames: source.durationFrames,
            frameRate: source.frameRate, background: source.background, layers: [layer])
        return try SceneFixtures.build([source, inner, root])
    }

    /// 用根源帧率创建合法采样微秒，所有宿主共用同一个后台计划入口。
    static func plan(_ scene: PreparedScene, frame: Int64) async throws -> PreparedFrame {
        let root = scene.composition.storage.compositions[scene.composition.storage.rootIndex]
        return try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: frame, rate: root.frameRate),
                                               targetSize: root.size, scale: 1, mode: .none)
    }
}
