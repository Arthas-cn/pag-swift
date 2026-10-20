import CoreGraphics
import Testing
@testable import pag_swift

/// 普通蒙版有限路径的nonzero网格及缓存；没有创建显示附件，不宣称Metal覆盖率已完成。
struct MaskGeometryTests {
    /// AudioMarker必须保留曲线外的包围盒内部空白，并与独立CGPath内部点参照一致。
    @Test func realAudioMarkerIsCurvedNonzeroRegion() throws {
        let mask = try MaskFixtures.read(PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_971_337..<1_971_395)).mask
        let sampled = try #require(try MaskTestSupport.sample([mask]))
        let mesh = try MaskTestSupport.mesh(sampled.path)
        for (x, y, inside): (Double, Double, Bool) in [
            (400, 650, true), (400, 400, true), (200, 650, true),
            (0, 650, false), (400, 1100, false), (20, 270, false)
        ] {
            #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: x, y: y)) == (inside ? 1 : 0))
        }
        let reference = systemPath(sampled.path)
        var comparisons = 0
        for y in stride(from: 280.7, through: 1_030.7, by: 37.1) {
            for x in stride(from: 15.3, through: 790.3, by: 41.7) {
                // 网格参照按内点取样；离边界0.5像素的邻点一致才排除曲线近似允许的边缘带。
                let values = [-0.5, 0.5].flatMap { dx in [-0.5, 0.5].map { dy in
                    reference.contains(CGPoint(x: x + dx, y: y + dy), using: .winding)
                } }
                guard values.allSatisfy({ $0 == values[0] }) else { continue }
                #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: x, y: y)) == (values[0] ? 1 : 0))
                comparisons += 1
            }
        }
        #expect(comparisons > 300)
    }

    /// 只检查整个路径末verb的闭合资格；前面开放外轮廓和后面反向孔洞应一起按nonzero填充。
    @Test func earlierOpenContourAndHoleAreBothConsumed() throws {
        let outer = GeometryTestSupport.rectangle(0, 0, 40, 40)
        let hole = GeometryTestSupport.rectangle(10, 10, 20, 20, reversed: true)
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .move, .line, .line, .line, .close], points: outer + hole)
        let sampled = try #require(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path))]))
        let mesh = try MaskTestSupport.mesh(sampled.path)
        #expect(abs(GeometryTestSupport.area(mesh) - 1_200) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 3, y: 5)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 17, y: 19)) == 0)
    }

    /// 自交路径的代数面积可为零，仍有两个真实填充区，不能按鞋带面积丢弃整个蒙版。
    @Test func selfIntersectionDoesNotDisappear() throws {
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close],
            points: [.zero, ScenePoint(x: 20, y: 20), ScenePoint(x: 0, y: 20), ScenePoint(x: 20, y: 0)])
        let sampled = try #require(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path))]))
        let mesh = try MaskTestSupport.mesh(sampled.path)
        #expect(abs(GeometryTestSupport.area(mesh) - 200) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 5, y: 2)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 2, y: 10)) == 0)
    }

    /// 所有真实355载荷各自采样端点和段内帧；单项覆盖不得被误称为多蒙版图层或整文件已支持。
    @Test func everyRealPayloadPreparesItsFinitePath() async throws {
        let payloads = try await MaskFixtures.payloads()
        #expect(payloads.count == 355)
        var animated = 0
        var prepared = 0
        for payload in payloads {
            let mask = try MaskFixtures.read(payload.data, code: payload.code).mask
            if mask.path.isAnimated { animated += 1 }
            let frames: [Int64] = mask.path.keyframes.isEmpty ? [0] : mask.path.keyframes.flatMap {
                [$0.startFrame, $0.startFrame + ($0.endFrame - $0.startFrame) / 2, $0.endFrame]
            }
            for frame in frames {
                if let sampled = try MaskTestSupport.sample([mask], at: frame) {
                    let mesh = try MaskTestSupport.mesh(sampled.path)
                    #expect(mesh.vertices.count.isMultiple(of: 3))
                    #expect(mesh.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                    #expect(sampled.isInverted == (mask.mode == .subtract))
                    prepared += 1
                } else {
                    #expect(mask.mode == .none || mask.path.initialValue.verbs.last != .close)
                }
            }
        }
        #expect(animated == 10 && prepared > 500)
    }

    /// 源路径身份跨正反向及平移共享网格，放大独立分档；禁留存和命中预算均不能绕过限制。
    @Test func pathIdentityPrecisionAndRetentionLimits() async throws {
        let path = try ShapePathFixtures.square(20)
        let positive = try #require(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path))]))
        let inverse = try #require(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path), inverted: true)]))
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let first = try cache.mesh(for: .mask(positive.path), transform: .identity, budget: &budget)
        let translated = try cache.mesh(for: .mask(inverse.path), transform: .translation(x: 1_000, y: -2_000), budget: &budget)
        #expect(first === translated && cache.count == 1)
        let scaled = try cache.mesh(for: .mask(path), transform: .scale(x: 8, y: 2), budget: &budget)
        #expect(scaled !== first && cache.count == 2)
        #expect(RenderGeometrySource.mask(path).estimatedBytes == path.estimatedBytes)
        var tiny = try GeometryBudget(maximumBytes: first.estimatedBytes - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try cache.mesh(for: .mask(path), transform: .identity, budget: &tiny)
        }
        var noRetention = try RenderGeometryCache(byteLimit: path.estimatedBytes - 1)
        _ = try noRetention.mesh(for: .mask(path), transform: .identity, budget: &budget)
        #expect(noRetention.count == 0)
        cache.removeAll()
        #expect(abs(GeometryTestSupport.area(first) - 400) < 1e-8)
        let task = Task {
            var canceled = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try RenderGeometrySource.mask(path).prepare(precision: GeometryPrecision(transform: .identity), budget: &canceled)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// CGPath仅用于测试的独立曲线参照，不使用生产折线化或网格反构期望。
    private func systemPath(_ source: SourcePath) -> CGPath {
        let path = CGMutablePath()
        var index = 0
        for verb in source.verbs {
            switch verb {
            case .move: path.move(to: CGPoint(x: source.points[index].x, y: source.points[index].y))
            case .line: path.addLine(to: CGPoint(x: source.points[index].x, y: source.points[index].y))
            case .cubic:
                path.addCurve(to: CGPoint(x: source.points[index + 2].x, y: source.points[index + 2].y),
                    control1: CGPoint(x: source.points[index].x, y: source.points[index].y),
                    control2: CGPoint(x: source.points[index + 1].x, y: source.points[index + 1].y))
            case .close: path.closeSubpath()
            }
            index += verb.pointCount
        }
        return path
    }
}
