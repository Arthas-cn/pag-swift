@testable import pag_swift

/// 渐变接入的纯语义场景，不生成PAG字节或提前开放正式标签。
enum GradientShapeFixtures {
    /// 可单独替换材料轨道；缺省从(10,10)到(50,10)，颜色由调用者保留引用身份。
    static func gradient(kind: SourceGradientKind = .linear,
                         start: SourceProperty<ScenePoint> = .init(constant: ScenePoint(x: 10, y: 10)),
                         end: SourceProperty<ScenePoint> = .init(constant: ScenePoint(x: 50, y: 10)),
                         colors: SourceProperty<SourceGradientColors>? = nil,
                         opacity: SourceProperty<UInt8> = .init(constant: 255)) -> SourceGradient {
        SourceGradient(kind: kind, start: start, end: end,
                       colors: colors ?? .init(constant: GradientColorFixtures.colors()), opacity: opacity)
    }

    /// 默认20×20可见矩形；位置与渐变方向独立，便于核对两种坐标来源。
    static func elements(_ gradient: SourceGradient, stroke: Bool = false) -> [SourceShape] {
        [ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 30, y: 30))),
         stroke ? .gradientStroke(self.stroke(gradient)) : .gradientFill(.init(compositeOrder: .belowPrevious, gradient: gradient))]
    }

    /// 普通描边样式的渐变载体，不伪造SourceStroke以获取几何参数。
    static func stroke(_ gradient: SourceGradient,
                       width: SourceProperty<Double> = .init(constant: 4),
                       miter: SourceProperty<Double> = .init(constant: 4),
                       dashes: SourceDashes? = nil) -> SourceGradientStroke {
        SourceGradientStroke(compositeOrder: .abovePrevious, gradient: gradient, cap: .square, join: .miter,
                             miterLimit: miter, width: width, dashes: dashes)
    }

    /// 八条轨道逐一变化，其余值固定；颜色动画有独立末值，几何轨道只影响outline。
    static func animated(_ field: Int) throws -> [SourceShape] {
        let colors = GradientColorFixtures.colors()
        let other = GradientColorFixtures.colors(rgb: [(0, GradientColorFixtures.green), (1, GradientColorFixtures.blue)])
        let material = try gradient(
            start: field == 0 ? ShapePropertyFixtures.track(ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 10)) : .init(constant: .zero),
            end: field == 1 ? ShapePropertyFixtures.track(ScenePoint(x: 50, y: 10), ScenePoint(x: 80, y: 10)) : .init(constant: ScenePoint(x: 50, y: 0)),
            colors: field == 2 ? ShapePropertyFixtures.track(colors, other) : .init(constant: colors),
            opacity: field == 3 ? ShapePropertyFixtures.track(UInt8(100), UInt8(200)) : .init(constant: 255))
        let scalar = try ShapePropertyFixtures.track(4.0, 8.0)
        let dashes = try SourceDashes(offset: field == 6 ? scalar : .init(constant: 0),
                                     intervals: [field == 7 ? scalar : .init(constant: 10)])
        return [ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 30, y: 30))),
                .gradientStroke(stroke(material, width: field == 5 ? scalar : .init(constant: 4),
                    miter: field == 4 ? scalar : .init(constant: 4), dashes: dashes))]
    }

    /// 颜色表逐项不同且解析容量不足，供跳过、退化和显式失败顺序验收。
    static func excessiveColors() -> SourceGradientColors {
        GradientColorFixtures.colors(rgb: (0..<20).map { (Float($0) / 19, SceneColor(red: UInt8($0 * 10), green: 0, blue: 0)) })
    }
}
