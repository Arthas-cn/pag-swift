import Foundation
import Synchronization

/// 播放事件的证据阶段；提交、GPU 完成和屏幕呈现不能互相代替。
public enum PAGPlaybackStage: String, Sendable, Codable {
    /// 场景安装或替换的完整资源准备已完成。
    case prepared
    /// 已向 Metal 队列提交命令，尚未证明执行或显示。
    case submitted
    /// Metal 已完成本次命令，仍可能被显示系统跳过。
    case gpuCompleted
    /// 系统给出了正的实际 presentedTime。
    case presented
    /// 系统呈现回调时间为零，表示未呈现或跳过。
    case presentationSkipped
    /// 当前目标未能提供 drawable。
    case drawableUnavailable
    /// 尚未开始的播放请求被更新请求合并。
    case coalesced
    /// 已完成工作因文档、播放或显示代数变化而丢弃。
    case discarded
}

/// 一条有界小值事件；不持有图像、文件或 GPU 对象。
public struct PAGPlaybackDiagnosticEvent: Sendable, Codable {
    /// 单会话开始后的单调秒数。
    public let elapsedSeconds: Double
    /// 此事件证明的实际阶段。
    public let stage: PAGPlaybackStage
    /// 帧工作身份；场景准备没有帧身份。
    public let requestID: UUID?
    /// 本次请求的 PAG 根微秒；非帧阶段为 nil。
    public let timeMicroseconds: Int64?
    /// 阶段耗时或系统呈现 host time，语义由 stage 决定；不可用为 nil。
    public let seconds: Double?
    /// 呈现是否仍属于有效代数；其它阶段没有此判断时为 nil。
    public let accepted: Bool?
}

/// 当前安装会话的只读汇总；GPU 计费不等于进程 RSS，nil 表示尚无测量。
public struct PAGPlaybackDiagnostics: Sendable, Codable {
    /// 播放器整个生命周期稳定的身份。
    public let playerID: UUID
    /// 每次成功 setComposition 的新会话；单槽内容更新保留此身份。
    public let sessionID: UUID
    /// 安装文件的完整摘要；没有合成时为 nil。
    public let documentIdentity: String?
    /// 最近一次场景准备的秒数，包含必要的媒体和字体准备。
    public internal(set) var preparationSeconds: Double?
    /// 发出命令的累计次数，不等于实际画面数。
    public internal(set) var submittedFrames = 0
    /// GPU 正常完成的累计次数，含后来被控制撤销的工作。
    public internal(set) var gpuCompletedFrames = 0
    /// 收到正呈现时间的累计次数；尚未收到可用证据为 nil。
    public internal(set) var presentedFrames: Int?
    /// 正时间但已过期的实际呈现数，不能激活当前内容时钟。
    public internal(set) var stalePresentedFrames = 0
    /// 系统回调明确给出零时间的次数。
    public internal(set) var skippedPresentations = 0
    /// 提交时取不到 drawable 的次数，和宿主未挂载分开。
    public internal(set) var drawableFailures = 0
    /// 待处理请求被合并的次数，不能直接换算为显示丢帧率。
    public internal(set) var coalescedRequests = 0
    /// 控制代数使已完成工作过期的次数。
    public internal(set) var discardedRequests = 0
    /// 会话开始到首次命令提交的秒数。
    public internal(set) var firstSubmitSeconds: Double?
    /// 会话开始到首次 GPU 完成回调的秒数。
    public internal(set) var firstGPUCompletionSeconds: Double?
    /// 会话开始到首次有效呈现回调的秒数，无法测得保持 nil。
    public internal(set) var firstPresentationSeconds: Double?
    /// 所有有效 GPU 时间区间之和；设备未给正区间时为 nil。
    public internal(set) var totalGPUSeconds: Double?
    /// 最近完整帧计划和 Metal 输入准备的 CPU 秒数。
    public internal(set) var framePreparationSeconds: Double?
    /// 单帧准备最大秒数，便于定位复杂资源。
    public internal(set) var maximumFramePreparationSeconds: Double?
    /// 最近帧中确实绘制且处于播放状态的跑马灯实例数。
    public internal(set) var activeMarqueeInstances = 0
    /// 宿主帧输入集合相对上一帧改变的次数；仅说明输入变化，不证明屏幕像素。
    public internal(set) var hostFrameChanges = 0
    /// 最近帧图像输入的 RGBA 总字节，不包含 GPU 纹理。
    public internal(set) var frameImageBytes: Int?
    /// 当前 Metal 输入 LRU 的保守计费字节。
    public internal(set) var retainedInputBytes: Int?
    /// 当前局部效果借用与空闲池的保守字节。
    public internal(set) var groupTextureBytes: Int?
    /// 当前局部 Picture 借用与留存的保守字节。
    public internal(set) var pictureTextureBytes: Int?
    /// 输入 LRU 的配置上限，与局部纹理池是分别独立的预算。
    public internal(set) var inputByteLimit: Int?
    /// 动图 owner 当前保留帧字节；没有动图 owner 为 nil。
    public internal(set) var animatedFrameBytes: Int?
    /// 动图解码及当前 RGBA 工作的预算；不包含宿主 decoder 自有内存。
    public internal(set) var animatedFrameByteLimit: Int?
    /// 动图同步 worker 的三画布预留；与 animatedFrameBytes 共用同一预算，未安装时为 nil。
    public internal(set) var animatedDecodingBytes: Int?
    /// 最近帧计划观察到的待解码需求数，上限 16；没有动图 owner 为 nil。
    public internal(set) var animatedPendingFrames: Int?
    /// 最近帧计划观察到的实际同步工作数，范围 0...1；没有动图 owner 为 nil。
    public internal(set) var animatedDecodingFrames: Int?
    /// 当前媒体 owner 累计宿主读取失败次数；失败只回退对应素材。
    public internal(set) var hostFrameFailures: Int?
    /// 最近宿主帧错误；没有动图或尚无错误为 nil。
    public internal(set) var lastHostFrameFailure: String?
    /// 最近已准备帧所属内嵌视频 owner 的策略；没有内嵌视频为 nil。
    public internal(set) var videoDecodingPolicy: PAGVideoDecodingPolicy?
    /// 最近帧观察到系统明确使用硬解的当前会话数；尚未测量或没有内嵌视频为 nil。
    public internal(set) var hardwareVideoDecoderSessions: Int?
    /// 最近帧观察到系统明确未使用硬解的当前会话数；不是按 automatic 配置推测。
    public internal(set) var softwareVideoDecoderSessions: Int?
    /// 最近帧观察到系统查询无结果的当前会话数；未知不能计入硬解或软件解码。
    public internal(set) var unknownVideoDecoderSessions: Int?
    /// 最近 128 条阶段事件，完整计数不因事件淘汰清零。
    public internal(set) var events: [PAGPlaybackDiagnosticEvent] = []
}

/// 帧回调与播放器共享的小值诊断；短锁不做磁盘写入或用户回调。
final class PlaybackDiagnosticSession: Sendable {
    /// 诊断时间原点，跨线程保持单调。
    private let started = ContinuousClock.now
    /// 所有统计及最近输入集合在同一锁内更新。
    private let state: Mutex<PlaybackDiagnosticState>

    /// 成功安装创建新对象，旧 GPU 回调只能更新旧会话，不能污染新文件报告。
    init(playerID: UUID, document: DocumentIdentity? = nil) {
        let identity = document?.digest.map { String(format: "%02x", $0) }.joined()
        state = Mutex(PlaybackDiagnosticState(value: PAGPlaybackDiagnostics(
            playerID: playerID, sessionID: UUID(), documentIdentity: identity)))
    }

    /// 只复制小值快照及最多 128 条事件，不暴露可变锁。
    var snapshot: PAGPlaybackDiagnostics { state.withLock { $0.value } }

    /// 写一条真实阶段记录，同时累计不能由截断历史重建的计数。
    func record(_ stage: PAGPlaybackStage, token: PlaybackRequestToken? = nil,
                time: PAGTime? = nil, seconds: Double? = nil, accepted: Bool? = nil) {
        let elapsed = loadElapsed(since: started)
        state.withLock { state in
            switch stage {
            case .prepared: state.value.preparationSeconds = seconds
            case .submitted:
                state.value.submittedFrames += 1
                if state.value.firstSubmitSeconds == nil { state.value.firstSubmitSeconds = elapsed }
            case .gpuCompleted:
                state.value.gpuCompletedFrames += 1
                if state.value.firstGPUCompletionSeconds == nil { state.value.firstGPUCompletionSeconds = elapsed }
                if let seconds, seconds > 0 { state.value.totalGPUSeconds = (state.value.totalGPUSeconds ?? 0) + seconds }
            case .presented:
                state.value.presentedFrames = (state.value.presentedFrames ?? 0) + 1
                if accepted == true, state.value.firstPresentationSeconds == nil { state.value.firstPresentationSeconds = elapsed }
                if accepted == false { state.value.stalePresentedFrames += 1 }
            case .presentationSkipped: state.value.skippedPresentations += 1
            case .drawableUnavailable: state.value.drawableFailures += 1
            case .coalesced: state.value.coalescedRequests += 1
            case .discarded: state.value.discardedRequests += 1
            }
            state.value.events.append(PAGPlaybackDiagnosticEvent(elapsedSeconds: elapsed, stage: stage,
                requestID: token?.requestID, timeMicroseconds: time?.microseconds, seconds: seconds, accepted: accepted))
            if state.value.events.count > 128 { state.value.events.removeFirst(state.value.events.count - 128) }
        }
    }

    /// 帧计划完成后记录输入集合与成本；只保存摘要，不保活任何像素。
    func preparedFrame(_ frame: PreparedFrame, seconds: Double, retainedInputs: Int,
                       groupTextures: Int, pictureTextures: Int, inputLimit: Int,
                       animation: AnimatedFrameDiagnostics?, video: VideoDecoderDiagnostics? = nil) {
        let frames = Set(frame.images.filter { $0.value.storage.sourceType == "pag.hostFrame" }.keys)
        let imageBytes = frame.images.values.reduce(0) { $0 + $1.storage.pixels.count }
        state.withLock { state in
            if !frames.isEmpty, !state.hostFrames.isEmpty, frames != state.hostFrames { state.value.hostFrameChanges += 1 }
            state.hostFrames = frames
            state.value.framePreparationSeconds = seconds
            state.value.maximumFramePreparationSeconds = max(seconds, state.value.maximumFramePreparationSeconds ?? 0)
            state.value.activeMarqueeInstances = frame.marqueeIDs.count
            state.value.frameImageBytes = imageBytes
            state.value.retainedInputBytes = retainedInputs
            state.value.groupTextureBytes = groupTextures
            state.value.pictureTextureBytes = pictureTextures
            state.value.inputByteLimit = inputLimit
            state.value.animatedFrameBytes = animation?.retainedBytes
            state.value.animatedFrameByteLimit = animation?.byteLimit
            state.value.animatedDecodingBytes = animation?.decodingBytes
            state.value.animatedPendingFrames = animation?.pendingFrames
            state.value.animatedDecodingFrames = animation?.decodingFrames
            state.value.hostFrameFailures = animation?.hostFailures
            state.value.lastHostFrameFailure = animation?.lastHostFailure
            state.value.videoDecodingPolicy = video?.policy
            state.value.hardwareVideoDecoderSessions = video?.hardwareSessions
            state.value.softwareVideoDecoderSessions = video?.softwareSessions
            state.value.unknownVideoDecoderSessions = video?.unknownSessions
        }
    }
}

/// 诊断锁中的有限状态；输入集合最多与一个已受帧预算约束的计划同大。
private struct PlaybackDiagnosticState {
    /// 公开汇总的唯一可变副本。
    var value: PAGPlaybackDiagnostics
    /// 上一份计划的宿主帧摘要，空表示尚无宿主帧输入。
    var hostFrames: Set<DocumentIdentity> = []
}
