import Testing
@testable import pag_swift

/// 形状属性动画的纯语义模板与采样辅助；不构造任何PAG字节或新增生产兼容层。
enum ShapePropertyFixtures {
    /// 所有轨道均缺省为源码默认值；调用者只替换当前测试关注的字段。
    static func group(anchor: SourceProperty<ScenePoint> = .init(constant: .zero),
                      position: SourceProperty<ScenePoint> = .init(constant: .zero),
                      scale: SourceProperty<ScenePoint> = .init(constant: .one),
                      skew: SourceProperty<Double> = .init(constant: 0),
                      skewAxis: SourceProperty<Double> = .init(constant: 0),
                      rotation: SourceProperty<Double> = .init(constant: 0),
                      opacity: SourceProperty<UInt8> = .init(constant: 255)) -> SourceShapeTransformProperties {
        SourceShapeTransformProperties(anchor: anchor, position: position, scale: scale, skew: skew,
            skewAxis: skewAxis, rotation: rotation, opacity: opacity)
    }

    /// 默认20×20矩形，以中心位置和半径轨道验证既有几何核心。
    static func rectangle(size: SourceProperty<ScenePoint> = .init(constant: ScenePoint(x: 20, y: 20)),
                          position: SourceProperty<ScenePoint> = .init(constant: .zero),
                          roundness: SourceProperty<Double> = .init(constant: 0)) -> SourceShape {
        .rectangle(SourceRectangle(reversed: false, size: size, position: position, roundness: roundness))
    }

    /// 默认不透明红色填充，仅改变颜色/alpha仍须复用几何。
    static func fill(color: SourceProperty<SceneColor> = .init(constant: .defaultFill),
                     opacity: SourceProperty<UInt8> = .init(constant: 255)) -> SourceShape {
        .fill(SourceFill(color: color, opacity: opacity))
    }

    /// 建立0...10源帧轨道；Hold用于稳定几何之间切换，不能作为导出器字节证据。
    static func track<Value: Sendable>(_ start: Value, _ end: Value,
                                       easing: SourceEasing = .linear) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10, startValue: start,
            endValue: end, easing: easing, spatialCurve: nil)])
    }

    /// 在独立预算内采样指定源帧，可借用至多四份同源旧采样。
    static func prepare(_ elements: [SourceShape], frame: Int64 = 0,
                        reuse: [PreparedShapeLayer] = []) throws -> PreparedShapeLayer {
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        return try ShapePreparation.prepare(elements, at: frame, reusing: reuse, budget: &budget)
    }

    /// 取出准备后的paint顺序，忽略整体透明度的成对边界指令。
    static func paints(_ layer: PreparedShapeLayer) -> [ShapePaint] {
        layer.instructions.compactMap { if case .fill(let paint) = $0 { paint } else { nil } }
    }

    /// 使用稳定源paint序号查找几何；透明paint缺失时测试明确失败。
    static func geometry(_ layer: PreparedShapeLayer, ordinal: Int) throws -> ShapeGeometry {
        layer.geometries[try #require(layer.geometryIndicesByPaint[ordinal])]
    }

    /// 一个源形状层由多个预合成实例引用，start用于验证不能再次减去图层起点。
    static func file(_ elements: [SourceShape], offsets: [Int64] = [0, 5], start: Int64 = 0) throws -> PAGFile {
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, start: start,
            duration: 30 - start, content: .shape(elements))])
        let layers = offsets.enumerated().map { index, offset in
            SceneFixtures.layer(UInt32(index + 10), content: .precomposition(id: 1, startFrame: offset))
        }
        return try SceneFixtures.build([child, SceneFixtures.composition(2, layers: layers)])
    }
}
