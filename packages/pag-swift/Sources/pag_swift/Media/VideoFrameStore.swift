import Dispatch
import Foundation

/// 单播放器的内嵌视频媒体owner；有界缓存原始输入帧，不做图层合成或最终画面缓存。
actor VideoFrameStore {
    /// 同步VT调用只占用专用后台执行器，不阻塞MainActor或协作线程池。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.video", qos: .userInitiated)
    /// actor全部同步工作由该真实串行队列执行。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 关闭工作在此等待同步decode退出后才失效；每次会话替换前排空，不让MainActor等待。
    private let cleanup = DispatchQueue(label: "pag.video.cleanup", qos: .userInitiated)
    /// 库保留的像素输入上限，不伪称包含系统不可见的解码参考帧。
    private let maximumBytes: Int
    /// 可选内部验收观察点，可以来自系统回调或清理队列；不允许在闭包里直接访问actor状态。
    private let onEvent: (@Sendable (VideoDecodeEvent) -> Void)?
    /// 从旧到新的最多四条序列，当前工作条目暂时移出，成功后才放回。
    private var entries: [VideoFrameEntry] = []
    /// 累计实际提交给VT的样本数，供内部验证缓存/seek没有全片重解。
    private(set) var decodedSampleCount = 0

    /// 设置库输入工作集预算；零或负值会在请求时明确失败。
    init(maximumBytes: Int = 64 * 1024 * 1024, onEvent: (@Sendable (VideoDecodeEvent) -> Void)? = nil) {
        self.maximumBytes = maximumBytes
        self.onEvent = onEvent
    }

    /// 请求合法逻辑帧；取消令牌在等待owner前就存在，结束后失去会话撤销权。
    nonisolated func frame(for sequence: SourceVideoSequence, at frame: Int64) async throws -> VideoFrameTransfer {
        let request = VideoDecodeRequest()
        return try await withTaskCancellationHandler {
            try await decode(sequence, at: frame, request: request)
        } onCancel: {
            request.cancel()
        }
    }

    /// 返回库保留的实际缓冲成本，不包含调用方已经取得的交接槽或系统参考帧。
    func retainedBytes() -> Int { entries.reduce(0) { $0 + $1.byteCount } }

    /// 缓存会话数量，最多4；仅用于内部压力和淘汰验证。
    func retainedSequenceCount() -> Int { entries.count }

    /// 没有await的完整求帧事务；错误和取消丢弃该会话，旧请求不能留下半更新解码状态。
    private func decode(_ sequence: SourceVideoSequence, at frame: Int64,
                        request: VideoDecodeRequest) throws -> VideoFrameTransfer {
        dispatchPrecondition(condition: .onQueue(executor))
        defer { request.finish() }
        try Task.checkCancellation()
        guard maximumBytes > 0, frame >= 0, frame < sequence.samples.count else {
            throw PAGError.invalidArgument("videoFrame")
        }
        let targetIndex = sequence.sampleIndex(at: frame)
        let target = sequence.samples[targetIndex].frame
        let minimumBytes = Int(sequence.decodedSize.width) * Int(sequence.decodedSize.height) * 3 / 2
        let entry: VideoFrameEntry
        if let index = entries.firstIndex(where: { $0.identity == sequence.identity }) {
            entry = entries.remove(at: index)
        } else {
            if entries.count == 4 { retireFirst() }
            entry = VideoFrameEntry(identity: sequence.identity)
        }
        do {
            // 先取出当前序列再计工作成本，避免缓存命中时把自身当作可淘汰的其他资源。
            try makeRoom(for: max(entry.byteCount, minimumBytes))
            if entry.current?.frame != target {
                try advance(entry, sequence: sequence, targetIndex: targetIndex, request: request,
                            minimumBytes: minimumBytes)
            }
            try Task.checkCancellation()
            guard let current = entry.current, current.frame == target else {
                throw PAGError.mediaFailure("videoMissingTargetFrame")
            }
            let transfer = try VideoFrameTransfer(current, sequence: sequence)
            entries.append(entry)
            return transfer
        } catch {
            // 失败后不复用部分推进的参考帧或被撤销的会话；显示端已有输入由自己的引用保活。
            entry.session?.lifetime.closeAndDrain()
            throw error
        }
    }

    /// 从可用当前状态或最近关键帧推进，最多保留两个PTS早到帧，不按编码索引假装显示顺序。
    private func advance(_ entry: VideoFrameEntry, sequence: SourceVideoSequence, targetIndex: Int,
                         request: VideoDecodeRequest, minimumBytes: Int) throws {
        let target = sequence.samples[targetIndex].frame
        if let cached = entry.pending.removeValue(forKey: target) {
            entry.current = cached
            entry.pending = entry.pending.filter { $0.key > target }
            return
        }
        entry.current = nil
        entry.pending = entry.pending.filter { $0.key > target }
        let keyframe = sequence.keyframeIndex(before: target)
        if entry.session?.lifetime.isOpen != true || targetIndex < entry.nextIndex || keyframe > entry.nextIndex {
            entry.session?.lifetime.closeAndDrain()
            entry.session = nil
            entry.pending.removeAll()
            try Task.checkCancellation()
            let observer = onEvent
            entry.session = try H264Session(sequence: sequence, cleanup: cleanup,
                                            willWaitForDecode: { observer?(.waitingForDecode) },
                                            willInvalidate: { observer?(.invalidating) })
            entry.nextIndex = keyframe
        }
        guard let session = entry.session else { throw PAGError.mediaFailure("videoMissingSession") }
        try request.install(session.lifetime)
        while entry.nextIndex <= targetIndex {
            try Task.checkCancellation()
            try makeRoom(for: entry.byteCount + minimumBytes)
            let index = entry.nextIndex
            decodedSampleCount += 1
            let observer = onEvent
            let output = try session.decode(sequence.samples[index], index: index, sequence: sequence,
                                            didOutput: { observer?(.output(index: index)) })
            try Task.checkCancellation()
            try makeRoom(for: entry.byteCount + output.byteCount)
            entry.nextIndex += 1
            if output.frame == target { entry.current = output }
            else if output.frame > target { entry.pending[output.frame] = output }
            // 读取器已经验证重排深度；运行期仍防止系统输出或内部调用破坏保留上限。
            guard entry.pending.count <= 2 else { throw PAGError.mediaFailure("videoPendingFrameLimit") }
        }
    }

    /// 当前工作条目不在entries内；先淘汰其他序列，无法容纳单请求则明确失败。
    private func makeRoom(for workingBytes: Int) throws {
        guard workingBytes >= 0, workingBytes <= maximumBytes else {
            throw PAGError.resourceLimitExceeded("maximumVideoFrameBytes")
        }
        while retainedBytes() > maximumBytes - workingBytes { retireFirst() }
    }

    /// 排空最旧会话的清理再释放条目，不能靠异步析构积累无界VT会话。
    private func retireFirst() {
        let entry = entries.removeFirst()
        entry.session?.lifetime.closeAndDrain()
    }
}

/// 只传标量的内部验收事件，不承载系统帧或赋予调用方播放控制权。
enum VideoDecodeEvent: Sendable {
    /// VT回调已经产生输出，但同步decode尚未返回；关联值为编码索引。
    case output(index: Int)
    /// 独立清理工作已排队，即将等待在途Decode退出，尚不能调用系统Invalidate。
    case waitingForDecode
    /// Decode及同步回调已经退出，独立清理队列即将调用Invalidate，仍不代表关闭完成。
    case invalidating
}

/// 当前媒体owner独占的序列状态，缓存淘汰与失败都不会修改已交接的只读缓冲。
private final class VideoFrameEntry {
    /// 完整压缩序列身份，文件内ID和分辨率不足以作为键。
    let identity: DocumentIdentity
    /// 当前硬件会话，尚未创建或重建中为nil。
    var session: H264Session?
    /// 下一条需要按编码顺序送入VT的样本索引。
    var nextIndex = 0
    /// 最近成功的实际显示帧，新的工作可以释放本引用但不修改缓冲。
    var current: VideoDecodedFrame?
    /// 最多两个未来显示帧，以实际PTS索引，不存放已经过时的输出。
    var pending: [Int64: VideoDecodedFrame] = [:]
    /// 此条目实际保留的像素成本；输入帧数组只有最多三个元素。
    var byteCount: Int { (current?.byteCount ?? 0) + pending.values.reduce(0) { $0 + $1.byteCount } }

    /// 建立尚未分配系统资源的缓存条目。
    init(identity: DocumentIdentity) { self.identity = identity }
}
