import Testing
@testable import pag_swift

/// 真实导出文件中的零跨度关键帧及确定性端点选择，不允许空区间进入插值除法。
struct PAGZeroSpanTests {
    /// list/17的opacity包含尾部[225,225]和独立[11,11]，均完整读取而不是判成倒序。
    @Test func readsRealZeroSpanTransforms() throws {
        let data = try PAGFixtures.data(named: "list/17.pag")
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 4_000_000))
        var first = PAGByteReader(data: data.subdata(in: 108..<298))
        let long = try decoder.readTransform(reader: &first)
        try StaticAttributes.requireEnd(of: first)
        #expect(long.opacity.keyframes.count == 23)
        let last = try #require(long.opacity.keyframes.last)
        #expect(last.startFrame == 225 && last.endFrame == 225)
        var second = PAGByteReader(data: data.subdata(in: 3450..<3480))
        let single = try decoder.readTransform(reader: &second)
        try StaticAttributes.requireEnd(of: second)
        let point = try #require(single.opacity.keyframes.first)
        #expect(single.opacity.keyframes.count == 1 && point.startFrame == 11 && point.endFrame == 11)
        #expect(point.startValue == 7 && point.endValue == 255)
        for frame: Int64 in [10, 11, 12, 11, 10, 12] {
            #expect(try single.value(at: frame).opacity == (frame <= 11 ? 7 : 255))
        }
    }

    /// 标量、Point和Opacity在零跨度只读取端值，包含Int64边界且不会产生NaN或除零。
    @Test func allValueKindsKeepZeroSpanEndpoints() throws {
        let scalar = try SourceProperty(keyframes: [keyframe(11, 11, 2.0, 3.0)])
        let point = try SourceProperty(keyframes: [keyframe(11, 11, ScenePoint.zero, ScenePoint.one)])
        let opacity = try SourceProperty(keyframes: [keyframe(11, 11, UInt8(7), 255)])
        for frame: Int64 in [.min, 10, 11, 12, .max] {
            #expect(try PropertyEvaluation.scalar(scalar, at: frame) == (frame <= 11 ? 2 : 3))
            #expect(try PropertyEvaluation.point(point, at: frame) == (frame <= 11 ? .zero : .one))
            #expect(try PropertyEvaluation.opacity(opacity, at: frame) == (frame <= 11 ? 7 : 255))
        }
        let extreme = try SourceProperty(keyframes: [keyframe(Int64.max, Int64.max, 4.0, 5.0)])
        #expect(try PropertyEvaluation.scalar(extreme, at: .max) == 4)
    }

    /// 真实零跨度opacity进入共同FramePlan，端点及后继帧分别得到7/255与1，不冻结根时间。
    @Test func realZeroSpanOpacityReachesFramePlan() async throws {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
        var reader = PAGByteReader(data: try PAGFixtures.data(named: "list/17.pag").subdata(in: 3450..<3480))
        let transform = try decoder.readTransform(reader: &reader)
        let input = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        let image = SourceImage(id: 1, image: input, logicalSize: input.size, scaleFactor: 1, anchor: .zero)
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, transform: transform, content: .image(1))])
        let file = try SceneFixtures.build([source], resources: SourceResources(images: [1: image]))
        let scene = try await PreparedScene.prepare(file.composition)
        for index: Int64 in [10, 11, 12] {
            let time = try SceneValidator.time(frame: index, rate: 30)
            let prepared = try await FramePlanner.prepare(scene, at: time, targetSize: file.composition.size, scale: 1, mode: .none)
            let images = prepared.plan.commands.compactMap { if case .image(let image) = $0 { image } else { nil } }
            #expect(images.count == 1 && images.first?.opacity == (index <= 11 ? Double(7) / 255 : 1))
            #expect(prepared.plan.time.frame == index)
        }
    }

    /// 开头、中间、末尾和连续零段均按右侧段/末段确定结果，并发乱序seek不受历史游标影响。
    @Test func zeroSpanPlacementHasDeterministicRandomAccess() async throws {
        let tracks = [
            try SourceProperty(keyframes: [keyframe(10, 10, 10.0, 20.0), keyframe(10, 20, 20.0, 30.0)]),
            try SourceProperty(keyframes: [keyframe(0, 10, 0.0, 10.0), keyframe(10, 10, 10.0, 20.0), keyframe(10, 20, 20.0, 30.0)]),
            try SourceProperty(keyframes: [keyframe(0, 10, 0.0, 10.0), keyframe(10, 10, 10.0, 20.0)]),
            try SourceProperty(keyframes: [keyframe(10, 10, 1.0, 2.0), keyframe(10, 10, 2.0, 3.0)])
        ]
        let expected: [[Double]] = [[10, 20, 21], [9, 20, 21], [9, 10, 20], [1, 2, 3]]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for track in tracks.indices {
                for offset in [2, 0, 1, 2, 1, 0] {
                    group.addTask {
                        let value = try PropertyEvaluation.scalar(tracks[track], at: Int64(offset + 9))
                        #expect(value == expected[track][offset])
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// 构造独立数值轨道，让SourceProperty负责时间校验；不生成PAG字节。
    private func keyframe<Value: Sendable>(_ start: Int64, _ end: Int64, _ a: Value, _ b: Value) -> SourceKeyframe<Value> {
        SourceKeyframe(startFrame: start, endFrame: end, startValue: a, endValue: b, easing: .linear, spatialCurve: nil)
    }
}
