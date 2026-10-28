import Foundation
import Metal
import Testing
@testable import pag_swift

/// 含音频元数据的真实TZ2逐源帧验证；只检验画面播放，不创建音频会话。
struct AudioFilePlaybackTests {
    /// 三种布局遍历全部源帧，含视频准备和真实Metal输入；根pass保持直接drawable附件。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_AUDIO_FRAME_AUDIT"] == "1",
                   "设置PAG_AUDIO_FRAME_AUDIT=1遍历TZ2全部源帧"), .timeLimit(.minutes(5)))
    func allSourceFramesPrepareMetalInputs() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TZ2.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = file.storage.compositions[file.storage.rootIndex]
        let owner = try AudioFileMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
        let displays: [(PAGSize, Double, PAGScaleMode)] = try [
            (PAGSize(width: 500, height: 220), 2, .aspectFit),
            (PAGSize(width: 200, height: 150), 1, .aspectFit),
            (PAGSize(width: 750, height: 500), 3, .stretch)
        ]
        var count = 0
        for (size, scale, mode) in displays {
            for frame in 0..<root.durationFrames {
                let prepared = try await FramePlanner.prepare(scene,
                    at: SceneValidator.time(frame: frame, rate: root.frameRate),
                    targetSize: size, scale: scale, mode: mode)
                try await owner.prepare(prepared, width: Int(size.width * scale), height: Int(size.height * scale))
                count += 1
            }
        }
        #expect(count == root.durationFrames * 3 && count > 0)
        print("AUDIO_FRAME_TOTAL TZ2.pag frames=\(root.durationFrames) combinations=\(count)")
    }
}

/// 测试专用GPU输入owner，裸Metal资源不跨隔离；不创建离屏出图器。
private actor AudioFileMetalOwner {
    /// 跨源帧复用生产材料缓存，按现有预算淘汰。
    private let resources: MetalResources

    /// 一次性接收设备并建立生产缓存，失败原样传播。
    init(device: sending any MTLDevice) throws { resources = try MetalResources(device: device) }

    /// 准备真实视频/网格输入，成功或失败都归还局部附件。
    func prepare(_ frame: PreparedFrame, width: Int, height: Int) throws {
        do {
            let batch = try MetalFramePreparation.prepare(frame, width: width, height: height, resources: resources)
            batch.releaseTransients()
            #expect(batch.passes.last?.attachment == nil && resources.groups.activeBytes == 0)
        } catch {
            #expect(resources.groups.activeBytes == 0)
            throw error
        }
    }
}
