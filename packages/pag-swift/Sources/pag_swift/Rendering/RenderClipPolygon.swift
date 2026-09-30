import Foundation

/// 多个真实矩形裁剪的凸交集；供覆盖准备使用，不将旋转裁剪简化为包围盒。
struct RenderClipPolygon: Sendable {
    /// 正有向面积的凸多边形顶点；空数组表示没有可见面积。
    private(set) var vertices: [ScenePoint]

    /// 从最终显示边界开始，确保之后的交集始终位于有界显示坐标内。
    init(bounds: RenderBounds) {
        if bounds.left < bounds.right, bounds.top < bounds.bottom {
            vertices = [ScenePoint(x: bounds.left, y: bounds.top), ScenePoint(x: bounds.right, y: bounds.top),
                        ScenePoint(x: bounds.right, y: bounds.bottom), ScenePoint(x: bounds.left, y: bounds.bottom)]
        } else { vertices = [] }
    }

    /// 将已验证矩形的四个半平面加入交集，负scale只改变顶点绕序，不改变可见区域。
    mutating func intersect(_ clip: FrameClip, budget: inout GeometryBudget) throws {
        try budget.consume()
        let m = clip.matrix
        let determinant = m.a * m.d - m.b * m.c
        guard determinant.isFinite, determinant != 0 else { throw PAGError.renderingFailure("metalClipTransform") }
        let width = clip.size.width, height = clip.size.height
        var corners = try [ScenePoint.zero, ScenePoint(x: width, y: 0), ScenePoint(x: width, y: height),
                           ScenePoint(x: 0, y: height)].map { try m.applying(to: $0) }
        if determinant < 0 { corners.reverse() }
        for index in corners.indices {
            try cut(from: corners[index], to: corners[(index + 1) % 4], budget: &budget)
        }
    }

    /// 按MSL float4(start.x,start.y,end.x,end.y)打包边界；空数组是空交集，调用方须跳过绘制，不能当作无裁剪。
    func packedEdges(budget: inout GeometryBudget) throws -> [SIMD4<Float>] {
        try budget.reserve(vertices.count, stride: 32)
        var result: [SIMD4<Float>] = []
        for index in vertices.indices {
            try budget.consume()
            let next = vertices[(index + 1) % vertices.count]
            result.append(try MetalDrawUniforms.finite(vertices[index].x, vertices[index].y, next.x, next.y))
        }
        return result
    }

    /// Sutherland–Hodgman凸半平面裁剪；交点在两端间插值，避免直接除巨大叉积。
    private mutating func cut(from start: ScenePoint, to end: ScenePoint, budget: inout GeometryBudget) throws {
        guard !vertices.isEmpty else { return }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0 else { throw PAGError.renderingFailure("coverageClipEdge") }
        let nx = -dy / length, ny = dx / length
        var result: [ScenePoint] = []
        var previous = vertices[vertices.count - 1]
        var previousDistance = try distance(previous, from: start, nx: nx, ny: ny)
        for point in vertices {
            try budget.consume()
            let currentDistance = try distance(point, from: start, nx: nx, ny: ny)
            if (previousDistance < 0) != (currentDistance < 0) {
                let scale = max(abs(previousDistance), abs(currentDistance))
                let first = previousDistance / scale, second = currentDistance / scale
                let fraction = first / (first - second)
                let intersection = try GeometryMath.checked(ScenePoint(
                    x: previous.x * (1 - fraction) + point.x * fraction,
                    y: previous.y * (1 - fraction) + point.y * fraction))
                try append(intersection, to: &result, budget: &budget)
            }
            if currentDistance >= 0 { try append(point, to: &result, budget: &budget) }
            previous = point
            previousDistance = currentDistance
        }
        if result.count > 1, result.first == result.last { result.removeLast() }
        // 只有线或点的交集没有覆盖面积，不留给GPU作为反向/退化多边形。
        guard result.count >= 3 else { vertices = []; return }
        let origin = result[0]
        var area = 0.0
        for index in 1..<(result.count - 1) {
            try budget.consume()
            let a = result[index], b = result[index + 1]
            area += (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
        }
        guard area.isFinite else { throw PAGError.renderingFailure("coverageClipNonFinite") }
        vertices = area > 0 ? result : []
    }

    /// 归一化半平面有符号距离；非有限中间结果明确失败，不猜测内外。
    private func distance(_ point: ScenePoint, from start: ScenePoint, nx: Double, ny: Double) throws -> Double {
        let value = (point.x - start.x) * nx + (point.y - start.y) * ny
        guard value.isFinite else { throw PAGError.renderingFailure("coverageClipNonFinite") }
        return value
    }

    /// 避免端点恰在裁剪边上时重复加入同一点，每次增长前检查统一预算。
    private func append(_ point: ScenePoint, to output: inout [ScenePoint], budget: inout GeometryBudget) throws {
        guard output.last != point else { return }
        try budget.reserve(stride: 32)
        output.append(point)
    }
}
