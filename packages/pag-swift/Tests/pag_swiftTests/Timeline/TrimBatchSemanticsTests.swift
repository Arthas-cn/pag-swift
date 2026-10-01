import Testing
@testable import pag_swift

/// 两模式批次行为的固定坐标金值；与纯曲线提取测试分开验证路径间分配和作用顺序。
struct TrimBatchSemanticsTests {
    /// 每条路径独立比例与全局比例有不同结果；Individual相触清空，输出槽位保持源顺序。
    @Test func modesAllocateDifferentDistances() throws {
        let inputs: [ShapeContour] = try [10.0, 30].map { .path(try TrimBatchFixtures.line($0), matrix: .identity) }
        let simultaneous = try TrimBatchFixtures.batch(inputs, TrimBatchFixtures.source(0.25, 0.5))
        #expect(try simultaneous.outputs.map { try TrimBatchFixtures.path($0).path.points.map(\.x) } == [[2.5, 5], [7.5, 15]])
        let individual = try TrimBatchFixtures.batch(inputs, TrimBatchFixtures.source(0.25, 0.5, mode: .individually))
        #expect(try individual.outputs.map { try TrimBatchFixtures.path($0).path.points.map(\.x) } == [[], [0, 10]])
    }

    /// Simultaneous保留端点零Line，Individual按源码先过滤相触区间；不可共用交集快路径。
    @Test(arguments: [false, true]) func touchingRangesDifferByMode(_ upperSeam: Bool) throws {
        let input: [ShapeContour] = [.path(try TrimBatchFixtures.line(10), matrix: .identity)]
        let start = upperSeam ? 1.0 : -0.25, end = upperSeam ? 1.25 : 0
        for mode in [SourceTrimMode.simultaneously, .individually] {
            let result = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(start, end, mode: mode))
            let path = try TrimBatchFixtures.path(result.outputs[0]).path
            let expected: [Double] = mode == .simultaneously ? (upperSeam ? [10, 10, 0, 2.5] : [7.5, 10, 0, 0])
                : (upperSeam ? [0, 2.5] : [7.5, 10])
            #expect(path.points.map(\.x) == expected)
            #expect(path.verbs == (mode == .simultaneously ? [.move, .line, .move, .line] : [.move, .line]))
        }
    }

    /// 反向Individual必须倒序Float求和；Double总和或先按正序计长会改变大路径终点。
    @Test func reversedIndividualUsesReversedFloatSum() throws {
        let inputs: [ShapeContour] = try [16_777_216.0, 1, 1].enumerated().map {
            .path(try TrimBatchFixtures.line($0.element, y: Double($0.offset)), matrix: .identity)
        }
        let result = try TrimBatchFixtures.batch(inputs, TrimBatchFixtures.source(1, 0.5, mode: .individually))
        #expect(try result.outputs.map { try TrimBatchFixtures.path($0).path.points.map(\.x) } == [[16_777_216, 8_388_609], [1, 0], [1, 0]])
        for (index, output) in result.outputs.enumerated() {
            #expect(try TrimBatchFixtures.path(output).path.points.allSatisfy { $0.y == Double(index) })
        }
    }

    /// 零长度完整路径在两模式保留，反向也保留尾随Move；empty则清空全部。
    @Test(arguments: [SourceTrimMode.simultaneously, .individually])
    func zeroLengthAndEmptyHaveDistinctSemantics(_ mode: SourceTrimMode) throws {
        let path = try SourcePath(verbs: [.move, .line, .move, .close], points: [.zero, .zero, ScenePoint(x: 5, y: 7)])
        let input: [ShapeContour] = [.path(path, matrix: .identity)]
        let forward = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0.25, 0.5, mode: mode))
        #expect(try TrimBatchFixtures.path(forward.outputs[0]).path.verbs == [.move, .line, .move, .close])
        let reverse = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0.75, 0.25, mode: mode))
        #expect(try TrimBatchFixtures.path(reverse.outputs[0]).path.verbs == [.move, .close, .move, .line])
        #expect(try TrimBatchFixtures.path(reverse.outputs[0]).path.points.first == ScenePoint(x: 5, y: 7))
        let empty = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0.5, 0.5, mode: mode))
        #expect(try TrimBatchFixtures.path(empty.outputs[0]).path.verbs.isEmpty)
        #expect(empty.measurements == nil)
    }

    /// 缺省end100重复首个可测轮廓两次；精确unchanged保留完整多轮廓引用，反向先换首轮廓。
    @Test func defaultsAndUnchangedPreserveDifferentTopology() throws {
        let path = try SourcePath(verbs: [.move, .line, .move, .line], points: [.zero, ScenePoint(x: 10, y: 0),
            ScenePoint(x: 20, y: 0), ScenePoint(x: 40, y: 0)])
        let input: [ShapeContour] = [.path(path, matrix: .identity)]
        let unchanged = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source())
        #expect(unchanged.outputs[0].matches(input[0]) && unchanged.measurements == nil)
        let repeated = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0, 100))
        #expect(try TrimBatchFixtures.path(repeated.outputs[0]).path.points.map(\.x) == [0, 10, 0, 10])
        let reverse = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(1, 0))
        #expect(reverse.measurements == nil)
        #expect(try TrimBatchFixtures.path(reverse.outputs[0]).path.points.map(\.x) == [40, 20, 10, 0])
        let cut = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(1, 0.5))
        #expect(try TrimBatchFixtures.path(cut.outputs[0]).path.points.map(\.x) == [40, 30])
    }
}
