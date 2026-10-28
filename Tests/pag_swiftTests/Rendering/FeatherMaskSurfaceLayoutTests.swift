import Testing
@testable import pag_swift

/// 羽化局部内容/蒙版表面的裁交、缩放量化和有界尺寸，不用构建整帧附件。
struct FeatherMaskSurfaceLayoutTests {
    /// 未发生mask裁切时保留分数边界和原始内容采样位置，不擅自roundOut。
    @Test func uncroppedFractionalContentKeepsBounds() throws {
        let content = try RenderBounds(left: 10.25, top: 12.5, right: 20.25, bottom: 22.5)
        let mask = try RenderBounds(left: -5, top: -5, right: 100, bottom: 100)
        var budget = try MetalFrameBudget()
        let layout = try #require(try FeatherMaskSurfacePreparation.layout(content: content, mask: mask,
                                                                            parentMatrix: .identity, budget: &budget))
        #expect(layout.bounds == content)
        #expect(layout.scale == 1 && layout.width == 10 && layout.height == 10)
        #expect(layout.contentMatrix.tx == -10.25 && layout.contentMatrix.ty == -12.5)
    }

    /// 与mask相交改变bounds后才向外取整，非整数父倍率按1/20向上量化再决定附件尺寸。
    @Test func cropRoundsOutBeforeQuantizedScale() throws {
        let content = try RenderBounds(left: 10.25, top: 10.25, right: 20.25, bottom: 20.25)
        let mask = try RenderBounds(left: 12.1, top: 11.2, right: 18.7, bottom: 17.8)
        let matrix = try SceneAffine.scale(x: 1.17, y: 1.17)
        var budget = try MetalFrameBudget()
        let layout = try #require(try FeatherMaskSurfacePreparation.layout(content: content, mask: mask,
                                                                            parentMatrix: matrix, budget: &budget))
        #expect(layout.bounds == (try RenderBounds(left: 12, top: 11, right: 19, bottom: 18)))
        #expect(layout.scale == Float(1.2))
        #expect(layout.width == 9 && layout.height == 9)
        #expect(layout.contentMatrix.tx == Double(Float(-12) * layout.scale))
    }

    /// TGFX取两个矩阵列长的较大者；剪切矩阵不应改用更大的奇异值倍率。
    @Test func shearUsesAxisLengthInsteadOfSingularValue() throws {
        let bounds = try RenderBounds(left: 0, top: 0, right: 10, bottom: 10)
        let matrix = try SceneAffine(a: 1, b: 0, c: 1, d: 1, tx: 0, ty: 0)
        var budget = try MetalFrameBudget()
        let layout = try #require(try FeatherMaskSurfacePreparation.layout(content: bounds, mask: bounds,
                                                                            parentMatrix: matrix, budget: &budget))
        #expect(layout.scale == Float(1.45))
        #expect(layout.width == 15 && layout.height == 15)
    }

    /// 不相交没有附件；不可表示的极大范围和预取消都须在GPU分配前失败。
    @Test func invisibleOversizedAndCancelledLayoutDoNotAllocate() async throws {
        let content = try RenderBounds(left: 0, top: 0, right: 20, bottom: 20)
        let outside = try RenderBounds(left: 21, top: 0, right: 30, bottom: 20)
        var budget = try MetalFrameBudget()
        #expect(try FeatherMaskSurfacePreparation.layout(content: content, mask: outside,
                                                         parentMatrix: .identity, budget: &budget) == nil)
        let huge = try RenderBounds(left: 0, top: 0, right: 20_000, bottom: 20_000)
        #expect(throws: PAGError.resourceLimitExceeded("metalGroupDimensions")) {
            try FeatherMaskSurfacePreparation.layout(content: huge, mask: huge,
                                                     parentMatrix: .identity, budget: &budget)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = try MetalFrameBudget()
            return try FeatherMaskSurfacePreparation.layout(content: content, mask: content,
                                                            parentMatrix: .identity, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
