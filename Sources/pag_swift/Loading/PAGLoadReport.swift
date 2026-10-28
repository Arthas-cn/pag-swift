import Foundation

/// 此次请求取得解析结果的路径；命中前仍需读取并计算完整摘要。
public enum PAGCacheDisposition: String, Sendable, Codable {
    /// 来源准备尚未完成，无法判断缓存路径。
    case unavailable
    /// 使用已完成且仍在预算内的不可变解析结果。
    case hit
    /// 未命中，由此请求发起一次新解析。
    case miss
    /// 加入另一请求已经发起的解析。
    case shared
    /// uncached 或准备期间失效，独立解析且不写回。
    case bypassed
}

/// 一次载入的终止结果，独立于后续渲染和播放结果。
public enum PAGLoadStatus: String, Sendable, Codable {
    /// 完整验证并返回不可变文档。
    case succeeded
    /// 来源、格式或资源校验失败，具体错误保存在报告中。
    case failed
    /// 调用者取消；不代表其它共享等待者取消。
    case cancelled
}

/// Loader 的只读计数和占用，计费字节不等于进程物理内存。
public struct PAGCacheStatistics: Sendable, Codable {
    /// 生命周期内直接命中已完成解析的请求数。
    public internal(set) var hits = 0
    /// 生命周期内查询缓存但未命中的请求数，包含随后加入共享的请求。
    public internal(set) var misses = 0
    /// 生命周期内加入已有解析的请求数。
    public internal(set) var sharedRequests = 0
    /// 实际启动的解析次数，包含独立和失败的解析。
    public internal(set) var parses = 0
    /// 因容量不足淘汰的条目数，不包含主动清理或 reload。
    public internal(set) var evictions = 0
    /// 显式 removeCachedFiles 或 reload 次数；一次 reload 只计一次。
    public internal(set) var invalidations = 0
    /// 已终止的失败请求数，不包含取消。
    public internal(set) var failures = 0
    /// 已终止的取消请求数。
    public internal(set) var cancellations = 0
    /// 最后等待者离开后仍返回的旧解析结果数。
    public internal(set) var discardedResults = 0
    /// 当前缓存的文档数量。
    public internal(set) var cachedFiles = 0
    /// 当前缓存的保守计费字节，不含调用方独自持有的文件。
    public internal(set) var cachedBytes = 0
    /// 留存上限；零仅禁用留存，仍允许并发共享。
    public internal(set) var byteLimit = 0
    /// 当前在途解析数，包含已撤销写回资格但仍服务有效调用者的任务。
    public internal(set) var inFlightParses = 0

    /// 创建 loader 独占的零计数器，不提供外部可变缓存入口。
    init() {}
}

/// 一次加载的不可变诊断；nil 耗时表示未执行或不可用，单位均为秒。
public struct PAGLoadReport: Sendable, Codable, Identifiable {
    /// 单次请求身份，可与宿主 runID/播放器身份关联。
    public let id: UUID
    /// 发起时的墙钟时间，仅供日志关联；耗时使用单调时钟。
    public let startedAt: Date
    /// 规范化本地路径；内存输入为 nil。
    public let sourcePath: String?
    /// 完整 SHA-256；来源或摘要失败时为 nil。
    public let documentIdentity: String?
    /// 此次调用指定的 useCache、reload 或 uncached。
    public let policy: String
    /// 成功、失败或取消，与缓存路径分开表达。
    public let status: PAGLoadStatus
    /// 此次取回文档所走的缓存路径。
    public let cache: PAGCacheDisposition
    /// 本地稳定快照读取与元数据验证耗时；内存输入为 nil。
    public let readSeconds: Double?
    /// 完整摘要耗时；失败前未完成时为 nil。
    public let digestSeconds: Double?
    /// 实际完整解析耗时；共享者看到同一次解析，命中为 nil。
    public let parseSeconds: Double?
    /// 仅 shared 请求自身等待的时间，与 parseSeconds 重叠而非相加。
    public let sharedWaitSeconds: Double?
    /// 从请求登记到结束的墙钟经过时间，使用单调时钟计算。
    public let totalSeconds: Double
    /// 失败错误的可读描述；成功为 nil。
    public let error: String?
    /// 完成时 loader 一致的计数和容量快照。
    public let statistics: PAGCacheStatistics
}

/// 成功加载及其对应报告，不把后续宿主编辑或播放器状态写回解析缓存。
public struct PAGLoadResult: Sendable {
    /// 完整验证的不可变 PAG 文件，可独立创建多个编辑值。
    public let file: PAGFile
    /// 与本次返回值一一对应的载入诊断。
    public let report: PAGLoadReport
}

/// 将单调时钟转换成诊断秒数，避免使用可跳变的 Date 计算耗时。
func loadElapsed(since start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}
