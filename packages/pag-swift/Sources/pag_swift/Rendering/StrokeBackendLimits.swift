/// 普通描边的内部接纳策略；限制输入、临时边界与留存输出，不把逻辑计费当作allocator峰值。
struct StrokeBackendLimits: Sendable {
    /// 进入描边构造前允许的规范化指令数量，包含未转换的Quad/Conic。
    let maximumInputVerbs: Int
    /// 临时中心线或dash结果的控制点数量上限，曲线仍保留原类型。
    let maximumInputPoints: Int
    /// 输入独立子路径数量，包括仅Move的轮廓。
    let maximumSubpaths: Int
    /// 弧长上界估算的理想on段数量上限，零on也计入。
    let maximumDashPieces: Int
    /// 实际边界和最终输出允许留存的元素数量上限。
    let maximumOutputElements: Int
    /// stroke坐标、宽度及叠加端点/斜接扩张后的理想包络最大幅度。
    let maximumMagnitude: Double

    /// 默认接纳策略；常量不是PAG格式上限或驻留成本证明。
    static let standard = StrokeBackendLimits(standardDefaults: ())

    /// 创建可缩小的内部策略供边界验证；非正数量或非正/非有限幅度抛invalidArgument。
    init(maximumInputVerbs: Int = 16_384, maximumInputPoints: Int = 49_152,
         maximumSubpaths: Int = 4_096, maximumDashPieces: Int = 32_768,
         maximumOutputElements: Int = 262_144, maximumMagnitude: Double = 16_777_216) throws {
        guard [maximumInputVerbs, maximumInputPoints, maximumSubpaths, maximumDashPieces, maximumOutputElements].allSatisfy({ $0 > 0 }),
              maximumMagnitude.isFinite, maximumMagnitude > 0 else { throw PAGError.invalidArgument("strokeBackendLimits") }
        self.maximumInputVerbs = maximumInputVerbs
        self.maximumInputPoints = maximumInputPoints
        self.maximumSubpaths = maximumSubpaths
        self.maximumDashPieces = maximumDashPieces
        self.maximumOutputElements = maximumOutputElements
        self.maximumMagnitude = maximumMagnitude
    }

    /// 仅用于已知合法的固定默认值，避免静态初始化强制解包错误。
    private init(standardDefaults: Void) {
        maximumInputVerbs = 16_384
        maximumInputPoints = 49_152
        maximumSubpaths = 4_096
        maximumDashPieces = 32_768
        maximumOutputElements = 262_144
        maximumMagnitude = 16_777_216
    }

    /// 在数组增长前检查实际stroke坐标幅度，超限明确失败而非继续生成巨大路径。
    func check(_ point: ScenePoint) throws {
        guard point.x.isFinite, point.y.isFinite,
              abs(point.x) <= maximumMagnitude, abs(point.y) <= maximumMagnitude else {
            throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude")
        }
    }
}
