@testable import pag_swift

/// Trim显示门禁的纯语义场景；不合成PAG字节，不提前开放正式文件入口。
enum MetalTrimFixtures {
    /// 从左上角沿顺时针走的方形；固定起点使截取范围对应可手算的边。
    static func square(x: Double = 20, y: Double = 20, size: Double = 60) throws -> SourcePath {
        try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: x, y: y), ScenePoint(x: x + size, y: y),
            ScenePoint(x: x + size, y: y + size), ScenePoint(x: x, y: y + size)])
    }

    /// 半轮廓形成右上三角形；颜色变化保留Trim身份，区间变化则由半轮廓扩至三边。
    static func filled(animatedColor: Bool = false, animatedRange: Bool = false,
                       gradient: SourceGradientKind? = nil) throws -> [SourceShape] {
        let trim = try SourceTrimPaths(start: .init(constant: 0),
            end: animatedRange ? ShapePropertyFixtures.track(0.5, 0.75) : .init(constant: 0.5),
            offset: .init(constant: 0), mode: .simultaneously)
        let paint: SourceShape
        if let gradient {
            paint = .gradientFill(.init(compositeOrder: .belowPrevious, gradient: MetalGradientFixtures.material(kind: gradient)))
        } else {
            paint = try ShapePropertyFixtures.fill(color: animatedColor
                ? ShapePropertyFixtures.track(.defaultFill, SceneColor(red: 0, green: 0, blue: 255)) : .init(constant: .defaultFill))
        }
        // paint故意放在Trim前，显示结果也必须读取两阶段最终路径。
        return [.path(.init(constant: try square())), paint, .trimPaths(trim)]
    }

    /// 两个子组的半轮廓三角形重叠，由父Trim更新此前子组paint；外组透明度只乘一次。
    static func groupOpacity() throws -> [SourceShape] {
        let children = try [10.0, 30].map { x in
            SourceShape.group(ShapePropertyFixtures.group(), [.path(.init(constant: try square(x: x, size: 40))),
                ShapePropertyFixtures.fill()])
        }
        return [.group(ShapePropertyFixtures.group(opacity: try ShapePropertyFixtures.track(UInt8(255), UInt8(0))),
            children + [.trimPaths(TrimBatchFixtures.source(0, 0.5))])]
    }

    /// 闭合方形裁剪后描边保持开放，供cap/join/跨接缝和渐变覆盖验证。
    static func squareStroke(start: Double, end: Double, cap: SourceLineCap = .butt,
                             join: SourceLineJoin = .miter) throws -> [SourceShape] {
        [.path(.init(constant: try square())), .trimPaths(TrimBatchFixtures.source(start, end)),
         .stroke(StrokeFixtures.make(width: .init(constant: 10), color: .init(constant: .defaultFill), cap: cap, join: join))]
    }

    /// 水平像素中心线，裁剪后的每个Move重新开始dash；材料保持原图层方向。
    static func line(start: Double, end: Double, cap: SourceLineCap = .butt,
                     dashed: Bool = false, gradient: Bool = false, multipleContours: Bool = false,
                     width: Double = 8) throws -> [SourceShape] {
        let points = multipleContours ? [ScenePoint(x: 20.5, y: 25.5), ScenePoint(x: 80.5, y: 25.5),
            ScenePoint(x: 20.5, y: 75.5), ScenePoint(x: 80.5, y: 75.5)]
            : [ScenePoint(x: 20.5, y: 50.5), ScenePoint(x: 80.5, y: 50.5)]
        let path = try SourcePath(verbs: multipleContours ? [.move, .line, .move, .line] : [.move, .line], points: points)
        let dashes = try dashed ? SourceDashes(offset: .init(constant: 0), intervals: [.init(constant: 10), .init(constant: 10)]) : nil
        let paint: SourceShape = gradient
            ? .gradientStroke(SourceGradientStroke(compositeOrder: .abovePrevious, gradient: MetalGradientFixtures.material(),
                cap: cap, join: .miter, miterLimit: .init(constant: 4), width: .init(constant: width), dashes: dashes))
            : .stroke(StrokeFixtures.make(width: .init(constant: width), color: .init(constant: .defaultFill), cap: cap, dashes: dashes))
        return [.path(.init(constant: path)), .trimPaths(TrimBatchFixtures.source(start, end)), paint]
    }

    /// 完整圆的前半弧保留Conic，Fill只在最终消费时连接上下端点。
    static func ellipse() -> [SourceShape] {
        [.ellipse(ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: 60, y: 60)),
            position: .init(constant: ScenePoint(x: 50, y: 50)))),
         .trimPaths(TrimBatchFixtures.source(0, 0.5)), ShapePropertyFixtures.fill()]
    }

    /// 两个独立等长PathElement按各自或合计长度裁剪，不能当作一条多轮廓路径处理。
    static func batch(_ mode: SourceTrimMode) throws -> [SourceShape] {
        let paths: [SourceShape] = try [25.5, 75.5].map { y in
            .path(.init(constant: try SourcePath(verbs: [.move, .line],
                points: [ScenePoint(x: 20.5, y: y), ScenePoint(x: 80.5, y: y)])))
        }
        return paths + [.trimPaths(TrimBatchFixtures.source(0.25, 0.75, mode: mode)),
            .stroke(StrokeFixtures.make(width: .init(constant: 8), color: .init(constant: .defaultFill)))]
    }
}
