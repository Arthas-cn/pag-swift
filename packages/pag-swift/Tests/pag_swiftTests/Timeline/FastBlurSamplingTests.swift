import Testing
@testable import pag_swift

/// FastBlur像素sigma与图层范围的两套尺度公式，对照上游`Apply`和`transformBounds`。
struct FastBlurSamplingTests {
    /// All方向的输出边界不乘effectScale，Gaussian像素sigma仍乘两个尺度。
    @Test func allDirectionHasDistinctBoundsScale() throws {
        let value = SampledFastBlur(blurriness: 68, direction: 0, repeatEdgePixels: false)
        let result = try FastBlurSampling(value, effectScaleX: 2, effectScaleY: 3,
                                          sourceScale: 1.5)
        #expect(result.sigmaX == 102)
        #expect(result.sigmaY == 153)
        #expect(result.outsetX == 68)
        #expect(result.outsetY == 68)
    }

    /// 仅单轴方向才把活动轴的effectScale带进图层范围，另一轴保持零。
    @Test(arguments: [(UInt8(1), Float(136), Float(0), Float(102), Float(0)),
                      (UInt8(2), Float(0), Float(204), Float(0), Float(153))])
    func oneAxisDirection(_ direction: UInt8, _ outsetX: Float, _ outsetY: Float,
                          _ sigmaX: Float, _ sigmaY: Float) throws {
        let value = SampledFastBlur(blurriness: 68, direction: direction, repeatEdgePixels: false)
        let result = try FastBlurSampling(value, effectScaleX: 2, effectScaleY: 3,
                                          sourceScale: 1.5)
        #expect(result.outsetX == outsetX)
        #expect(result.outsetY == outsetY)
        #expect(result.sigmaX == sigmaX)
        #expect(result.sigmaY == sigmaY)
    }

    /// 重复边缘保持原输入裁剪范围，但内部Gaussian仍按真实sigma工作。
    @Test func clampPreservesBounds() throws {
        let value = SampledFastBlur(blurriness: 68, direction: 0, repeatEdgePixels: true)
        let result = try FastBlurSampling(value, effectScaleX: 1, effectScaleY: 1,
                                          sourceScale: 1)
        #expect(result.outsetX == 0 && result.outsetY == 0)
        #expect(result.sigmaX == 34 && result.sigmaY == 34)
        #expect(result.repeatEdgePixels)
    }

    /// 源0模糊无需卷积；非法方向和负模糊不得进入GPU尺寸计算。
    @Test func zeroAndInvalidInputs() throws {
        let zero = try FastBlurSampling(SampledFastBlur(blurriness: 0, direction: 0,
            repeatEdgePixels: false), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        #expect(zero.sigmaX == 0 && zero.sigmaY == 0)
        #expect(throws: PAGError.self) {
            try FastBlurSampling(SampledFastBlur(blurriness: -1, direction: 0,
                repeatEdgePixels: false), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        }
        #expect(throws: PAGError.self) {
            try FastBlurSampling(SampledFastBlur(blurriness: 1, direction: 3,
                repeatEdgePixels: false), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        }
    }
}
