import Foundation
import Synchronization

/// 宿主按源槽决定内容；调用在后台执行，宿主负责网络和第三方图片库隔离。
public typealias PAGContentProvider = @Sendable (PAGContentSlot) async throws -> DynamicContent

/// 动态内容解析的等待与工作预算，不改变 PAG 播放时序。
public struct PAGContentOptions: Sendable {
    /// 从入队到 provider 结果的最长等待；超时后原播放继续。
    public let timeout: Duration
    /// 同时等待的请求数量，合法范围 1...16；不合作的旧 provider 另占硬配额。
    public let maximumConcurrentRequests: Int
    /// 等待或正在解析的请求总上限，合法范围 1...1024。
    public let maximumPendingRequests: Int

    /// 创建有限请求策略；非法时长或预算抛 invalidArgument。
    public init(timeout: Duration = .seconds(5), maximumConcurrentRequests: Int = 4,
                maximumPendingRequests: Int = 128) throws {
        guard timeout > .zero, timeout <= .seconds(300),
              (1...16).contains(maximumConcurrentRequests),
              (maximumConcurrentRequests...1024).contains(maximumPendingRequests) else {
            throw PAGError.invalidArgument("contentOptions")
        }
        self.timeout = timeout
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumPendingRequests = maximumPendingRequests
    }

    /// 五秒等待、四个并发、一百二十八个待处理请求。
    public static var standard: PAGContentOptions {
        // 常量在上方构造器合法区间内，不接受运行时不可信输入。
        try! PAGContentOptions()
    }
}

/// 单槽请求或提交的可观察阶段，不能作为 GPU 完成或实际画面证明。
public enum PAGContentEventStatus: String, Sendable, Codable {
    /// 请求已经入队，尚未承诺调用了宿主。
    case requested
    /// 占位已完成场景准备并安装。
    case placeholder
    /// 替换已完成场景准备并安装，仍须等待显示提交。
    case applied
    /// 宿主明确不提供覆盖，当前内容保持不变。
    case unchanged
    /// provider 或内容准备失败，保留之前已安装的内容或占位。
    case failed
    /// 等待期限已到，旧 provider 返回也不能生效。
    case timedOut
    /// 被新请求、文档切换或显式取消撤销。
    case cancelled
    /// 已撤销请求迟到返回，结果没有安装到合成。
    case discarded
}

/// 有界诊断中的单个内容事件；身份可关联宿主 runID，不暴露可变播放器内部状态。
public struct PAGContentEvent: Sendable, Codable {
    /// 日志记录时间，供报告和宿主其它阶段对齐。
    public let date: Date
    /// 完整 PAG 内容 SHA-256 十六进制值。
    public let documentIdentity: String
    /// 当前内容会话身份，换文件或更换 provider 后变化。
    public let sessionID: UUID
    /// 本次单槽请求的内容版本，连续更新同一 tag 时不同。
    public let contentVersion: UUID
    /// 文件槽位目录中的稳定键。
    public let tag: String
    /// 已知的内容类型，如 text、image.animated、hidden；provider 尚未返回时为 nil。
    public let contentType: String?
    /// 事件处于请求、安装或终止的哪一阶段。
    public let status: PAGContentEventStatus
    /// 入队后经过的秒数；单调时钟计算，不含安装后等待显示的时间。
    public let elapsedSeconds: Double
    /// 失败类别或补充信息；正常事件为 nil。
    public let detail: String?
}

/// 由 Mutex 管理的有界事件容器；迟到宿主工作只保留此容器，不保活播放器。
final class ContentEventLog: Sendable {
    /// 最多保存最近 256 条，不进行磁盘或 UI 工作。
    private let entries = Mutex<[PAGContentEvent]>([])
    /// 每个消费者独立的有界流；与历史记录分开，不让 UI 消费速度阻塞后台。
    private let observers = Mutex<[UUID: AsyncStream<PAGContentEvent>.Continuation]>([:])

    /// 复制当前有界快照供宿主异步导出。
    var snapshot: [PAGContentEvent] { entries.withLock { $0 } }

    /// 订阅未来的内容事件，取消后释放 continuation；每个消费者至多缓冲 256 条。
    func updates() -> AsyncStream<PAGContentEvent> {
        let id = UUID()
        let pair = AsyncStream.makeStream(of: PAGContentEvent.self, bufferingPolicy: .bufferingNewest(256))
        pair.continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { $0[id] = nil }
        }
        observers.withLock { $0[id] = pair.continuation }
        return pair.stream
    }

    /// 播放器释放时主动结束订阅；迟到 provider 的日志仍可记录但不保活 UI 消费者。
    func finishUpdates() {
        let continuations = observers.withLock {
            let values = Array($0.values)
            $0.removeAll()
            return values
        }
        for continuation in continuations { continuation.finish() }
    }

    /// 关联原请求身份记录阶段，超过容量时移除最早一条。
    func record(_ token: ContentRequestToken, _ status: PAGContentEventStatus, detail: String? = nil,
                content: DynamicContent? = nil) {
        let elapsed = token.started.duration(to: .now).components
        let event = PAGContentEvent(date: Date(), documentIdentity: token.document,
            sessionID: token.session, contentVersion: token.version, tag: token.tag,
            contentType: content.map(Self.typeName), status: status,
            elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, detail: detail)
        entries.withLock {
            if $0.count == 256 { $0.removeFirst() }
            $0.append(event)
        }
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations { continuation.yield(event) }
    }

    /// 记录语义类型，不展开宿主文字、像素或 URL 内容，保持日志成本有界。
    private static func typeName(_ content: DynamicContent) -> String {
        switch content {
        case .text: "text"
        case .image(let image, let options): "image.\(options.playbackMode == .still ? "still" : String(describing: image.kind))"
        case .imageURL: "imageURL"
        case .hidden: "hidden"
        case .original: "original"
        case .unchanged: "unchanged"
        }
    }
}

/// 请求完整身份；同名 tag 也必须同时满足文档、会话和版本检查。
struct ContentRequestToken: Sendable {
    /// 请求时不可变文档的完整摘要。
    let document: String
    /// 换 provider 或文档会撤销的会话。
    let session: UUID
    /// 同 tag 每次更新都创建新值。
    let version: UUID
    /// 对应业务槽。
    let tag: String
    /// 单调开始时间，用于期限和耗时。
    let started: ContinuousClock.Instant
}
