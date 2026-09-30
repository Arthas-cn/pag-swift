import CoreGraphics
import Testing
@testable import pag_swift

/// PAG路径与解析矩形共同进入nonzero几何，验证隐式游标、孔洞、真实曲线及资源预算。
struct ShapePathGeometryTests {
    /// 反向路径作为矩形中的孔洞必须合为一次填充；父fill也能取得零alpha子组交出的路径。
    @Test func mixedContoursKeepHoleAndInvisibleGroupPath() throws {
        let hole = try ShapePathFixtures.square(20, reversed: true)
        let group = SourceShapeTransform(base: SourceTransform(anchor: .zero, position: .zero,
            scale: .one, rotation: 0, opacity: 0), skew: 0, skewAxis: 0)
        let elements: [SourceShape] = [
            .rectangle(reversed: false, size: ScenePoint(x: 40, y: 40), position: ScenePoint(x: 20, y: 20), roundness: 0),
            .group(group, [.path(SourceProperty(constant: hole)), .fill(color: .defaultFill, opacity: 255)]),
            .fill(color: .defaultFill, opacity: 255)
        ]
        var budget = FramePlanBudget(limit: 1_000_000)
        let prepared = try ShapePreparation.prepare(elements, budget: &budget)
        #expect(prepared.instructions.count == 1 && prepared.geometries.count == 1)
        let geometry = try #require(prepared.geometries.first)
        #expect(geometry.contours.count == 2)
        let mesh = try mesh(geometry)
        #expect(abs(GeometryTestSupport.area(mesh) - 1_200) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 17, y: 19)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 3, y: 5)) == 1)
    }

    /// 空路径首个line补原点，重复close无额外轮廓，close后继续line从最近Move起点而非压缩末点出发。
    @Test func implicitOriginAndClosedCursorMatchConsumer() throws {
        let path = try SourcePath(verbs: [.close, .line, .line, .close, .close, .line, .line], points: [
            ScenePoint(x: 10, y: 0), ScenePoint(x: 0, y: 10), ScenePoint(x: -10, y: 0), ScenePoint(x: 0, y: -10)])
        var budget = try GeometryBudget()
        let contours = try PathFlattening.sourcePath(path, tolerance: 0.125, budget: &budget)
        #expect(contours == [[.zero, ScenePoint(x: 10, y: 0), ScenePoint(x: 0, y: 10)],
                             [.zero, ScenePoint(x: -10, y: 0), ScenePoint(x: 0, y: -10)]])
        #expect(abs(GeometryTestSupport.area(try GeometryTestSupport.mesh(contours)) - 100) < 1e-8)
        let curve = try SourcePath(verbs: [.cubic], points: [ScenePoint(x: 10, y: 0),
            ScenePoint(x: 10, y: 10), ScenePoint(x: 0, y: 10)])
        let curved = try PathFlattening.sourcePath(curve, tolerance: 0.125, budget: &budget)
        #expect(curved.first?.first == .zero && curved.first?.last == ScenePoint(x: 0, y: 10))
    }

    /// 真实0.pag的静态曲线与独立CoreGraphics路径做内部点对照，组内缩放沿共同精度策略收紧容差。
    @Test func realPathMatchesSystemContainmentAfterGroupScale() throws {
        let path = try PathFixtures.property(named: "0.pag", range: 164..<202).initialValue
        let geometry = try ShapeGeometry(contours: [.path(path, matrix: .scale(x: 3, y: 2))])
        let mesh = try mesh(geometry)
        let reference = systemPath(path)
        var checked = 0
        for y in stride(from: -6.7, through: 6.7, by: 1.3) {
            for x in stride(from: -10.7, through: 10.7, by: 1.3) {
                let inside = reference.contains(CGPoint(x: x, y: y), using: .winding)
                let count = GeometryTestSupport.coverage(mesh, at: ScenePoint(x: x * 3, y: y * 2))
                #expect(count == (inside ? 1 : 0))
                checked += 1
            }
        }
        #expect(checked > 150)
    }

    /// 网格缓存计入引用的路径点，装不下时不留存；低工作预算与取消不产生截断轮廓。
    @Test func pathRetentionCostAndPreparationLimits() async throws {
        let path = try PathFixtures.property(named: "0.pag", range: 164..<202).initialValue
        let geometry = try ShapeGeometry(contours: [.path(path, matrix: .identity)])
        #expect(geometry.estimatedBytes >= path.estimatedBytes + 192)
        #expect(RenderGeometrySource.shape(geometry).estimatedBytes == geometry.estimatedBytes)
        var cache = try RenderGeometryCache(byteLimit: geometry.estimatedBytes - 1)
        var budget = try GeometryBudget()
        let source = RenderGeometrySource.shape(geometry)
        let first = try cache.mesh(for: source, transform: .identity, budget: &budget)
        #expect(!first.vertices.isEmpty && cache.count == 0)
        var tiny = try GeometryBudget(maximumWork: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try PathFlattening.sourcePath(path, tolerance: 0.125, budget: &tiny)
        }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try PathFlattening.shape(geometry, tolerance: 0.125, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 按共同的显示精度和预算生成网格，测试不创建离屏表面或读取播放像素。
    private func mesh(_ geometry: ShapeGeometry) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try RenderGeometrySource.shape(geometry).prepare(precision: GeometryPrecision(transform: .identity), budget: &budget)
    }

    /// 测试参照直接交给系统曲线，不经过生产折线化或nonzero扫描器。
    private func systemPath(_ source: SourcePath) -> CGPath {
        let path = CGMutablePath()
        var index = 0
        for verb in source.verbs {
            switch verb {
            case .move: path.move(to: point(source.points[index]))
            case .line: path.addLine(to: point(source.points[index]))
            case .cubic:
                path.addCurve(to: point(source.points[index + 2]), control1: point(source.points[index]), control2: point(source.points[index + 1]))
            case .close: path.closeSubpath()
            }
            index += verb.pointCount
        }
        return path
    }

    /// 只在测试参照内转换坐标，不在FramePlan保存CoreGraphics对象。
    private func point(_ value: ScenePoint) -> CGPoint { CGPoint(x: value.x, y: value.y) }
}
