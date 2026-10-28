import Testing
@testable import pag_swift

/// 上游256格纹理生成的量化、重合色标和帧预算边界。
struct GradientTexturePixelsTests {
    /// 两端颜色在0和255号格写入，内部alpha按Float步长截成字节。
    @Test func twoStopsWriteEndpointsAndAlpha() throws {
        var budget = try MetalFrameBudget()
        let stops = [GradientStop(position: 0, color: SIMD4(1, 0, 0, 0)),
                     GradientStop(position: 1, color: SIMD4(0, 0, 1, 1))]
        let pixels = try GradientTexturePixels.make(stops: stops, budget: &budget)
        #expect(pixels.count == 1_024)
        #expect(Array(pixels[0..<4]) == [255, 0, 0, 0])
        #expect(Array(pixels[255 * 4..<(256 * 4)]) == [0, 0, 255, 255])
        #expect(abs(Int(pixels[128 * 4 + 3]) - 128) <= 1)
    }

    /// 同位置hardstop不写旧色，第0格应从右侧新色开始。
    @Test func repeatedIndexSelectsRightColor() throws {
        var budget = try MetalFrameBudget()
        let stops = [GradientStop(position: 0, color: SIMD4(1, 0, 0, 1)),
                     GradientStop(position: 0, color: SIMD4(0, 0, 1, 1)),
                     GradientStop(position: 1, color: SIMD4(0, 1, 0, 1))]
        let pixels = try GradientTexturePixels.make(stops: stops, budget: &budget)
        #expect(Array(pixels[0..<4]) == [0, 0, 255, 255])
    }

    /// 小于输入表成本的帧预算须在分配前失败，不能返回半张查色表。
    @Test func tightBudgetRejectsBeforeAllocation() throws {
        var budget = try MetalFrameBudget(maximumBytes: 100)
        let stops = [GradientStop(position: 0, color: SIMD4(1, 0, 0, 1)),
                     GradientStop(position: 1, color: SIMD4(0, 0, 1, 1))]
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try GradientTexturePixels.make(stops: stops, budget: &budget)
        }
    }
}
