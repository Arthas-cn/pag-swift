import CoreGraphics
import Testing
@testable import pag_swift

/// 有序普通蒙版Boolean的纯值网格、远场补集与资源失败，不借生产折叠器计算金值。
struct MaskBooleanTessellationTests {
    /// 两个部分重叠矩形分别执行四种几何运算，重叠区不能被重复绘制。
    @Test func orderedOperationsUseFinalGeometry() throws {
        let left = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let right = GeometryTestSupport.rectangle(5, 0, 10, 10)
        for (mode, area, overlap) in [
            (SourceMaskMode.add, 150.0, 1),
            (.subtract, 50.0, 0),
            (.intersect, 50.0, 1),
            (.difference, 100.0, 0),
            (.lighten, 150.0, 1),
            (.darken, 50.0, 1),
            (.accumulate, 150.0, 1)
        ] {
            let result = try prepare([.init(contours: [left], mode: .add, isInverted: false),
                                      .init(contours: [right], mode: mode, isInverted: false)])
            #expect(result.isInverted == false)
            #expect(GeometryTestSupport.area(result.mesh) == area)
            #expect(GeometryTestSupport.coverage(result.mesh, at: .init(x: 7.37, y: 4.61)) == overlap)
        }
    }

    /// 首项Difference/Intersect仍直接取路径；首项Subtract才翻转远场。
    @Test func firstModeOnlySubtractChangesInverse() throws {
        let rectangle = GeometryTestSupport.rectangle(0, 0, 10, 10)
        for mode in [SourceMaskMode.difference, .intersect, .darken] {
            let result = try prepare([.init(contours: [rectangle], mode: mode, isInverted: false)])
            #expect(result.isInverted == false)
            #expect(GeometryTestSupport.area(result.mesh) == 100)
        }
        let subtract = try prepare([.init(contours: [rectangle], mode: .subtract, isInverted: false)])
        #expect(subtract.isInverted)
        #expect(GeometryTestSupport.area(subtract.mesh) == 100)
    }

    /// 反向源项参与Boolean时远场也参与运算；结果网格表示补集的有限洞。
    @Test func inverseOperandsPreserveOutsideTruth() throws {
        let left = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let right = GeometryTestSupport.rectangle(5, 0, 10, 10)
        let union = try prepare([.init(contours: [left], mode: .add, isInverted: true),
                                 .init(contours: [right], mode: .add, isInverted: false)])
        #expect(union.isInverted)
        #expect(GeometryTestSupport.area(union.mesh) == 50)
        #expect(GeometryTestSupport.coverage(union.mesh, at: .init(x: 2.31, y: 4.79)) == 1)
        let intersection = try prepare([.init(contours: [left], mode: .add, isInverted: true),
                                        .init(contours: [right], mode: .intersect, isInverted: false)])
        #expect(intersection.isInverted == false)
        #expect(GeometryTestSupport.area(intersection.mesh) == 50)
        #expect(GeometryTestSupport.coverage(intersection.mesh, at: .init(x: 12.31, y: 4.79)) == 1)
    }

    /// 同源轮廓相消仅证明网格为空；此层不擅自推断PathKit是否会产生零verb。
    @Test func identicalXORHasNoFiniteArea() throws {
        let rectangle = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let result = try prepare([.init(contours: [rectangle], mode: .add, isInverted: false),
                                  .init(contours: [rectangle], mode: .difference, isInverted: false)])
        #expect(result.isInverted == false)
        #expect(result.mesh.vertices.isEmpty)
    }

    /// 仅共边或共点的路径不凭接触产生交集，共边XOR也不能留下重复内部覆盖。
    @Test func touchingEdgesAndPointsRemainFinite() throws {
        let first = GeometryTestSupport.rectangle(0, 0, 10, 10)
        for (second, sample) in [
            (GeometryTestSupport.rectangle(10, 0, 10, 10), ScenePoint(x: 15.37, y: 4.39)),
            (GeometryTestSupport.rectangle(10, 10, 10, 10), ScenePoint(x: 15.37, y: 14.39))
        ] {
            let intersection = try prepare([.init(contours: [first], mode: .add, isInverted: false),
                                            .init(contours: [second], mode: .intersect, isInverted: false)])
            #expect(intersection.mesh.vertices.isEmpty)
            let xor = try prepare([.init(contours: [first], mode: .add, isInverted: false),
                                   .init(contours: [second], mode: .difference, isInverted: false)])
            #expect(GeometryTestSupport.area(xor.mesh) == 200)
            #expect(GeometryTestSupport.coverage(xor.mesh, at: .init(x: 5.37, y: 4.39)) == 1)
            #expect(GeometryTestSupport.coverage(xor.mesh, at: sample) == 1)
        }
    }

    /// 路径各自的nonzero孔洞必须先求内部状态，再执行跨路径Union。
    @Test func separateWindingDoesNotMergeSources() throws {
        let outer = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let hole = GeometryTestSupport.rectangle(2, 2, 6, 6, reversed: true)
        let island = GeometryTestSupport.rectangle(3, 3, 4, 4)
        let result = try prepare([.init(contours: [outer, hole], mode: .add, isInverted: false),
                                  .init(contours: [island], mode: .add, isInverted: false)])
        #expect(GeometryTestSupport.area(result.mesh) == 80)
        #expect(GeometryTestSupport.coverage(result.mesh, at: .init(x: 3.71, y: 4.39)) == 1)
        #expect(GeometryTestSupport.coverage(result.mesh, at: .init(x: 2.37, y: 4.29)) == 0)
    }

    /// 扩张描边与原路径先按正并负差合成，再参与跨蒙版交集；描边孔洞不能和源路径绕数混用。
    @Test func signedExpansionUsesSeparateStrokeWindingBeforeOuterBoolean() throws {
        let original = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let outer = GeometryTestSupport.rectangle(-1, -1, 12, 12)
        let inner = GeometryTestSupport.rectangle(1, 1, 8, 8, reversed: true)
        let stroke = [outer, inner]
        let positive = try prepare([.init(contours: [original], strokeContours: stroke, expansion: 1,
                                          mode: .add, isInverted: false)])
        let negative = try prepare([.init(contours: [original], strokeContours: stroke, expansion: -1,
                                          mode: .add, isInverted: false)])
        #expect(GeometryTestSupport.area(positive.mesh) == 144)
        #expect(GeometryTestSupport.area(negative.mesh) == 64)
        #expect(GeometryTestSupport.coverage(positive.mesh, at: .init(x: -0.5, y: 4.5)) == 1)
        #expect(GeometryTestSupport.coverage(negative.mesh, at: .init(x: 0.5, y: 4.5)) == 0)
        let clip = GeometryTestSupport.rectangle(5, -2, 10, 14)
        let intersect = try prepare([
            .init(contours: [original], strokeContours: stroke, expansion: -1,
                  mode: .add, isInverted: false),
            .init(contours: [clip], mode: .intersect, isInverted: false)
        ])
        #expect(GeometryTestSupport.area(intersect.mesh) == 32)
        #expect(GeometryTestSupport.coverage(intersect.mesh, at: .init(x: 5.5, y: 4.5)) == 1)
    }

    /// 单项负扩张相消时有限网格为空；此纯几何层不擅自代替上游零verb显示判定。
    @Test func expansionCanCancelOwnFiniteFill() throws {
        let rectangle = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let result = try prepare([.init(contours: [rectangle], strokeContours: [rectangle],
                                        expansion: -1, mode: .add, isInverted: false)])
        #expect(result.mesh.vertices.isEmpty)
        #expect(!result.isInverted)
        #expect(throws: PAGError.invalidArgument("maskExpansion")) {
            try prepare([.init(contours: [rectangle], expansion: .infinity,
                               mode: .add, isInverted: false)])
        }
    }

    /// 零扩张直接沿用原路径；无关描边即使含非有限点或大量轮廓，也不得进入原点与工作预算。
    @Test func zeroExpansionIgnoresUnusedStrokeGeometry() throws {
        let rectangle = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let ignored = Array(repeating: [ScenePoint(x: .infinity, y: 0)], count: 1_000)
        var budget = try GeometryBudget(maximumWork: 200)
        let result = try MaskBooleanTessellation.prepare([
            .init(contours: [rectangle], strokeContours: ignored, expansion: 0,
                  mode: .add, isInverted: false)
        ], budget: &budget)
        #expect(GeometryTestSupport.area(result.mesh) == 100)
        #expect(!result.isInverted)
    }

    /// 自交蝴蝶结与半幅矩形取交集，只保留左右对称面积中的左半幅。
    @Test func selfIntersectionParticipatesInOrderedBoolean() throws {
        let bowtie = [ScenePoint(x: 0, y: 0), ScenePoint(x: 10, y: 10),
                      ScenePoint(x: 0, y: 10), ScenePoint(x: 10, y: 0)]
        let left = GeometryTestSupport.rectangle(0, 0, 5, 10)
        let result = try prepare([.init(contours: [bowtie], mode: .add, isInverted: false),
                                  .init(contours: [left], mode: .intersect, isInverted: false)])
        #expect(result.isInverted == false)
        #expect(GeometryTestSupport.area(result.mesh) == 25)
        #expect(GeometryTestSupport.coverage(result.mesh, at: .init(x: 2.13, y: 1.71)) == 1)
        #expect(GeometryTestSupport.coverage(result.mesh, at: .init(x: 7.13, y: 1.71)) == 0)
    }

    /// 三条交叉源路径按Union后XOR，逐点对照系统单路径包含判断组合出的独立真值。
    @Test func crossingPathsMatchIndependentPointwiseBoolean() throws {
        let first = GeometryTestSupport.rectangle(0, 1, 13, 12)
        let second = [ScenePoint(x: 2, y: -2), ScenePoint(x: 17, y: 5), ScenePoint(x: 4, y: 17)]
        let third = GeometryTestSupport.rectangle(6, 3, 8, 9)
        let result = try prepare([.init(contours: [first], mode: .add, isInverted: false),
                                  .init(contours: [second], mode: .add, isInverted: true),
                                  .init(contours: [third], mode: .difference, isInverted: false)])
        #expect(result.isInverted)
        let paths = [first, second, third].map { GeometryTestSupport.systemPath(GeometryTestSupport.outline([$0])) }
        for y in -3..<18 {
            for x in -2..<18 {
                let point = ScenePoint(x: Double(x) + 0.137, y: Double(y) + 0.319)
                let inside = paths.map { $0.contains(CGPoint(x: point.x, y: point.y), using: .winding) }
                let expected = (inside[0] || !inside[1]) != inside[2]
                let finite = GeometryTestSupport.coverage(result.mesh, at: point)
                #expect(finite <= 1)
                #expect(((finite > 0) != result.isInverted) == expected)
            }
        }
    }

    /// 全Difference快路径遇到重合边、非零孔洞及反向项时，仍逐点等于独立路径的异或。
    @Test func differenceOnlyPreservesPerPathWindingAndOutside() throws {
        let first = GeometryTestSupport.rectangle(0, 0, 12, 12)
        let hole = GeometryTestSupport.rectangle(3, 3, 6, 6, reversed: true)
        let second = GeometryTestSupport.rectangle(0, 0, 12, 12)
        let third = GeometryTestSupport.rectangle(7, 1, 10, 10)
        let result = try prepare([
            .init(contours: [first, hole], mode: .difference, isInverted: false),
            .init(contours: [second], mode: .difference, isInverted: true),
            .init(contours: [third], mode: .difference, isInverted: false)
        ])
        #expect(result.isInverted)
        let paths = [[first, hole], [second], [third]].map {
            GeometryTestSupport.systemPath(GeometryTestSupport.outline($0))
        }
        for y in -2..<15 {
            for x in -2..<19 {
                let point = ScenePoint(x: Double(x) + 0.217, y: Double(y) + 0.389)
                let inside = paths.map { $0.contains(CGPoint(x: point.x, y: point.y), using: .winding) }
                let expected = (inside[0] != !inside[1]) != inside[2]
                let finite = GeometryTestSupport.coverage(result.mesh, at: point)
                #expect(finite <= 1)
                #expect(((finite > 0) != result.isInverted) == expected)
            }
        }
    }

    /// 非有限坐标、字节或工作上限以及预取消都显式失败，不返回部分网格。
    @Test func invalidAndLimitedWorkCannotPublishPartialResult() async throws {
        let contour = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let operands = [MaskBooleanOperand(contours: [contour], mode: .add, isInverted: false)]
        var bytes = try GeometryBudget(maximumBytes: 16)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try MaskBooleanTessellation.prepare(operands, budget: &bytes)
        }
        var work = try GeometryBudget(maximumWork: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try MaskBooleanTessellation.prepare(operands, budget: &work)
        }
        #expect(throws: PAGError.renderingFailure("geometryNonFinite")) {
            try prepare([.init(contours: [[.init(x: .infinity, y: 0)]], mode: .add, isInverted: false)])
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = try GeometryBudget()
            return try MaskBooleanTessellation.prepare(operands, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(throws: PAGError.invalidArgument("maskBooleanOperands")) {
            try prepare([])
        }
        #expect(throws: PAGError.invalidArgument("maskBooleanMode")) {
            try prepare([.init(contours: [contour], mode: .none, isInverted: false)])
        }
        // 零点轮廓不产生边，也必须按数量收费，不能靠空数组绕过工作上限。
        var emptyWork = try GeometryBudget(maximumWork: 64)
        let emptyContours = [MaskBooleanOperand(contours: Array(repeating: [], count: 1_000),
                                               mode: .add, isInverted: false)]
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try MaskBooleanTessellation.prepare(emptyContours, budget: &emptyWork)
        }
    }

    /// 以默认几何预算调用纯值求解器，测试金值只由手算区域和独立网格覆盖获得。
    private func prepare(_ operands: [MaskBooleanOperand]) throws -> MaskBooleanResult {
        var budget = try GeometryBudget()
        return try MaskBooleanTessellation.prepare(operands, budget: &budget)
    }
}
