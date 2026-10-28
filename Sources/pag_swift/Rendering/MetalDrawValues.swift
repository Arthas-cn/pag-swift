import Foundation

/// Swift 与 MSL 共用的16字节顶点布局；位置为网格本地坐标，图片使用0...1纹理坐标。
struct MetalVertex: Sendable {
    /// 已减去网格原点的有限Float位置。
    let position: SIMD2<Float>
    /// 顶行对应v=0；纯色图元不使用此字段。
    let textureCoordinate: SIMD2<Float>
}

/// 固定实际GPU正向系数后再求逆；包围范围、BVH查询和图片UV共同使用这份变换。
struct MetalDrawTransform: Sendable {
    /// 网格局部到显示像素x的Float行，平移已在Double中补偿源原点。
    let horizontal: SIMD4<Float>
    /// 网格局部到显示像素y的Float行。
    let vertical: SIMD4<Float>
    /// 实际Float正向矩阵的逆线性部分，按两行排列。
    let inverse: SIMD4<Float>

    /// 原始矩阵或上传系数退化、结果超出Float范围时失败，不把矛盾的正逆矩阵交给GPU。
    init(matrix: SceneAffine, origin: ScenePoint) throws {
        let determinant = matrix.a * matrix.d - matrix.b * matrix.c
        guard determinant.isFinite, determinant != 0 else { throw PAGError.renderingFailure("metalDrawTransform") }
        let position = try matrix.applying(to: origin)
        horizontal = try MetalDrawUniforms.finite(matrix.a, matrix.c, position.x, 0)
        vertical = try MetalDrawUniforms.finite(matrix.b, matrix.d, position.y, 0)
        let a = Double(horizontal.x), c = Double(horizontal.y), b = Double(vertical.x), d = Double(vertical.y)
        // Double可逆不代表Float打包后仍可逆；索引查询必须对应实际GPU顶点变换。
        let actual = a * d - b * c
        guard actual.isFinite, actual != 0 else { throw PAGError.renderingFailure("metalDrawTransform") }
        inverse = try MetalDrawUniforms.finite(d / actual, -c / actual, -b / actual, a / actual)
    }

    /// 对实际上传系数求保守范围，并在编码前拒绝GPU无法表达的非有限结果。
    func bounds(_ local: RenderBounds) throws -> RenderBounds {
        let matrix = try SceneAffine(a: Double(horizontal.x), b: Double(vertical.x),
                                     c: Double(horizontal.y), d: Double(vertical.y),
                                     tx: Double(horizontal.z), ty: Double(vertical.z))
        let result = try local.transformed(by: matrix)
        _ = try MetalDrawUniforms.finite(result.left, result.top, result.right, result.bottom)
        return result
    }
}

/// 与MSL按七个16字节字段排列的112字节常量，不包含平台资源或指针。
struct MetalDrawUniforms: Sendable {
    /// 网格局部(x,y,1)到最终显示像素x的行向量，已补回网格原点。
    let horizontalPixels: SIMD4<Float>
    /// 网格局部(x,y,1)到最终显示像素y的行向量。
    let verticalPixels: SIMD4<Float>
    /// 已预乘源色；图片四通道均为图层opacity。
    let color: SIMD4<Float>
    /// 裁剪边数、BVH节点数、保留零值、单帧裁剪数组起点。
    let counts: SIMD4<UInt32>
    /// 当前pass左上角的最终显示坐标；片元在此恢复全局位置。
    let targetOffset: SIMD4<Float>
    /// 世界到网格局部的逆线性矩阵，按两行排列；平移由上述世界原点单独扣除。
    let inverse: SIMD4<Float>
    /// 边缘片元包围矩形的NDC(left,top,right,bottom)，不表示真实几何或裁剪。
    let rasterBounds: SIMD4<Float>

    /// 接收已验证的世界变换，并在Double中准备当前pass包围范围；拒绝不可表示的GPU常量。
    init(transform: MetalDrawTransform, color: SIMD4<Float>, clipCount: Int, clipStart: Int = 0,
         nodeCount: Int, width: Int, height: Int, targetOrigin: ScenePoint = .zero, raster: RenderPixelRect) throws {
        guard width > 0, height > 0, clipCount >= 0, clipStart >= 0, nodeCount > 0,
              UInt32(exactly: clipCount) != nil, UInt32(exactly: clipStart) != nil, UInt32(exactly: nodeCount) != nil else {
            throw PAGError.invalidArgument("metalDrawDimensions")
        }
        horizontalPixels = transform.horizontal
        verticalPixels = transform.vertical
        inverse = transform.inverse
        targetOffset = try Self.finite(targetOrigin.x, targetOrigin.y, 0, 0)
        let sx = 2 / Double(width), sy = -2 / Double(height)
        rasterBounds = try Self.finite((Double(raster.x) - targetOrigin.x) * sx - 1,
                                       (Double(raster.y) - targetOrigin.y) * sy + 1,
                                       (Double(raster.x) + Double(raster.width) - targetOrigin.x) * sx - 1,
                                       (Double(raster.y) + Double(raster.height) - targetOrigin.y) * sy + 1)
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite, color.w.isFinite else {
            throw PAGError.renderingFailure("metalColorNonFinite")
        }
        self.color = color
        counts = SIMD4(UInt32(clipCount), UInt32(nodeCount), 0, UInt32(clipStart))
    }

    /// 将有限Double系数打包为Float；范围溢出不得默默送入着色器。
    static func finite(_ x: Double, _ y: Double, _ z: Double, _ w: Double) throws -> SIMD4<Float> {
        let value = SIMD4(Float(x), Float(y), Float(z), Float(w))
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else {
            throw PAGError.renderingFailure("metalCoordinateNonFinite")
        }
        return value
    }

    /// 纯色/文字按统一sRGB数值域一次预乘，不在显示宿主再转换或重复乘alpha。
    static func premultiplied(red: Double, green: Double, blue: Double, alpha: Double) throws -> SIMD4<Float> {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PAGError.renderingFailure("metalColorRange")
        }
        return SIMD4(Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha))
    }
}

/// 真实矩形裁剪的纯值作用域；保留源矩阵，最终由凸交集准备GPU边界。
struct MetalClipValues: Sendable {
    /// 已接受的真实矩形，COW共享父作用域，不保存GPU小常量区的旧逆映射行。
    private(set) var sources: [FrameClip] = []
    /// 裁剪的保守交集；nil且isEmpty=false表示没有范围限制。
    private(set) var bounds: RenderBounds?
    /// 保守范围交集已经为空，后续追加不能把它变回无限范围。
    private(set) var isEmpty = false
    /// 每个作用域最多128个源裁剪，这是库的有界准备策略。
    var count: Int { sources.count }

    /// 追加有限可逆的真实矩形，反向缩放合法；奇异矩阵与资源超限明确失败。
    mutating func append(_ clip: FrameClip) throws {
        guard count < 128 else { throw PAGError.resourceLimitExceeded("maximumMetalClips") }
        let m = clip.matrix
        let determinant = m.a * m.d - m.b * m.c
        guard determinant.isFinite, determinant != 0 else { throw PAGError.renderingFailure("metalClipTransform") }
        let local = try RenderBounds(left: 0, top: 0, right: clip.size.width, bottom: clip.size.height)
        let transformed = try local.transformed(by: m)
        sources.append(clip)
        intersect(transformed)
    }

    /// 单图元折叠时合并真实裁剪，不能只合并包围范围。
    func merging(_ other: MetalClipValues) throws -> MetalClipValues {
        guard count + other.count <= 128 else { throw PAGError.resourceLimitExceeded("maximumMetalClips") }
        var result = self
        result.sources += other.sources
        result.isEmpty = isEmpty || other.isEmpty
        if let bound = other.bounds { result.intersect(bound) }
        return result
    }

    /// 在当前pass有界范围内求完整凸交集；空顶点必须使调用者跳过绘制。
    func polygon(in bounds: RenderBounds) throws -> RenderClipPolygon {
        var result = RenderClipPolygon(bounds: bounds)
        var budget = try GeometryBudget()
        for clip in sources { try result.intersect(clip, budget: &budget) }
        return result
    }

    /// 累计保守范围，空交集作为独立状态保存。
    private mutating func intersect(_ bound: RenderBounds) {
        guard !isEmpty else { return }
        if let previous = bounds {
            bounds = previous.intersection(bound)
            isEmpty = bounds == nil
        } else { bounds = bound }
    }
}
