import Testing
@testable import pag_swift

/// tag61的两轴尺寸和核参数专项；这些数值不能被紧致附件大小重新归一。
struct GlowSamplingTests {
    /// 半径48时横轴目标分别向上取整到97×49，步长取目标尺寸倒数。
    @Test func radiusShrinksBothAxesBeforeSampling() throws {
        let sampling = try GlowSampling(SampledGlow(threshold: 0.2431372553,
            radius: 48, intensity: 1), inputWidth: 100, inputHeight: 50)
        #expect(sampling.blurWidth == 97)
        #expect(sampling.blurHeight == 49)
        #expect(sampling.horizontalStep == 1 / Float(97))
        #expect(sampling.verticalStep == 1 / Float(49))
        #expect(sampling.threshold == Float(0.2431372553))
        #expect(sampling.intensity == 1)
    }

    /// 半径为零时仍执行五点核，但两轴目标尺寸与原输入相同。
    @Test func zeroRadiusKeepsInputDimensions() throws {
        let sampling = try GlowSampling(SampledGlow(threshold: 1, radius: 0, intensity: 1),
                                        inputWidth: 40, inputHeight: 30)
        #expect(sampling.blurWidth == 40)
        #expect(sampling.blurHeight == 30)
    }

    /// 缩放结果不再具有正的整数尺寸时，不能提交零尺寸GPU附件。
    @Test func exhaustedRadiusFailsBeforeGPUAllocation() {
        #expect(throws: PAGError.self) {
            try GlowSampling(SampledGlow(threshold: 1, radius: 1500, intensity: 0),
                             inputWidth: 40, inputHeight: 30)
        }
    }
}
