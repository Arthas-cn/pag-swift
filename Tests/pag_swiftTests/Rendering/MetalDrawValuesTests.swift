import Testing
@testable import pag_swift

/// CPU与MSL共享常量的布局、坐标、裁剪和预乘合同，无需GPU即可发现两端错位。
struct MetalDrawValuesTests {
    /// 顶点与常量偏移符合MSL布局，避免结构大小相同却字段错位。
    @Test func sharedLayoutsHaveStableOffsets() {
        #expect(MemoryLayout<MetalVertex>.stride == 16)
        #expect(MemoryLayout<MetalVertex>.offset(of: \.textureCoordinate) == 8)
        #expect(MemoryLayout<MetalDrawUniforms>.stride == 112)
        #expect(MemoryLayout<MetalDrawUniforms>.offset(of: \.verticalPixels) == 16)
        #expect(MemoryLayout<MetalDrawUniforms>.offset(of: \.color) == 32)
        #expect(MemoryLayout<MetalDrawUniforms>.offset(of: \.counts) == 48)
        #expect(MemoryLayout<MetalDrawUniforms>.offset(of: \.targetOffset) == 64)
        #expect(MemoryLayout<MetalDrawUniforms>.offset(of: \.inverse) == 80)
        #expect(MemoryLayout<MetalDrawUniforms>.offset(of: \.rasterBounds) == 96)
    }

    /// 先以Double补回巨大原点并抵消平移，再准备世界查询和包围矩形NDC。
    @Test func worldMappingRestoresOriginBeforeFloatConversion() throws {
        let offset = Double(1 << 40)
        let matrix = try SceneAffine.translation(x: -offset + 10, y: offset + 20)
        let transform = try MetalDrawTransform(matrix: matrix, origin: ScenePoint(x: offset, y: -offset))
        let uniform = try MetalDrawUniforms(transform: transform,
                                             color: .one, clipCount: 2, clipStart: 8, nodeCount: 7, width: 100, height: 100,
                                             raster: RenderPixelRect(x: 10, y: 20, width: 20, height: 30))
        #expect(uniform.horizontalPixels == SIMD4<Float>(1, 0, 10, 0))
        #expect(uniform.verticalPixels == SIMD4<Float>(0, 1, 20, 0))
        #expect(uniform.inverse == SIMD4<Float>(1, 0, 0, 1))
        #expect(abs(uniform.rasterBounds.x + 0.8) < 0.000001 && abs(uniform.rasterBounds.y - 0.6) < 0.000001)
        #expect(uniform.counts == SIMD4<UInt32>(2, 7, 0, 8))
    }

    /// 分数剪切和镜像下，实际上传的正矩阵与逆矩阵仍还原相同图片UV。
    @Test func inverseMatchesUploadedWorldCoefficients() throws {
        let matrix = try SceneAffine(a: -2.12345678, b: 0.34567891, c: 0.12345678, d: 3.12345678, tx: 13.25, ty: 9.75)
        let transform = try MetalDrawTransform(matrix: matrix, origin: .zero)
        let uv = SIMD2<Float>(0.25, 0.75)
        let h = transform.horizontal, v = transform.vertical, inverse = transform.inverse
        let x = h.x * uv.x + h.y * uv.y, y = v.x * uv.x + v.y * uv.y
        #expect(abs(inverse.x * x + inverse.y * y - uv.x) < 1e-6)
        #expect(abs(inverse.z * x + inverse.w * y - uv.y) < 1e-6)
        let bounds = try transform.bounds(RenderBounds(left: 0, top: 0, right: 1, bottom: 1))
        #expect(bounds.left <= Double(x + h.z) && bounds.right >= Double(x + h.z))
        #expect(bounds.top <= Double(y + v.z) && bounds.bottom >= Double(y + v.z))
    }

    /// Double合法而Float打包已奇异，或顶点变换溢出Float时，编码前明确失败。
    @Test func unrepresentableGPUTransformsFailBeforeEncoding() throws {
        let collapsed = try SceneAffine(a: 1, b: 1, c: 1, d: 1 + 1e-8, tx: 0, ty: 0)
        #expect(throws: PAGError.renderingFailure("metalDrawTransform")) {
            try MetalDrawTransform(matrix: collapsed, origin: .zero)
        }
        let enormous = try MetalDrawTransform(matrix: .scale(x: 1e30, y: 1), origin: .zero)
        #expect(throws: PAGError.renderingFailure("metalCoordinateNonFinite")) {
            try enormous.bounds(RenderBounds(left: 0, top: 0, right: 1e30, bottom: 1))
        }
    }

    /// 旋转和反向缩放后的真矩形可还原局部坐标，AABB内但矩形外的点被拒绝。
    @Test func clipKeepsRotationAndNegativeScale() throws {
        let rotation = try SceneAffine.rotation(degrees: 45)
        let matrix = try SceneAffine.scale(x: -2, y: 3).following(rotation).following(.translation(x: 20, y: 40))
        var clips = MetalClipValues()
        try clips.append(FrameClip(size: PAGSize(width: 10, height: 10), matrix: matrix))
        let point = try matrix.applying(to: ScenePoint(x: 3, y: 7))
        let polygon = try clips.polygon(in: RenderBounds(left: -100, top: -100, right: 100, bottom: 100))
        #expect(contains(point, polygon: polygon))
        let outside = try matrix.applying(to: ScenePoint(x: -1, y: 5))
        #expect(contains(outside, polygon: polygon) == false)
        #expect(clips.sources[0].matrix == matrix)
    }

    /// 预乘颜色仅乘一次alpha；图片opacity的四通道一致，透明色全部为零。
    @Test func premultiplicationUsesOneSharedNumericDomain() throws {
        #expect(try MetalDrawUniforms.premultiplied(red: 1, green: 0.5, blue: 0.25, alpha: 0.5)
                == SIMD4<Float>(0.5, 0.25, 0.125, 0.5))
        #expect(try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1, alpha: 0) == .zero)
        #expect(throws: PAGError.renderingFailure("metalColorRange")) {
            try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1, alpha: .nan)
        }
    }

    /// 奇异裁剪、Float溢出和超过作用域预算的裁剪数明确失败，不向GPU传入未定义数据。
    @Test func invalidTransformsAndClipBudgetFail() throws {
        var clips = MetalClipValues()
        #expect(throws: PAGError.renderingFailure("metalClipTransform")) {
            try clips.append(FrameClip(size: PAGSize(width: 10, height: 10), matrix: .scale(x: 0, y: 1)))
        }
        #expect(throws: PAGError.renderingFailure("metalCoordinateNonFinite")) {
            try MetalDrawUniforms.finite(Double.greatestFiniteMagnitude, 0, 0, 0)
        }
        let clip = FrameClip(size: try PAGSize(width: 10, height: 10), matrix: .identity)
        for _ in 0..<128 { try clips.append(clip) }
        #expect(clips.count == 128)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalClips")) { try clips.append(clip) }
    }

    /// 直接检查准备后的凸边界，独立于原矩形逆变换的内外关系。
    private func contains(_ point: ScenePoint, polygon: RenderClipPolygon) -> Bool {
        guard polygon.vertices.count >= 3 else { return false }
        return polygon.vertices.indices.allSatisfy { index in
            let a = polygon.vertices[index], b = polygon.vertices[(index + 1) % polygon.vertices.count]
            return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) >= -1e-8
        }
    }
}
