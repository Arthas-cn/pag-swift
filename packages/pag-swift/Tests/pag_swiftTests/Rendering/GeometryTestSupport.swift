import CoreGraphics
@testable import pag_swift

/// 网格测试的独立面积、覆盖与系统路径参照；不调用生产扫描器来计算期望。
enum GeometryTestSupport {
    /// 创建沿向下 y 坐标正向排列的矩形，可选反向以构造孔洞。
    static func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double,
                          reversed: Bool = false) -> [ScenePoint] {
        let points = [ScenePoint(x: x, y: y), ScenePoint(x: x + width, y: y),
                      ScenePoint(x: x + width, y: y + height), ScenePoint(x: x, y: y + height)]
        return reversed ? points.reversed() : points
    }

    /// 将折线转换为普通路径输入，每个轮廓显式关闭。
    static func outline(_ contours: [[ScenePoint]]) -> GlyphOutline {
        GlyphOutline(elements: contours.flatMap { points -> [GlyphPathElement] in
            guard let first = points.first else { return [] }
            return [.move(first)] + points.dropFirst().map { .line($0) } + [.close]
        })
    }

    /// 用默认预算进行一次独立三角剖分，便于覆盖纯填充语义。
    static func mesh(_ contours: [[ScenePoint]]) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try NonzeroTessellation.prepare(contours, budget: &budget)
    }

    /// 累加三角形有向面积；测试期望来自手算几何，不能把重叠重复计费掩盖成 union。
    static func area(_ mesh: RenderMesh) -> Double {
        stride(from: 0, to: mesh.vertices.count, by: 3).reduce(0) { sum, index in
            let a = mesh.vertices[index], b = mesh.vertices[index + 1], c = mesh.vertices[index + 2]
            return sum + cross(a, b, c) * 0.5
        }
    }

    /// 返回点落在几个三角形严格内部；网格内部重叠会返回大于 1。
    static func coverage(_ mesh: RenderMesh, at point: ScenePoint) -> Int {
        let point = ScenePoint(x: point.x - mesh.origin.x, y: point.y - mesh.origin.y)
        var count = 0
        for index in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let a = mesh.vertices[index], b = mesh.vertices[index + 1], c = mesh.vertices[index + 2]
            if cross(a, b, point) > 0, cross(b, c, point) > 0, cross(c, a, point) > 0 { count += 1 }
        }
        return count
    }

    /// 系统参照保留二次/三次曲线，故不同于生产器使用的折线近似。
    static func systemPath(_ outline: GlyphOutline) -> CGPath {
        let path = CGMutablePath()
        for element in outline.elements {
            switch element {
            case let .move(value): path.move(to: point(value))
            case let .line(value): path.addLine(to: point(value))
            case let .quadratic(control, end): path.addQuadCurve(to: point(end), control: point(control))
            case let .cubic(first, second, end): path.addCurve(to: point(end), control1: point(first), control2: point(second))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    /// 坐标类型适配，仅在测试作用域创建系统对象。
    private static func point(_ value: ScenePoint) -> CGPoint { CGPoint(x: value.x, y: value.y) }

    /// 未归一化的叉积，测试输入使用普通尺度以独立核验三角形方向。
    private static func cross(_ a: ScenePoint, _ b: ScenePoint, _ c: ScenePoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
}
