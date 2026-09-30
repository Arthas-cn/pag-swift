@testable import pag_swift

/// 测试语义场景的常量构造便利方法；生产源模型始终只有统一轨道表达。
extension SourceShape {
    /// 将已知静态组变换转换为常量轨道，保留测试的矩阵意图和子元素顺序。
    static func group(_ transform: SourceShapeTransform, _ children: [SourceShape]) -> SourceShape {
        .group(SourceShapeTransformProperties(
            anchor: SourceProperty(constant: transform.base.anchor),
            position: SourceProperty(constant: transform.base.position),
            scale: SourceProperty(constant: transform.base.scale),
            skew: SourceProperty(constant: transform.skew),
            skewAxis: SourceProperty(constant: transform.skewAxis),
            rotation: SourceProperty(constant: transform.base.rotation),
            opacity: SourceProperty(constant: transform.base.opacity)), children)
    }

    /// 建立常量矩形语义夹具，不生成或冒充真实PAG字节。
    static func rectangle(reversed: Bool, size: ScenePoint, position: ScenePoint, roundness: Double) -> SourceShape {
        .rectangle(SourceRectangle(reversed: reversed, size: SourceProperty(constant: size),
            position: SourceProperty(constant: position), roundness: SourceProperty(constant: roundness)))
    }

    /// 建立静态Below填充语义夹具；颜色与alpha仍保存为独立常量轨道。
    static func fill(color: SceneColor, opacity: UInt8) -> SourceShape {
        .fill(SourceFill(color: SourceProperty(constant: color), opacity: SourceProperty(constant: opacity)))
    }
}
