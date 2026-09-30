import Testing
@testable import pag_swift

/// 统一形状轨道模型的动画存在性和源帧求值；纯语义数据不冒充导出器二进制。
struct SourceShapePropertiesTests {
    /// 七种单独轨道即使首末值相同也必须判为动画，包含真实资源尚未覆盖的anchor与skewAxis。
    @Test(arguments: 0..<7)
    func eachGroupTrackRetainsAnimation(_ index: Int) throws {
        let source = try makeGroup(animatedIndex: index)
        #expect(source.isAnimated)
        let value = try source.value(at: 40)
        #expect(value.base.anchor == .zero && value.base.position == .zero && value.base.scale == .one)
        #expect(value.base.rotation == 0 && value.base.opacity == 255 && value.skew == 0 && value.skewAxis == 0)
    }

    /// 矩形的三个属性各自决定动画存在性；reversed独立保存，零圆角初值不抹去轨道。
    @Test(arguments: 0..<3)
    func eachRectangleTrackRetainsAnimation(_ index: Int) throws {
        let rectangle = try SourceRectangle(reversed: true,
            size: property(ScenePoint(x: -100, y: 0), animated: index == 0),
            position: property(.zero, animated: index == 1), roundness: property(0, animated: index == 2))
        #expect(rectangle.isAnimated && rectangle.reversed)
        #expect(rectangle.size.initialValue == ScenePoint(x: -100, y: 0))
    }

    /// 初值是默认红色或透明零的填充轨道仍是动画，全部常量才可以判为静态。
    @Test func fillAndConstantClassification() throws {
        let color = try SourceFill(color: property(.defaultFill, animated: true), opacity: property(0, animated: false))
        let opacity = try SourceFill(color: property(.defaultFill, animated: false), opacity: property(0, animated: true))
        let constant = SourceFill(color: .init(constant: .defaultFill), opacity: .init(constant: 0))
        let rectangle = SourceRectangle(reversed: false, size: .init(constant: .one),
            position: .init(constant: .zero), roundness: .init(constant: 0))
        #expect(color.isAnimated && opacity.isAnimated)
        #expect(constant.isAnimated == false && rectangle.isAnimated == false)
        #expect(try makeGroup(animatedIndex: -1).isAnimated == false)
    }

    /// 所有变换分量在同一源合成帧求值，30...50的中点是40，范围外取首末值。
    @Test func groupValuesUseSourceCompositionFrame() throws {
        let source = try SourceShapeTransformProperties(
            anchor: track(ScenePoint(x: 2, y: 4), ScenePoint(x: 6, y: 8)),
            position: track(ScenePoint(x: 10, y: 20), ScenePoint(x: 30, y: 40)),
            scale: track(ScenePoint(x: -2, y: 0), ScenePoint(x: 4, y: 2)),
            skew: track(10, 30), skewAxis: track(20, 40), rotation: track(30, 90),
            opacity: track(UInt8(0), UInt8(200)))
        let value = try source.value(at: 40)
        #expect(value.base == SourceTransform(anchor: ScenePoint(x: 4, y: 6), position: ScenePoint(x: 20, y: 30),
            scale: ScenePoint(x: 1, y: 1), rotation: 60, opacity: 100))
        #expect(value.skew == 20 && value.skewAxis == 30)
        #expect(try source.value(at: 0).base.position == ScenePoint(x: 10, y: 20))
        #expect(try source.value(at: 100).base.position == ScenePoint(x: 30, y: 40))
    }

    /// 动态分类包含内部三类新增属性，即使组为空或填充首帧透明也不能按首帧可见性降为静态。
    @Test func preparationClassificationRetainsNewTracks() throws {
        let group = try SourceShape.group(makeGroup(animatedIndex: 6), [])
        let rectangle = try SourceShape.rectangle(SourceRectangle(reversed: false, size: property(.one, animated: true),
            position: .init(constant: .zero), roundness: .init(constant: 0)))
        let fill = try SourceShape.fill(SourceFill(color: .init(constant: .defaultFill), opacity: property(0, animated: true)))
        for element in [group, rectangle, fill] {
            var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
            #expect(try ShapePreparation.isAnimated([element], budget: &budget))
        }
    }

    /// 即使全是常量，预取消求值也不能发布变换；有限Float端值的段内插值溢出明确失败。
    @Test func cancellationAndInterpolationOverflowFail() async throws {
        let source = try makeGroup(animatedIndex: -1)
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask { _ = try source.value(at: 0) }
                for try await _ in group {}
            }
        }
        let largest = Double(Float.greatestFiniteMagnitude)
        let overflow = try SourceShapeTransformProperties(anchor: source.anchor, position: source.position, scale: source.scale,
            skew: track(-largest, largest), skewAxis: source.skewAxis, rotation: source.rotation, opacity: source.opacity)
        #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) { try overflow.value(at: 40) }
    }

    /// 指定一个组字段为同值动画，其他均为源码默认常量；-1表示全静态。
    private func makeGroup(animatedIndex: Int) throws -> SourceShapeTransformProperties {
        try SourceShapeTransformProperties(anchor: property(.zero, animated: animatedIndex == 0),
            position: property(.zero, animated: animatedIndex == 1), scale: property(.one, animated: animatedIndex == 2),
            skew: property(0, animated: animatedIndex == 3), skewAxis: property(0, animated: animatedIndex == 4),
            rotation: property(0, animated: animatedIndex == 5), opacity: property(255, animated: animatedIndex == 6))
    }

    /// 构造相同初末值的轨道以验证存在性；常量分支不创建关键帧。
    private func property<Value: Sendable>(_ value: Value, animated: Bool) throws -> SourceProperty<Value> {
        try animated ? track(value, value) : SourceProperty(constant: value)
    }

    /// 建立源帧30...50的纯语义线性轨道，独立覆盖未出现在真实文件中的属性组合。
    private func track<Value: Sendable>(_ start: Value, _ end: Value) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 30, endFrame: 50, startValue: start,
            endValue: end, easing: .linear, spatialCurve: nil)])
    }
}
