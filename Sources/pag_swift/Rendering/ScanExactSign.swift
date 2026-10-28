import Foundation

/// 区间无法判符号时的有限精确展开；只处理扫描边界冷分支，不替代常规插值。
enum ScanExactSign {
    /// 比较同一高度的两条边；分母为正，直接取三项三重积分子的精确符号。
    static func difference(_ left: ScanBoundary, _ right: ScanBoundary, at y: Double,
                           budget: inout GeometryBudget) throws -> Int {
        let dx = try ScanExpansion.difference(left.lower.x, right.lower.x, budget: &budget)
        let ly = try ScanExpansion.difference(left.upper.y, left.lower.y, budget: &budget)
        let ry = try ScanExpansion.difference(right.upper.y, right.lower.y, budget: &budget)
        let lx = try ScanExpansion.difference(left.upper.x, left.lower.x, budget: &budget)
        let rx = try ScanExpansion.difference(right.upper.x, right.lower.x, budget: &budget)
        let yl = try ScanExpansion.difference(y, left.lower.y, budget: &budget)
        let yr = try ScanExpansion.difference(y, right.lower.y, budget: &budget)
        var result = try dx.multiplied(by: ly, budget: &budget).multiplied(by: ry, budget: &budget)
        let second = try yl.multiplied(by: lx, budget: &budget).multiplied(by: ry, budget: &budget)
        let third = try yr.multiplied(by: rx, budget: &budget).multiplied(by: ly, budget: &budget)
        for value in second.components { try result.add(value, budget: &budget) }
        for value in third.components { try result.add(-value, budget: &budget) }
        guard let leading = result.components.last else { return 0 }
        return leading > 0 ? 1 : -1
    }
}

/// 按幅度递增、互不重叠的Double误差展开；空数组表示精确零，最多128项。
private struct ScanExpansion {
    /// 每项之和是精确实数结果，末项决定非零展开的符号。
    private(set) var components: [Double] = []

    /// 以TwoSum构造精确差；不把相消后的低位直接丢掉。
    static func difference(_ first: Double, _ second: Double,
                           budget: inout GeometryBudget) throws -> ScanExpansion {
        var result = ScanExpansion()
        try result.add(first, budget: &budget)
        try result.add(-second, budget: &budget)
        return result
    }

    /// 原地并入精确项，保留每步余项；失败后局部累加器不可复用，整个精确查询必须退出。
    mutating func add(_ value: Double, budget: inout GeometryBudget) throws {
        try budget.consume()
        guard value.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
        if value == 0 { return }
        guard components.count < 128 else { throw PAGError.renderingFailure("geometryOrdering") }
        try budget.reserve(components.count + 1, stride: 16)
        let count = components.count
        components.reserveCapacity(count + 1)
        var written = 0
        var carry = value
        // 写指针最多追到当前读下标；先读局部值，不能用for-in保活旧数组并触发COW。
        for index in 0..<count {
            try budget.consume()
            let component = components[index]
            let sum = carry + component
            guard sum.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
            // TwoSum不要求两项的幅度有序；保留真实加法与已舍入sum之间的差。
            let shifted = sum - carry
            let restored = sum - shifted
            let firstError = carry - restored, secondError = component - shifted
            let remainder = firstError + secondError
            guard shifted.isFinite, restored.isFinite, firstError.isFinite, secondError.isFinite,
                  remainder.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
            if remainder != 0 {
                components[written] = remainder
                written += 1
            }
            carry = sum
        }
        if carry != 0 {
            if written < count { components[written] = carry }
            else { components.append(carry) }
            written += 1
        }
        components.removeLast(components.count - written)
    }

    /// 分配有界乘积展开；FMA残差必须能够精确表示，不能用静默下溢的零当作证明。
    func multiplied(by other: ScanExpansion, budget: inout GeometryBudget) throws -> ScanExpansion {
        var result = ScanExpansion()
        for first in components {
            for second in other.components {
                try budget.consume()
                // 每个Double至多53有效位。指数和至少−970保证乘积最低位不低于2^-1074。
                let exponent = first.exponent + second.exponent
                guard exponent >= -970, exponent <= 1022 else {
                    throw PAGError.renderingFailure("geometryOrdering")
                }
                let product = first * second
                guard product.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
                let remainder = (-product).addingProduct(first, second)
                try result.add(remainder, budget: &budget)
                try result.add(product, budget: &budget)
            }
        }
        return result
    }
}
