import Testing
@testable import pag_swift

/// 用独立的源坐标实例核对MotionBlur相邻矩阵、语义域共轭及上游跳过分支。
struct MotionBlurSamplingTests {
    /// 首个内容帧以前一帧固定为自身，应跳过滤镜且不扩大任何输入范围。
    @Test func identicalMatricesKeepInputBounds() throws {
        let matrix = try SceneAffine.translation(x: 20, y: -10)
        let sampling = try MotionBlurSampling(previous: matrix, current: matrix)
        let input = try RenderBounds(left: 10, top: 20, right: 110, bottom: 70)
        #expect(sampling.shouldSkip)
        #expect(try sampling.outputBounds(for: input) == input)
    }

    /// 非原点100×50输入平移10像素，归一速度必须是(0.1,0)，不受紧附件尺寸影响。
    @Test func translationUsesSemanticInputSize() throws {
        let sampling = try MotionBlurSampling(previous: .identity,
            current: SceneAffine.translation(x: 10, y: 0))
        let input = try RenderBounds(left: 30, top: 40, right: 130, bottom: 90)
        let matrix = try sampling.textureTransforms(in: input)
        #expect(!sampling.shouldSkip)
        #expect(sampling.velocityCenter == 0.5)
        let velocity = matrix.velocity(at: SIMD2(0.25, 0.75))
        #expect(abs(velocity.x - 0.1) < 0.000_01)
        #expect(abs(velocity.y) < 0.000_01)
        #expect(try sampling.outputBounds(for: input) ==
            RenderBounds(left: 20, top: 35, right: 140, bottom: 95))
    }

    /// x缩放改变时中心必须取0；输入非零原点会进入前后位置差，不能只算线性项。
    @Test func scaleIncludesInputOriginAndSelectsLeadingSamples() throws {
        let sampling = try MotionBlurSampling(previous: .identity,
            current: SceneAffine.scale(x: 2, y: 1))
        let input = try RenderBounds(left: 20, top: 10, right: 120, bottom: 60)
        let matrix = try sampling.textureTransforms(in: input)
        #expect(sampling.velocityCenter == 0)
        let velocity = matrix.velocity(at: SIMD2(0, 0.5))
        #expect(abs(velocity.x - 0.1) < 0.000_01)
        #expect(abs(velocity.y) < 0.000_01)
    }
}
