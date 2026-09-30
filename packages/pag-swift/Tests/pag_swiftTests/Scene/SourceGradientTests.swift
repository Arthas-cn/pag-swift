import Testing
@testable import pag_swift

/// 渐变不可变源模型的动画分类；语义轨道不冒充PAG文件字节。
struct SourceGradientTests {
    /// 共有四轨及width/miter/dash各轨逐一触发动画，同值关键帧也不能误判静态。
    @Test(arguments: 0..<8)
    func everyTrackKeepsAnimationPresence(_ index: Int) throws {
        let source = try stroke(animated: index)
        #expect(source.isAnimated)
        #expect(source.gradient.isAnimated == (index < 4))
    }

    /// 全常量保持静态；同一颜色关键值对象在常量和相邻动画边界保持身份，不复制成深比较缓存键。
    @Test func constantValuesAndReferenceIdentityAreRetained() throws {
        let source = try stroke(animated: -1)
        #expect(source.isAnimated == false)
        let colors = source.gradient.colors.initialValue
        let track = try ShapePropertyFixtures.track(colors, colors)
        #expect(track.initialValue === colors)
        #expect(track.keyframes[0].startValue === colors && track.keyframes[0].endValue === colors)
    }

    /// 在纯语义模型中指定一条同值轨道，负线宽保留给消费层而不是在源模型修正。
    private func stroke(animated index: Int) throws -> SourceGradientStroke {
        let colors = SourceGradientColors(alphaStops: [.init(position: 0, midpoint: 0.5, opacity: 128)],
            colorStops: [.init(position: 0, midpoint: 0.5, color: .defaultFill)])
        let gradient = try SourceGradient(kind: .linear,
            start: property(ScenePoint.zero, animated: index == 0),
            end: property(ScenePoint(x: 10, y: 10), animated: index == 1),
            colors: property(colors, animated: index == 2), opacity: property(UInt8(128), animated: index == 3))
        return try SourceGradientStroke(compositeOrder: .abovePrevious, gradient: gradient,
            cap: .square, join: .bevel, miterLimit: property(4, animated: index == 4),
            width: property(-1, animated: index == 5),
            dashes: SourceDashes(offset: property(0, animated: index == 6),
                                 intervals: [property(10, animated: index == 7)]))
    }

    /// 同值关键帧只验证源轨道存在性；真正颜色插值属于后续门禁②。
    private func property<Value: Sendable>(_ value: Value, animated: Bool) throws -> SourceProperty<Value> {
        if animated { return try ShapePropertyFixtures.track(value, value) }
        return SourceProperty(constant: value)
    }
}
