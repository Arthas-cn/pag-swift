import Foundation

/// 固定PathKit的Float三次/二次单位区间根；用于描边分析与偏移，不替代时间轴的独立求根规则。
enum StrokeCubicPolynomial {
    /// 求a·t³+b·t²+c·t+d的源根；三次会钳制端点，调用方必须另行排除0和1。
    static func roots(_ coefficients: SIMD4<Float>, budget: inout GeometryBudget) throws -> [Float] {
        try budget.consume(64)
        try budget.reserve(3, stride: 16)
        try finite(coefficients)
        if abs(coefficients.x) <= 1.0 / 4096 {
            return try quadratic(coefficients.y, coefficients.z, coefficients.w)
        }
        let inverse = 1 / coefficients.x
        let a = coefficients.y * inverse, b = coefficients.z * inverse, c = coefficients.w * inverse
        let q = (a * a - b * 3) / 9
        let r = (2 * a * a * a - 9 * a * b + 27 * c) / 54
        let q3 = q * q * q, discriminant = r * r - q3, third = a / 3
        try finite(SIMD4(q, r, q3, discriminant))
        let values: [Float]
        if discriminant < 0 {
            let ratio = r / q3.squareRoot()
            guard ratio.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
            let theta = acosf(max(-1, min(1, ratio))), scale = -2 * q.squareRoot()
            // PK_FloatPI的最近Float比Swift Float.pi高一ULP，必须使用源字面量舍入。
            let pi = Float(3.14159265358979323846)
            values = [scale * cosf(theta / 3) - third,
                      scale * cosf((theta + 2 * pi) / 3) - third,
                      scale * cosf((theta - 2 * pi) / 3) - third]
        } else {
            // 源powf使用0.3333333f而非精确1/3；换成cbrt会改变重复/端点分类。
            var root = powf(abs(r) + discriminant.squareRoot(), Float(0.3333333))
            if r > 0 { root = -root }
            if root != 0 { root += q / root }
            values = [root - third]
        }
        guard values.allSatisfy(\.isFinite) else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        try budget.reserve(9, stride: 16)
        let sorted = values.map { max(0, min(1, $0)) }.sorted()
        var result: [Float] = []
        for value in sorted where result.last != value { result.append(value) }
        return result
    }

    /// 直接求a·t²+b·t+c的开区间根；仅a精确为0才降阶，供拐点与偏移射线复用。
    static func quadraticRoots(_ a: Float, _ b: Float, _ c: Float, budget: inout GeometryBudget) throws -> [Float] {
        try budget.consume(32)
        try budget.reserve(2, stride: 16)
        try finite(SIMD4(a, b, c, 0))
        return try quadratic(a, b, c)
    }

    /// 二次判别式用Double计算，sqrt转Float；负判别式无根，不擅自把它钳到零。
    private static func quadratic(_ a: Float, _ b: Float, _ c: Float) throws -> [Float] {
        if a == 0 { return divide(-c, by: b).map { [$0] } ?? [] }
        let discriminant = Double(b) * Double(b) - 4 * Double(a) * Double(c)
        if discriminant < 0 { return [] }
        let root = Float(discriminant.squareRoot())
        guard root.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        let q = b < 0 ? -(b - root) / 2 : -(b + root) / 2
        guard q.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        var values: [Float] = []
        if let value = divide(q, by: a) { values.append(value) }
        if let value = divide(c, by: q) { values.append(value) }
        if values.count == 2 {
            if values[0] > values[1] { values.swapAt(0, 1) }
            else if values[0] == values[1] { values.removeLast() }
        }
        return values
    }

    /// 源valid_unit_divide先比较分子分母再相除；精确端点和Float除法下溢为零均不返回根。
    private static func divide(_ numerator: Float, by denominator: Float) -> Float? {
        let numeratorSign: Float = numerator < 0 ? -1 : 1
        let numerator = numerator * numeratorSign, denominator = denominator * numeratorSign
        guard denominator != 0, numerator != 0, numerator < denominator else { return nil }
        let value = numerator / denominator
        return value.isFinite && value != 0 ? value : nil
    }

    /// 不让非有限中间值经过min/max变成貌似合法的端点；精度超限要终止整个准备。
    private static func finite(_ values: SIMD4<Float>) throws {
        guard values.x.isFinite, values.y.isFinite, values.z.isFinite, values.w.isFinite else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
    }
}
