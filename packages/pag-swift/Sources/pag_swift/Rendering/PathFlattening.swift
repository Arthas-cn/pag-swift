import Foundation

/// 将不可变字形与解析形状转换为复合折线；只细分边界，不决定填充或抗锯齿。
enum PathFlattening {
    /// 保留子路径绕序，开放子路径按填充语义隐式闭合；序列、精度或预算错误整体失败。
    static func glyph(_ outline: GlyphOutline, tolerance: Double,
                      budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        var builder = FlattenedPathBuilder(budget: budget, tolerance: tolerance)
        defer { budget = builder.budget }
        for element in outline.elements {
            try builder.budget.consume()
            switch element {
            case let .move(point):
                try builder.finishContour()
                try builder.append(point)
            case let .line(point):
                guard !builder.current.isEmpty else { throw PAGError.renderingFailure("geometryPathSequence") }
                try builder.append(point)
            case let .quadratic(control, end):
                try builder.curve(first: control, second: nil, end: end)
            case let .cubic(first, second, end):
                try builder.curve(first: first, second: second, end: end)
            case .close:
                // close 之后的当前位置仍是子路径起点；之后继续 line 是合法路径序列。
                if let start = builder.current.first {
                    try builder.finishContour()
                    try builder.append(start)
                }
            }
        }
        try builder.finishContour()
        try Task.checkCancellation()
        return builder.contours
    }

    /// 描边先构造完整outline；普通填充在组变换前收紧容差，二者都输出单次复合填充的边界。
    static func shape(_ geometry: ShapeGeometry, tolerance: Double,
                      budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        if let stroke = geometry.stroke {
            // 奇异组矩阵仍可留下有效中心线；描边必须早于下方仅适用于fill的面积过滤。
            return try self.stroke(geometry, stroke: stroke, tolerance: tolerance, budget: &budget)
        }
        var contours: [[ScenePoint]] = []
        for element in geometry.contours {
            try budget.consume()
            let matrix = element.matrix
            let stretch = try GeometryPrecision.maximumStretch(matrix)
            guard stretch > 0, try matrix.hasArea() else { continue }
            let generated: [[ScenePoint]]?
            switch element {
            case .path(let path, _):
                generated = try sourcePath(path, tolerance: tolerance / stretch, budget: &budget)
            case .ellipse(let contour):
                generated = try ellipse(contour, tolerance: tolerance / stretch, budget: &budget)
            case .polyStar(let contour):
                let path = try contour.path(budget: &budget)
                generated = try sourcePath(path, tolerance: tolerance / stretch, budget: &budget)
            case .rectangle:
                generated = nil
            }
            if var paths = generated {
                for index in paths.indices {
                    for point in paths[index].indices {
                        try budget.consume()
                        paths[index][point] = try matrix.applying(to: paths[index][point])
                    }
                }
                try budget.reserve(paths.count, stride: 64)
                contours.append(contentsOf: paths)
                continue
            }
            guard case .rectangle(let contour) = element, contour.hasArea else { continue }
            // 准备层保留退化中心线供Stroke使用；fill只在消费时排除零面积边界。
            let left = contour.left, right = contour.right
            let top = contour.top, bottom = contour.bottom
            var points: [ScenePoint] = []
            if contour.radius == 0 {
                try budget.reserve(4, stride: 32)
                points = [ScenePoint(x: left, y: top), ScenePoint(x: right, y: top),
                          ScenePoint(x: right, y: bottom), ScenePoint(x: left, y: bottom)]
            } else {
                let radius = contour.radius
                let localTolerance = tolerance / stretch
                // 1-cos(theta/2) 在小角度会丢精度，改用等价的 asin/sqrt 形式。
                let angle = 4 * asin(sqrt(min(1, (localTolerance / radius) * 0.5)))
                guard angle > 0, let steps = Int(exactly: max(1, ceil((.pi * 0.5) / angle))) else {
                    throw PAGError.resourceLimitExceeded("geometryPrecision")
                }
                let count = steps.addingReportingOverflow(1)
                guard !count.overflow else { throw PAGError.resourceLimitExceeded("maximumRenderGeometryWork") }
                try budget.reserve(count.partialValue, stride: 4 * 32)
                let centers = [ScenePoint(x: right - radius, y: top + radius),
                               ScenePoint(x: right - radius, y: bottom - radius),
                               ScenePoint(x: left + radius, y: bottom - radius),
                               ScenePoint(x: left + radius, y: top + radius)]
                for corner in 0..<4 {
                    for index in 0...steps {
                        try budget.consume()
                        // 四分之一圆的端点直接写整数轴方向，避免三角函数误差制造短边或假自交。
                        let direction: ScenePoint
                        if index == 0 { direction = cardinal(corner - 1) }
                        else if index == steps { direction = cardinal(corner) }
                        else { direction = arcDirection(index: index, steps: steps, corner: corner) }
                        points.append(ScenePoint(x: centers[corner].x + radius * direction.x,
                                                 y: centers[corner].y + radius * direction.y))
                    }
                }
            }
            for index in points.indices {
                try budget.consume()
                points[index] = try contour.matrix.applying(to: points[index])
            }
            if contour.reversed { points.reverse() }
            try budget.reserve(stride: 64)
            contours.append(points)
        }
        try Task.checkCancellation()
        return contours
    }

    /// 返回四分之一圈整数位置的方向，允许首个圆角使用 -1 表示向上。
    private static func cardinal(_ index: Int) -> ScenePoint {
        switch (index + 4) % 4 {
        case 0: ScenePoint(x: 1, y: 0)
        case 1: ScenePoint(x: 0, y: 1)
        case 2: ScenePoint(x: -1, y: 0)
        default: ScenePoint(x: 0, y: -1)
        }
    }

    /// 第一象限只计算到 45 度，其余方向通过交换和符号得到，保持对称点逐位一致。
    private static func arcDirection(index: Int, steps: Int, corner: Int) -> ScenePoint {
        let angle = Double(min(index, steps - index)) / Double(steps) * .pi * 0.5
        let sine = sin(angle), cosine = cos(angle)
        let diagonal = index == steps - index
        let x = diagonal ? sqrt(0.5) : (index < steps - index ? cosine : sine)
        let y = diagonal ? x : (index < steps - index ? sine : cosine)
        switch corner {
        case 0: return ScenePoint(x: y, y: -x)
        case 1: return ScenePoint(x: x, y: y)
        case 2: return ScenePoint(x: -y, y: x)
        default: return ScenePoint(x: -x, y: -y)
        }
    }
}

/// 单次字形或PAG路径折线化的局部累积，拥有预算和输出；发生错误时上层丢弃整个值。
struct FlattenedPathBuilder {
    /// 所有曲线与数组共享同一个工作/字节上限。
    var budget: GeometryBudget
    /// 源坐标中正的最大允许误差。
    let tolerance: Double
    /// 已结束的有效填充轮廓；至少三个点，不额外重复起点。
    var contours: [[ScenePoint]] = []
    /// 正在构造的子路径；空表示尚未有 move。
    var current: [ScenePoint] = []

    /// 验证点并去掉连续重复顶点，数组增长前计费。
    mutating func append(_ point: ScenePoint) throws {
        _ = try GeometryMath.checked(point)
        guard current.last != point else { return }
        try budget.reserve(stride: 32)
        current.append(point)
    }

    /// 填充时隐式闭合；不足三个顶点的路径无面积，不生成伪三角形。
    mutating func finishContour() throws {
        if current.count > 1, current.first == current.last { current.removeLast() }
        if current.count >= 3 {
            try budget.reserve(stride: 64)
            contours.append(current)
        }
        current = []
    }

    /// 用显式栈执行 de Casteljau，控制凸包到弦段的距离给出整段曲线误差上界。
    mutating func curve(first: ScenePoint, second: ScenePoint?, end: ScenePoint) throws {
        guard let start = current.last else { throw PAGError.renderingFailure("geometryPathSequence") }
        let first = try GeometryMath.checked(first)
        let second = try second.map { try GeometryMath.checked($0) }
        let end = try GeometryMath.checked(end)
        try budget.reserve(stride: 128)
        var stack = [FlatteningCurve(start: start, first: first, second: second, end: end, depth: 0)]
        while let curve = stack.popLast() {
            try budget.consume()
            let firstDistance = try GeometryMath.distance(curve.first, to: curve.start, curve.end)
            let secondDistance = try curve.second.map { try GeometryMath.distance($0, to: curve.start, curve.end) } ?? 0
            if max(firstDistance, secondDistance) <= tolerance {
                try append(curve.end)
                continue
            }
            guard curve.depth < budget.maximumDepth else {
                throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")
            }
            let halves = curve.split()
            // 右半先入栈，保持输出沿原始曲线方向；不在无法达标时悄悄改用终点。
            try budget.reserve(2, stride: 128)
            stack.append(halves.1)
            stack.append(halves.0)
        }
    }
}

/// 一段待检查的二次或三次曲线；second 为 nil 时使用二次规则。
private struct FlatteningCurve {
    /// 此子段的起点，已经与前一段连接。
    let start: ScenePoint
    /// 第一个控制点。
    let first: ScenePoint
    /// 三次曲线第二个控制点；二次曲线为 nil。
    let second: ScenePoint?
    /// 此子段的终点。
    let end: ScenePoint
    /// 从原始曲线开始的二分次数。
    let depth: Int

    /// 在参数 1/2 处精确构造两个子段；有限端点的中点不产生溢出。
    func split() -> (FlatteningCurve, FlatteningCurve) {
        let a = GeometryMath.midpoint(start, first)
        if let second {
            let b = GeometryMath.midpoint(first, second), c = GeometryMath.midpoint(second, end)
            let d = GeometryMath.midpoint(a, b), e = GeometryMath.midpoint(b, c)
            let middle = GeometryMath.midpoint(d, e)
            return (FlatteningCurve(start: start, first: a, second: d, end: middle, depth: depth + 1),
                    FlatteningCurve(start: middle, first: e, second: c, end: end, depth: depth + 1))
        }
        let b = GeometryMath.midpoint(first, end)
        let middle = GeometryMath.midpoint(a, b)
        return (FlatteningCurve(start: start, first: a, second: nil, end: middle, depth: depth + 1),
                FlatteningCurve(start: middle, first: b, second: nil, end: end, depth: depth + 1))
    }
}
