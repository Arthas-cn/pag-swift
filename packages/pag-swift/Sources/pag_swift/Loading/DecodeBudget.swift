/// 一次解码的保守逻辑内存计量；在分配源节点、索引与实例之前检查。
struct DecodeBudget {
    /// 调用者设定的正上限，不代表 allocator 的精确驻留峰值。
    let limit: Int
    /// 已预留的估计字节，单调增加，失败不会返回部分文档。
    private(set) var used: Int = 0

    /// 预留非负成本；先减后比避免攻击性长度相加溢出。
    mutating func reserve(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= limit - used else {
            throw PAGError.resourceLimitExceeded("maximumDecodedBytes")
        }
        used += bytes
    }

    /// 按元素数和保守步长预留数组/哈希表成本，乘法溢出同样视为超限。
    mutating func reserve(count: Int, stride: Int) throws {
        let cost = count.multipliedReportingOverflow(by: stride)
        guard !cost.overflow else { throw PAGError.resourceLimitExceeded("maximumDecodedBytes") }
        try reserve(cost.partialValue)
    }
}
