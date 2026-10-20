import Testing
@testable import pag_swift

/// 独立Python原始轨道探针导出的完整真实层金值；不以生产分析结果自举期望。
struct ShapeContentFileRangesTests {
    /// 静态、仅外变换、Trim及内部组/路径动画均按所属合成帧排除，再转层局部时间。
    @Test(arguments: [
        ("red.pag", UInt32(20010), UInt32(20013), Int64(0), Int64(450), [Int64(0)...449]),
        ("fans.pag", 2076, 2098, 0, 25, [0...24]),
        ("refreshing.pag", 1284, 1293, 34, 5, []),
        ("list/14.pag", 0, 22, -20, 300, [0...28, 60...299]),
        ("list/16.pag", 0, 3, 57, 88, [0...7, 70...87])
    ])
    func realLayersMatchIndependentRanges(name: String, compositionID: UInt32, layerID: UInt32,
                                          start: Int64, duration: Int64, expected: [ClosedRange<Int64>]) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let composition = try #require(file.storage.compositions.first { $0.id == compositionID })
        let layer = try #require(composition.layers.first { $0.id == layerID })
        #expect(layer.startFrame == start && layer.durationFrames == duration)
        var budget = FramePlanBudget(limit: 8 * 1024 * 1024)
        #expect(try ShapeContentRanges.make(for: layer, budget: &budget).ranges == expected)
    }

    /// list/16的真实opacity单独排除，防止被更宽的path动画区间覆盖后漏测该属性。
    @Test func realGroupOpacityHasIndependentBoundaryEvidence() throws {
        let bytes = try PAGFixtures.data(named: "list/16.pag").subdata(in: 4753..<5003)
        var reader = PAGByteReader(data: bytes)
        var decoder = TrimFixtures.decoder()
        guard case .group(let transform, _) = try decoder.readShape(code: 15, reader: &reader, depth: 0) else {
            Issue.record("已取证的真实载荷必须为ShapeGroup")
            return
        }
        try StaticAttributes.requireEnd(of: reader)
        #expect(transform.opacity.keyframes.map(\.startFrame) == [66, 67, 125])
        #expect(transform.opacity.keyframes.map(\.endFrame) == [67, 125, 126])
        var budget = FramePlanBudget(limit: 1_000_000)
        let source = try StaticFrameRanges(startFrame: 57, duration: 88, budget: &budget)
        let result = try source.excluding(transform.opacity, budget: &budget).relative(to: 57, budget: &budget)
        #expect(result.ranges == [0...8, 69...87])
    }
}
