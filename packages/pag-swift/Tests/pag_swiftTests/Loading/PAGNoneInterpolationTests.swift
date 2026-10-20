import Foundation
import Testing
@testable import pag_swift

/// 原始None与Linear的身份、数值和静态范围差异；只使用有源码布局的属性子流。
struct PAGNoneInterpolationTests {
    /// 两种原始类型都线性求值，但None按起止点分割静态范围，不能解码成Linear或Hold。
    @Test func scalarIdentityAndStaticBehaviorRemainDistinct() throws {
        for raw: UInt8 in [0, 1] {
            // ReadKeyframes一段、两位kind对齐、ReadTime20/40、Float0/10、ReadTimeEase位宽1。
            var reader = PAGByteReader(data: Data([1, raw, 20, 40, 0, 0, 0, 0, 0, 0, 32, 65, 0]))
            var decoder = TrimFixtures.decoder()
            let property = try decoder.readScalarProperty(.init(exists: true, isAnimated: true, hasSpatial: false),
                                                          defaultValue: 0, reader: &reader)
            try StaticAttributes.requireEnd(of: reader)
            let key = try #require(property.keyframes.first)
            switch (raw, key.easing) {
            case (0, .none), (1, .linear): break
            default: Issue.record("原始None和Linear身份必须分别保留")
            }
            #expect(property.isAnimated)
            #expect(try PropertyEvaluation.scalar(property, at: 30) == 5)
            var budget = FramePlanBudget(limit: 10_000)
            let full = try StaticFrameRanges(startFrame: 0, duration: 100, budget: &budget)
            let expected: [ClosedRange<Int64>] = raw == 0 ? [0...19, 20...39, 40...99] : [0...19, 40...99]
            #expect(try full.excluding(property, budget: &budget).ranges == expected)
            let trim = SourceShape.trimPaths(.init(start: property, end: .init(constant: 1),
                offset: .init(constant: 0), mode: .simultaneously))
            #expect(try ShapeRangeFixtures.ranges([trim]).ranges == expected)
        }
    }

    /// Frame属性的None保留原始帧值；素材段中点仍线性，不受新的静态范围分支影响。
    @Test func frameMappingKeepsLinearNumericProgress() throws {
        var reader = PAGByteReader(data: Data([1, 0, 20, 40, 0, 10, 0]))
        var decoder = TrimFixtures.decoder()
        let property = try decoder.readFrameProperty(.init(exists: true, isAnimated: true, hasSpatial: false), reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        let key = try #require(property.keyframes.first)
        guard case .none = key.easing else { Issue.record("Frame原始None被合并"); return }
        let segment = ImageTimeSegment(start: key.startFrame, end: key.endFrame,
            first: Float(key.startValue), last: Float(key.endValue), easing: key.easing)
        #expect(try segment.value(at: 30) == 5)
    }

    /// None路径和空间Point仍插值，不能误用Hold的保持起点分支。
    @Test func pathAndSpatialPointAreNotHeld() throws {
        let path = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 20,
            startValue: ShapePathFixtures.square(10), endValue: ShapePathFixtures.square(30),
            easing: .none, spatialCurve: nil)])
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try PropertyEvaluation.path(path, at: 10, budget: &budget).points[1].x == 30)
        var curveBudget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: .zero, control2: .one, end: .one,
                                         precision: 0.05, budget: &curveBudget)
        let point = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 20,
            startValue: ScenePoint.zero, endValue: .one, easing: .none, spatialCurve: curve)])
        #expect(try PropertyEvaluation.point(point, at: 10) == ScenePoint(x: 0.5, y: 0.5))
    }
}
