import Testing
@testable import pag_swift

/// FastBlur透明扩边、Clamp裁回及大sigma缩采的整数纹理布局。
struct FastBlurTextureLayoutTests {
    /// 真实最大模糊值68在单位尺度下给sigma34，内部先缩到10再按取整宽度重算比例。
    @Test func largeSigmaRetainsSignedBoundsAndActualScale() throws {
        let sample = try FastBlurSampling(SampledFastBlur(blurriness: 68, direction: 0,
            repeatEdgePixels: false), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        let layout = try FastBlurTextureLayout(sample, width: 5, height: 3)
        #expect(layout.x.sampleLeft == -68)
        #expect(layout.x.sampleLength == 141)
        #expect(layout.x.outputLength == 141)
        #expect(layout.x.outputLeft == -68)
        #expect(layout.x.reducedLength == 42)
        #expect(layout.x.actualScale == Float(42) / Float(141))
        #expect(layout.x.kernel?.radius == 20)
        #expect(layout.y.sampleLength == 139)
        #expect(layout.y.reducedLength == 41)
        #expect(layout.x.outputTransform.translate == 0)
    }

    /// Clamp的内部采样仍需要双侧halo，最终输出和UV则裁回原图。
    @Test func clampHasInternalHaloButFixedOutput() throws {
        let sample = try FastBlurSampling(SampledFastBlur(blurriness: 4, direction: 0,
            repeatEdgePixels: true), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        let layout = try FastBlurTextureLayout(sample, width: 5, height: 3)
        #expect(layout.x.sampleLeft == -4)
        #expect(layout.x.sampleLength == 13)
        #expect(layout.x.reducedLength == 13)
        #expect(layout.x.outputLength == 5)
        #expect(layout.x.outputLeft == 0)
        #expect(layout.x.outputTransform.translate == 4)
        #expect(layout.y.outputLength == 3)
    }

    /// 单轴模糊不会在另一轴产生halo；过大局部表面在借GPU纹理前失败。
    @Test func oneAxisAndAreaLimit() throws {
        let sample = try FastBlurSampling(SampledFastBlur(blurriness: 4, direction: 1,
            repeatEdgePixels: false), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        let layout = try FastBlurTextureLayout(sample, width: 5, height: 3)
        #expect(layout.x.outputLength == 13)
        #expect(layout.y.outputLength == 3)
        #expect(layout.y.kernel?.radius == nil)
        #expect(throws: PAGError.self) {
            _ = try FastBlurTextureLayout(sample, width: 10_000, height: 10_000)
        }
    }
}
