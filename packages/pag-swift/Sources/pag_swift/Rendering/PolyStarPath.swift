import Foundation

/// 按ShapeRenderer.cpp的Float公式展开PolyStar；只在后台几何缓存缺失时执行，不创建平台路径。
extension PolyStarContour {
    /// 源M_PI转Float的实际位模式；Swift Float.pi低一ULP，不能替代。
    private static let sourcePi = Float(bitPattern: 0x40490FDB)

    /// 完整生成Line/Cubic路径；Int32未定义范围、Float溢出、预算或取消均不发布部分数组。
    func path(budget: inout GeometryBudget) throws -> SourcePath {
        try budget.consume(32)
        let x = Float(position.x), y = Float(position.y)
        guard [points, x, y, rotation, innerRadius, outerRadius, innerRoundness, outerRoundness].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        let count = try segmentCount()
        let length = max(0, Int(count))
        let rounded = outerRoundness != 0 || (kind == .star && innerRoundness != 0)
        let pointCount = length.multipliedReportingOverflow(by: rounded ? 3 : 1)
        let capacity = pointCount.partialValue.addingReportingOverflow(1)
        guard !pointCount.overflow, !capacity.overflow else {
            throw PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")
        }
        // 先为完整结果与固定工作状态付费，极大合法点数也不能先分配后发现超限。
        try budget.reserve(stride: 640)
        try budget.reserve(length + 2, stride: 16)
        try budget.reserve(capacity.partialValue, stride: 32)
        var verbs: [SourcePathVerb] = []
        var values: [ScenePoint] = []
        verbs.reserveCapacity(length + 2)
        values.reserveCapacity(capacity.partialValue)
        let direction: Float = reversed ? -1 : 1
        let step = kind == .star ? Self.sourcePi / points : Self.sourcePi * 2 / Float(count)
        var angle = (rotation - 90) * Self.sourcePi / 180
        let fraction = kind == .star ? points - floorf(points) : 0
        var decimalIndex: Int32 = -2
        if fraction != 0 {
            if reversed {
                let index = count.subtractingReportingOverflow(3)
                guard !index.overflow else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
                decimalIndex = index.partialValue
            } else {
                decimalIndex = 1
            }
            // 源码在两个绕序方向都执行同号首角偏移，不能用direction再乘一次。
            angle -= step * fraction * 2
        }
        guard angle.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        let firstX = outerRadius * cosf(angle), firstY = outerRadius * sinf(angle)
        var lastX = firstX, lastY = firstY
        values.append(try checkedPoint(firstX + x, firstY + y))
        verbs.append(.move)
        var outer = false
        for index in 0..<length {
            try budget.consume(64)
            var delta = step * direction
            let dx: Float, dy: Float
            if index == length - 1 {
                // 最后一段复用首点而不继续累加角度，显式返回首点之后仍必须Close。
                dx = firstX
                dy = firstY
            } else {
                var radius = kind == .star && !outer ? innerRadius : outerRadius
                if kind == .star && (index == Int(decimalIndex) || index == Int(decimalIndex) + 1) {
                    radius = innerRadius + fraction * (radius - innerRadius)
                    delta *= fraction
                }
                angle += delta
                guard angle.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
                dx = radius * cosf(angle)
                dy = radius * sinf(angle)
            }
            if rounded {
                let previousRoundness = kind == .star && outer ? innerRoundness : outerRoundness
                let roundness = kind == .star && !outer ? innerRoundness : outerRoundness
                let factor = delta * (kind == .star ? 0.5 : 0.25)
                // AddCurveToPath的乘加按源Float左结合，圆度和半径均不夹值。
                values.append(try checkedPoint(lastX - lastY * previousRoundness * factor + x,
                                               lastY + lastX * previousRoundness * factor + y))
                values.append(try checkedPoint(dx + dy * roundness * factor + x,
                                               dy - dx * roundness * factor + y))
                values.append(try checkedPoint(dx + x, dy + y))
                verbs.append(.cubic)
                lastX = dx
                lastY = dy
            } else {
                values.append(try checkedPoint(dx + x, dy + y))
                verbs.append(.line)
            }
            outer.toggle()
        }
        verbs.append(.close)
        try Task.checkCancellation()
        return try SourcePath(verbs: verbs, points: values)
    }

    /// 模拟源32位int的已定义范围；非正数量仍合法，不能无条件计算只属于分数分支的n-3。
    private func segmentCount() throws -> Int32 {
        let rounded = kind == .star ? ceilf(points) : floorf(points)
        guard let integer = Int32(exactly: rounded) else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        guard kind == .star else { return integer }
        let doubled = integer.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return doubled.partialValue
    }

    /// Float控制点及累计组变换必须有限；返回局部点，实际变换仍由消费者恰好应用一次。
    private func checkedPoint(_ x: Float, _ y: Float) throws -> ScenePoint {
        guard x.isFinite, y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        let result = ScenePoint(x: Double(x), y: Double(y))
        _ = try matrix.applying(to: result)
        return result
    }
}
