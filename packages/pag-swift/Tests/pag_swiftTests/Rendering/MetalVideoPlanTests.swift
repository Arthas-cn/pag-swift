import CoreMedia
import Metal
import Testing
import VideoToolbox
@testable import pag_swift

/// 视频输入经过共同计划和Metal批次的资源保活、透明组及失败检查，后续drawable测试负责实际提交。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) && MTLCreateSystemDefaultDevice() != nil,
                 "需要硬件解码与Metal"), .timeLimit(.minutes(1)))
struct MetalVideoPlanTests {
    /// 无Picture快照时一个或两个视频draw都继承预合成alpha，不借整组合成附件。
    @Test(arguments: [1, 2]) func preservesVideoInputsThroughOpacityGroups(_ count: Int) async throws {
        let file = try await VideoPlanningFixtures.nested(starts: Array(repeating: 0, count: count), opacity: 128)
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await VideoPlanningFixtures.plan(scene, frame: 2)
        let owner = MetalVideoPlanTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verify(frame, size: file.composition.size, count: count)
    }
}

/// 裸Metal批次仅在测试owner内构造/释放，不跨actor返回系统输入。
private actor MetalVideoPlanTestOwner {
    /// 一次性sending移交的设备，只属于当前测试域。
    private let device: any MTLDevice

    /// 接管设备，避免从主actor保留共享裸GPU别名。
    init(device: sending any MTLDevice) { self.device = device }

    /// 禁用跨帧缓存仍保活完整视频输入；同PTS复用纹理，缺资源和小预算拒绝部分批次。
    func verify(_ frame: PreparedFrame, size: PAGSize, count: Int) throws {
        let resources = try MetalResources(device: device, byteLimit: 0)
        let missing = PreparedFrame(plan: frame.plan, images: frame.images, shapes: frame.shapes, texts: frame.texts)
        #expect(throws: PAGError.renderingFailure("metalVideoResource")) {
            try MetalFramePreparation.prepare(missing, width: Int(size.width), height: Int(size.height), resources: resources)
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try MetalFramePreparation.prepare(frame, width: Int(size.width), height: Int(size.height), resources: resources, maximumBytes: 1)
        }
        let batch = try MetalFramePreparation.prepare(frame, width: Int(size.width), height: Int(size.height), resources: resources)
        defer { batch.releaseTransients() }
        #expect(resources.count == 0)
        #expect(batch.passes.count == 1 && batch.loans.isEmpty)
        let firstPass = try #require(batch.passes.first)
        #expect(firstPass.draws.count == count)
        let video = try #require(firstPass.draws.first?.video)
        #expect(firstPass.draws.allSatisfy { $0.video === video && $0.texture == nil })
        #expect(firstPass.draws.allSatisfy { $0.uniforms.color == SIMD4(repeating: Float(128.0 / 255)) })
        resources.removeAll()
        #expect(video.luma.width > 0 && video.chroma.height > 0)
    }
}
