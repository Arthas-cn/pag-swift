/// Quad/Conic偏移的原参数射线；恰零导数只补首末弦，不采用Cubic的端点阈值或左半补救。
enum StrokeQuadraticSampling {
    /// 在二次曲线上生成有限ray；非法参数与半径/侧别报strokeQuadraticSampling，数值溢出报geometryPrecision。
    static func ray(_ curve: StrokeQuadCurve, at parameter: Float, radius: Float,
                    side: Float, budget: inout GeometryBudget) throws -> StrokeOffsetRay {
        try validate(parameter: parameter, radius: radius, side: side, budget: &budget)
        let position = try curve.position(at: parameter, budget: &budget)
        let direction = try curve.tangent(at: parameter, budget: &budget)
        return try make(position: position, direction: direction, chord: curve.end - curve.start, radius: radius, side: side)
    }

    /// 在原有理曲线全局参数上生成ray；原方向非有限仍进入源setLength失败回退。
    static func ray(_ curve: StrokeConicCurve, at parameter: Float, radius: Float,
                    side: Float, budget: inout GeometryBudget) throws -> StrokeOffsetRay {
        try validate(parameter: parameter, radius: radius, side: side, budget: &budget)
        let position = try curve.position(at: parameter, budget: &budget)
        let direction = try curve.tangent(at: parameter, budget: &budget)
        return try make(position: position, direction: direction, chord: curve.end - curve.start, radius: radius, side: side)
    }

    /// 直接缩放到radius后旋转偏移；失败方向选默认轴，不能先Float单位化再乘radius。
    private static func make(position: SIMD2<Float>, direction: SIMD2<Float>, chord: SIMD2<Float>,
                             radius: Float, side: Float) throws -> StrokeOffsetRay {
        let direction = direction == .zero ? chord : direction
        let scaled = StrokeLineMath.scaled(direction, length: radius) ?? SIMD2(radius, 0)
        let offset = try StrokeCurveMath.checked(SIMD2(position.x + side * scaled.y, position.y - side * scaled.x))
        let tangent = try StrokeCurveMath.checked(offset + scaled)
        return StrokeOffsetRay(curve: position, offset: offset, tangent: tangent)
    }

    /// 每次真实采样先计费并检查取消，随后调用曲线方法时继续扣其实际求值成本。
    private static func validate(parameter: Float, radius: Float, side: Float, budget: inout GeometryBudget) throws {
        try budget.consume(32)
        guard parameter.isFinite, parameter >= 0, parameter <= 1, radius.isFinite, radius > 0,
              side == 1 || side == -1 else { throw PAGError.invalidArgument("strokeQuadraticSampling") }
    }
}
