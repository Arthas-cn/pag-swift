/// 场景准备或单次计划的保守逻辑计量；共享输入像素不重复收费。
struct FramePlanBudget {
    /// 正字节上限，可由测试注入；不是 allocator 驻留峰值。
    let limit: Int
    /// 当前受限资源的诊断名称，区分准备资源和逐帧计划。
    private let resourceName: String
    /// 本次已经预留的累计成本，失败不回退或发布部分计划。
    private(set) var used = 0

    /// 保存调用入口已验证的正限制；准备阶段使用独立资源名称和独立计数器。
    init(limit: Int, resourceName: String = "maximumFramePlanBytes") {
        self.limit = limit
        self.resourceName = resourceName
    }

    /// 在分配前预留非负成本，乘法或总量超出上限时抛资源错误。
    mutating func reserve(count: Int = 1, stride: Int) throws {
        let bytes = count.multipliedReportingOverflow(by: stride)
        guard !bytes.overflow, bytes.partialValue >= 0, bytes.partialValue <= limit - used else {
            throw PAGError.resourceLimitExceeded(resourceName)
        }
        used += bytes.partialValue
    }
}
