import Testing
@testable import pag_swift

/// 新路径生成器的不可变源轨道分类；纯语义模型不声称是导出器PAG字节。
struct SourceShapeGeneratorTests {
    /// 尺寸和位置的同值关键帧各自保留动画存在性，负/零尺寸不被源模型夹成正数。
    @Test(arguments: 0..<2)
    func ellipseTracksRemainAnimated(_ index: Int) throws {
        let size = ScenePoint(x: -20, y: 0)
        let source = try SourceEllipse(reversed: true, size: property(size, animated: index == 0),
            position: property(.zero, animated: index == 1))
        #expect(source.isAnimated && source.reversed && source.size.initialValue == size)
    }

    /// 七条轨道逐一判动画；Polygon也保留当前几何不用的内半径/内圆度轨道。
    @Test(arguments: [SourcePolyStarKind.star, .polygon], 0..<7)
    func everyPolyStarTrackRemainsAnimated(_ kind: SourcePolyStarKind, _ index: Int) throws {
        let source = try polyStar(kind: kind, animatedIndex: index)
        #expect(source.isAnimated && source.kind == kind && source.reversed)
        #expect(source.points.initialValue == 2.5 && source.innerRadius.initialValue == -1)
        #expect(source.innerRoundness.initialValue == -0.5 && source.outerRoundness.initialValue == 2)
    }

    /// 只有全部常量才能判静态，kind与reversed不单独制造动画。
    @Test func constantGeneratorsRemainStatic() throws {
        let ellipse = SourceEllipse(reversed: true, size: .init(constant: .zero), position: .init(constant: .zero))
        #expect(ellipse.isAnimated == false)
        #expect(try polyStar(kind: .star, animatedIndex: -1).isAnimated == false)
        #expect(try polyStar(kind: .polygon, animatedIndex: -1).isAnimated == false)
    }

    /// 指定一条同值动画，其他属性是刻意带分数、负半径和未夹圆度的常量。
    private func polyStar(kind: SourcePolyStarKind, animatedIndex: Int) throws -> SourcePolyStar {
        try SourcePolyStar(kind: kind, reversed: true,
            points: property(2.5, animated: animatedIndex == 0),
            position: property(.zero, animated: animatedIndex == 1),
            rotation: property(90, animated: animatedIndex == 2),
            innerRadius: property(-1, animated: animatedIndex == 3),
            outerRadius: property(2, animated: animatedIndex == 4),
            innerRoundness: property(-0.5, animated: animatedIndex == 5),
            outerRoundness: property(2, animated: animatedIndex == 6))
    }

    /// 同值轨道仍包含关键帧，避免测试只覆盖首值改变这种较弱的动画识别。
    private func property<Value: Sendable>(_ value: Value, animated: Bool) throws -> SourceProperty<Value> {
        if animated { return try ShapePropertyFixtures.track(value, value) }
        return SourceProperty(constant: value)
    }
}
