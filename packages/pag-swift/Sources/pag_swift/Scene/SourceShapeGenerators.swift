/// 有源码枚举证据的PolyStar生成方式；未知原始值由读取边界拒绝。
enum SourcePolyStarKind: UInt8, Sendable {
    /// 内外半径交替的星形，分数点数保留不完整顶点。
    case star = 0
    /// 只使用外半径的多边形，点数向下取整。
    case polygon = 1
}

/// Ellipse的不可变源轨道；解码不生成路径，尺寸符号和退化值留给几何消费者。
struct SourceEllipse: Sendable {
    /// 不随时间变化的反向绕序BitFlag，负尺寸不改变此值。
    let reversed: Bool
    /// 两轴独立时间缓动的尺寸，保留负值和零值。
    let size: SourceProperty<ScenePoint>
    /// 椭圆中心的Spatial位置轨道。
    let position: SourceProperty<ScenePoint>

    /// 任一属性含关键帧即为动画，首末值相同也不能降为静态。
    var isAnimated: Bool { size.isAnimated || position.isAnimated }
}

/// PolyStar的完整源属性；Polygon也保留内半径/内圆度，避免跳过源字段或轨道错误。
struct SourcePolyStar: Sendable {
    /// 源文件的非动画生成方式，决定点数和半径的消费规则。
    let kind: SourcePolyStarKind
    /// 源角度步进的反向标志，不通过倒序路径替代。
    let reversed: Bool
    /// 浮点顶点数，允许分数和非正值，整数范围在生成路径时校验。
    let points: SourceProperty<Double>
    /// 图形中心的Spatial轨道。
    let position: SourceProperty<ScenePoint>
    /// 以度保存的整体旋转，首角按源公式减90度。
    let rotation: SourceProperty<Double>
    /// 星形内半径，不取绝对值；Polygon仍读取与求值此属性。
    let innerRadius: SourceProperty<Double>
    /// 星形外半径或多边形半径，不强制大于内半径。
    let outerRadius: SourceProperty<Double>
    /// 星形内顶点的原始圆度比例，不夹值或再除100。
    let innerRoundness: SourceProperty<Double>
    /// 外顶点的原始圆度比例，零表示该类顶点不产生圆度控制偏移。
    let outerRoundness: SourceProperty<Double>

    /// 七条属性任一含关键帧即为动画，包括Polygon当前不用的内半径与内圆度。
    var isAnimated: Bool {
        points.isAnimated || position.isAnimated || rotation.isAnimated || innerRadius.isAnimated ||
            outerRadius.isAnimated || innerRoundness.isAnimated || outerRoundness.isAnimated
    }
}
