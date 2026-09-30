import Testing
@testable import pag_swift

/// PolyStar的独立C Float常量、低点数、圆度、Int32边界及有界失败；不把模型数据冒充PAG。
struct PolyStarGeneratorTests {
    /// points2.5的两方向坐标对照独立C公式结果；逆向Float累加不要求与顺向简单倒序逐位相同。
    @Test(arguments: [false, true])
    func fractionalStarsMatchSourceFloatGolden(_ reversed: Bool) throws {
        let path = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(reversed: reversed))
        #expect(path.verbs == [.move, .line, .line, .line, .line, .line, .line, .close])
        let clockwise: [(UInt32, UInt32)] = [(0x3f1e3779, 0xbff37871), (0x3f800000, 0),
            (0x3f9b54ce, 0x3f61b5a4), (0x3e9e3779, 0x3f737871), (0xbfcf1bbe, 0x3f967917),
            (0xbf4f1bbc, 0xbf16791a), (0x3f1e3779, 0xbff37871)]
        let counter: [(UInt32, UInt32)] = [(0x3f1e3779, 0xbff37871), (0xbf4f1bbe, 0xbf167917),
            (0xbfcf1bbc, 0x3f96791a), (0x3e9e377e, 0x3f737870), (0x3f9b54d1, 0x3f61b59c),
            (0x3f800000, 0xb52eef4c), (0x3f1e3779, 0xbff37871)]
        #expect(path.points == golden(reversed ? counter : clockwise))
    }

    /// 圆度0.25/0.5产生六个三次段，所有控制点对照源码算序的独立C结果。
    @Test func roundedFractionalStarMatchesControlPointGolden() throws {
        let path = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(
            innerRoundness: .init(constant: 0.25), outerRoundness: .init(constant: 0.5)))
        #expect(path.verbs == [.move] + Array(repeating: .cubic, count: 6) + [.close])
        #expect(path.points == golden([(0x3f1e3779, 0xbff37871), (0x3f9b98cc, 0xbfda9e2c), (0x3f800000, 0xbe20d97c),
            (0x3f800000, 0), (0x3f800000, 0x3da0d97c), (0x3fad0ef7, 0x3f30e928), (0x3f9b54ce, 0x3f61b5a4),
            (0x3f899aa5, 0x3f894110), (0x3ec47600, 0x3f6d41e0), (0x3e9e3779, 0x3f737871),
            (0x3e2374d4, 0x3f7fe594), (0xbf9fd5fc, 0x3fd789bc), (0xbfcf1bbe, 0x3f967917),
            (0xbffe6180, 0x3f2ad0e4), (0xbf66be9e, 0xbeebe190), (0xbf4f1bbc, 0xbf16791a),
            (0xbf3778da, 0xbf37016c), (0x3ca7ab60, 0xc006295b), (0x3f1e3779, 0xbff37871)]))
    }

    /// Polygon小数点数floor而非ceil，源pi位模式直接决定两点路径中的微小y坐标。
    @Test func polygonFloorsAndLocksSourcePi() throws {
        let path = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: .polygon))
        #expect(path.verbs == [.move, .line, .line, .close])
        #expect(path.points == golden([(0x40000000, 0), (0xc0000000, 0xb43bbd2e), (0x40000000, 0)]))
    }

    /// 非正点数保留Move+Close；负小数Star的首角偏移及极小Int32计数不错误触发无用减法。
    @Test(arguments: [SourcePolyStarKind.star, .polygon], [0.0, -0.5, -2.5, -1_073_741_824])
    func nonpositiveCountsPreserveSourceDegeneracy(_ kind: SourcePolyStarKind, _ points: Double) throws {
        let path = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: kind, reversed: true,
            points: .init(constant: points), outerRoundness: .init(constant: 2)))
        #expect(path.verbs == [.move, .close] && path.points.count == 1)
        if kind == .star && points == -2.5 {
            #expect(path.points == golden([(0x3f1e3779, 0x3ff37871)]))
        } else if points == 0 || kind == .polygon || points == -1_073_741_824 {
            #expect(path.points == [ScenePoint(x: 2, y: 0)])
        }
    }

    /// 一点与两点Polygon、低点数Star仍保留Cubic；圆度负值和大于1都不夹，负半径不abs。
    @Test func lowCountsAndUnclampedRoundnessKeepCurves() throws {
        for (kind, count, segments): (SourcePolyStarKind, Double, Int) in [(.polygon, 1, 1), (.polygon, 2, 2), (.star, 0.5, 2)] {
            let path = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: kind,
                points: .init(constant: count), outerRoundness: .init(constant: 2)))
            #expect(path.verbs == [.move] + Array(repeating: .cubic, count: segments) + [.close])
        }
        for roundness in [-0.5, 2.0] {
            let path = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: .polygon,
                points: .init(constant: 1), outerRadius: .init(constant: -2), outerRoundness: .init(constant: roundness)))
            let controlY = Double(Float(-2) * Float(roundness) * (Float(bitPattern: 0x40490FDB) * 0.5))
            #expect(path.points == [ScenePoint(x: -2, y: 0), ScenePoint(x: -2, y: controlY),
                                   ScenePoint(x: -2, y: -controlY), ScenePoint(x: -2, y: 0)])
        }
    }

    /// 源Int32未定义边界精度失败；边界前一个Float是合法大数量但必须先被数组预算拒绝。
    @Test func integerConversionAndAllocationLimitsRemainDistinct() throws {
        for (kind, boundary): (SourcePolyStarKind, Float) in [(.polygon, 2_147_483_648), (.star, 1_073_741_824)] {
            #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
                try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: kind, points: .init(constant: Double(boundary))))
            }
            #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
                try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: kind, points: .init(constant: Double(boundary.nextDown))))
            }
        }
        let minimum = try ShapeGeneratorFixtures.path(ShapeGeneratorFixtures.polyStar(kind: .polygon,
            points: .init(constant: -2_147_483_648)))
        #expect(minimum.verbs == [.move, .close])
    }

    /// 必须使用的角度/控制点Float溢出明确失败；工作和取消也不会返回已经生成的前几段。
    @Test func floatWorkAndCancellationFailuresAreAtomic() async throws {
        let overflow = ShapeGeneratorFixtures.polyStar(rotation: .init(constant: Double(Float.greatestFiniteMagnitude)))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try ShapeGeneratorFixtures.path(overflow) }
        let tiny = ShapeGeneratorFixtures.polyStar(points: .init(constant: Double(Float.leastNonzeroMagnitude)))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try ShapeGeneratorFixtures.path(tiny) }
        let contour = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(), at: 0, matrix: .identity)
        var work = try GeometryBudget(maximumWork: 100)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) { try contour.path(budget: &work) }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    var budget = try GeometryBudget()
                    _ = try contour.path(budget: &budget)
                }
                for try await _ in group {}
            }
        }
    }

    /// 位模式来自单独C算式程序（ffp-contract=off），未链接或编译上游库；不以生产函数算期望。
    private func golden(_ values: [(UInt32, UInt32)]) -> [ScenePoint] {
        values.map { ScenePoint(x: Double(Float(bitPattern: $0.0)), y: Double(Float(bitPattern: $0.1))) }
    }
}
