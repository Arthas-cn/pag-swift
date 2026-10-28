import Testing
@testable import pag_swift

/// 测试中的材料分支断言；生产模型不为旧纯色断言增加有歧义的color访问器。
extension ShapeMaterial {
    /// 取出预期纯色；遇到渐变立即使当前测试失败，不默认补一种颜色。
    func solidColor() throws -> SceneColor {
        guard case .solid(let value) = self else {
            Issue.record("预期纯色材料，实际为渐变")
            throw PAGError.invalidArgument("expectedSolidMaterial")
        }
        return value
    }

    /// 取出预期渐变；遇到纯色立即失败，供身份、矩阵及程序断言复用。
    func gradientValue() throws -> PreparedGradient {
        guard case .gradient(let value) = self else {
            Issue.record("预期渐变材料，实际为纯色")
            throw PAGError.invalidArgument("expectedGradientMaterial")
        }
        return value
    }
}
