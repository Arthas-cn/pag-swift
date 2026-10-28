import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import pag_swift

/// 内嵌视频策略的公开入口、媒体 owner 传递和真实系统查询；不把单会话测试当成百实例性能验收。
@Suite(.serialized, .timeLimit(.minutes(2)))
struct VideoDecodingPolicyTests {
    /// 默认 player 保留硬解策略，显式 automatic 沿真实场景安装传递至实例视频 owner。
    @Test(arguments: [false, true])
    func playerPropagatesPolicyThroughRealScene(automatic: Bool) async throws {
        let file = try await loadVideo()
        let player = automatic ? PAGPlayer(videoDecodingPolicy: .automatic) : PAGPlayer()
        try await player.setComposition(file.composition)
        let scene = try #require(await player.scene)
        let videos = try #require(scene.videos)
        #expect(videos.decodingPolicy == (automatic ? .automatic : .hardwareRequired))
        let diagnostics = await videos.decoderDiagnostics()
        #expect(diagnostics.hardwareSessions == 0)
        #expect(diagnostics.softwareSessions == 0)
        #expect(diagnostics.unknownSessions == 0)
        try await player.setComposition(nil)
    }

    /// 每种策略只选一个系统键；模拟器保留既有例外，不能用模拟器结果证明真实设备硬解。
    @Test func specificationPreservesDefaultAndAllowsAutomaticSelection() {
        #expect(PAGVideoDecodingPolicy.automatic.requiresHardware == false)
        #expect(PAGVideoDecodingPolicy.automatic.specificationKey == kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder)
        #if targetEnvironment(simulator)
        #expect(PAGVideoDecodingPolicy.hardwareRequired.requiresHardware == false)
        #expect(PAGVideoDecodingPolicy.hardwareRequired.specificationKey == kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder)
        #else
        #expect(PAGVideoDecodingPolicy.hardwareRequired.requiresHardware)
        #expect(PAGVideoDecodingPolicy.hardwareRequired.specificationKey == kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder)
        #endif
    }

    /// 同源同策略编辑复用视频 owner；策略不同则换 owner，不能把旧硬解会话偷渡给 automatic。
    @Test func sceneReuseRespectsDecodingPolicy() async throws {
        let file = try await loadVideo()
        let original = try await PreparedScene.prepare(file.composition)
        let originalVideos = try #require(original.videos)
        let same = try await PreparedScene.prepare(file.composition, reusing: original)
        #expect(same.videos === originalVideos)
        let automatic = try await PreparedScene.prepare(file.composition, reusing: original, videoDecodingPolicy: .automatic)
        let automaticVideos = try #require(automatic.videos)
        #expect(automaticVideos !== originalVideos)
        #expect(automaticVideos.decodingPolicy == .automatic)
        let repeated = try await PreparedScene.prepare(file.composition, reusing: automatic, videoDecodingPolicy: .automatic)
        #expect(repeated.videos === automaticVideos)
    }

    /// 真正创建并解码一帧之后才计系统查询结果；automatic 不预设一定硬解或一定软件回退。
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "需要真实 H.264 系统解码能力"),
          arguments: [PAGVideoDecodingPolicy.hardwareRequired, .automatic])
    func countsActualOpenSessions(policy: PAGVideoDecodingPolicy) async throws {
        let file = try await loadVideo()
        let source = try #require(file.composition.storage.compositions.compactMap(\.video).first?.sequences.first)
        let store = VideoFrameStore(decodingPolicy: policy)
        let frame = try await store.frame(for: source, at: 0)
        #expect(frame.byteCount > 0)
        let diagnostics = await store.decoderDiagnostics()
        #expect(diagnostics.policy == policy)
        #expect(diagnostics.hardwareSessions + diagnostics.softwareSessions + diagnostics.unknownSessions == 1)
        if policy.requiresHardware {
            // required 的系统后验校验已通过，唯一实际会话应明确报告硬解。
            #expect(diagnostics.hardwareSessions == 1)
        }
        // 同帧命中不能凭空累加会话统计；此处口径是当前开放会话，不是累计创建次数。
        _ = try await store.frame(for: source, at: 0)
        let repeated = await store.decoderDiagnostics()
        #expect(repeated.hardwareSessions + repeated.softwareSessions + repeated.unknownSessions == 1)
    }

    /// 从指定源 revision 的真实 PAG 夹具加载；不手写二进制冒充合法视频资源。
    private func loadVideo() async throws -> PAGFile {
        let url = try #require(Bundle.module.url(forResource: "RootLayerVideo", withExtension: "pag", subdirectory: "Resources"))
        return try await PAGLoader().load(from: url)
    }
}
