import Testing
@testable import pag_swift

/// 局部组范围与pass坐标换算，无GPU即可验证分配不会吞掉旋转或负坐标内容。
struct RenderBoundsTests {
    /// 旋转后范围包含四角，整像素附件只为可见内容向外保留一像素。
    @Test func transformedBoundsCropToDisplay() throws {
        let source = try RenderBounds(left: 0, top: 0, right: 10, bottom: 20)
        // 用可精确表示的直角矩阵，避免把sin/cos舍入多保留一行像素误判为范围算法错误。
        let transform = try SceneAffine(a: 0, b: 1, c: -1, d: 0, tx: 25, ty: 5)
        let rotated = try source.transformed(by: transform)
        #expect(abs(rotated.left - 5) < 1e-10 && abs(rotated.right - 25) < 1e-10)
        let display = try RenderBounds(left: 8, top: 0, right: 100, bottom: 100)
        let rect = try #require(try rotated.pixelRect(clippedTo: display))
        #expect(rect.x == 8 && rect.y == 4 && rect.width == 18 && rect.height == 12)
        let disjoint = try RenderBounds(left: 50, top: 50, right: 60, bottom: 60)
        #expect(try rotated.pixelRect(clippedTo: disjoint) == nil)
    }

    /// 全局变换减去局部附件原点后产生相同局部NDC，片元另持有全局裁剪偏移。
    @Test func localPassPreservesGlobalClipCoordinates() throws {
        let transform = try MetalDrawTransform(matrix: .translation(x: 40, y: 70), origin: .zero)
        let uniforms = try MetalDrawUniforms(transform: transform, color: .one,
                                             clipCount: 1, nodeCount: 1, width: 20, height: 10, targetOrigin: ScenePoint(x: 30, y: 65),
                                             raster: RenderPixelRect(x: 40, y: 70, width: 5, height: 3))
        #expect(uniforms.rasterBounds.x == 0 && uniforms.rasterBounds.y == 0)
        #expect(uniforms.horizontalPixels.z == 40 && uniforms.verticalPixels.z == 70)
        #expect(uniforms.targetOffset == SIMD4<Float>(30, 65, 0, 0))
    }

    /// 相离裁剪的空交集不会在再次追加/合并时被误当成无限范围。
    @Test func emptyClipIntersectionStaysEmpty() throws {
        let size = try PAGSize(width: 10, height: 10)
        var a = MetalClipValues(), b = MetalClipValues()
        try a.append(FrameClip(size: size, matrix: .identity))
        try a.append(FrameClip(size: size, matrix: .translation(x: 20, y: 20)))
        try b.append(FrameClip(size: size, matrix: .identity))
        let result = try a.merging(b)
        #expect(result.isEmpty && result.count == 3)
        #expect(try b.merging(a).isEmpty)
    }

    /// 非有限或过大分配范围必须失败，极端坐标减法不能触发整数溢出崩溃。
    @Test func invalidOrOversizedBoundsFail() throws {
        #expect(throws: PAGError.renderingFailure("metalBounds")) {
            try RenderBounds(left: .nan, top: 0, right: 10, bottom: 10)
        }
        let enormous = try RenderBounds(left: -1e18, top: 0, right: 1e18, bottom: 10)
        #expect(throws: PAGError.resourceLimitExceeded("metalGroupDimensions")) { try enormous.pixelRect(clippedTo: enormous) }
    }
}
