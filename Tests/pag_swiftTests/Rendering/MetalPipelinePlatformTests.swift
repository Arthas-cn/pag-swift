import Metal
import Testing
@testable import pag_swift

/// 检查普通 Metal 管线与可选的颜色附件混合能力能在对应平台共同初始化。
struct MetalPipelinePlatformTests {
    /// 模拟器必须能创建普通管线，真实 Apple GPU 仍同时保留两种 HardLight 管线。
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的 Metal 设备"))
    func createsStandardPipelineWithoutRequiringFramebufferFetch() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipelines = try MetalPipelines(device: device)
        #expect(pipelines.solid.label == "pag.pagSolid")
        #expect(pipelines.image.label == "pag.pagImage")
        #if targetEnvironment(simulator)
        // 模拟器的 GPU 家族不能代表 framebuffer fetch 能力。
        #expect(pipelines.hardLightImage == nil)
        #expect(pipelines.hardLightTrackMatteImage == nil)
        #else
        let canFetch = device.supportsFamily(.apple2)
        #expect((pipelines.hardLightImage != nil) == canFetch)
        #expect((pipelines.hardLightTrackMatteImage != nil) == canFetch)
        #endif
    }
}
