import CoreMedia
import Dispatch
import Foundation
import Synchronization
import VideoToolbox

/// VT会话的局部同步桥：解码与一次后台失效互斥，取消只撤销接纳，不向调用方泄露会话引用。
final class VideoSessionLifetime: @unchecked Sendable {
    /// 保护会话引用及关闭标志，锁内不能调用VT或等待队列。
    private let lock = NSLock()
    /// 解码和实际Invalidate共用的执行锁；取消回调不取锁，仅后台清理可等待在途解码退出。
    private let decoding = NSLock()
    /// 原始会话只由本桥持有，关闭工作取得强引用后在锁外失效。
    private var session: VTDecompressionSession?
    /// 一旦请求关闭就不再接受新输入，不等系统Invalidate结束才阻止提交。
    private var closing = false
    /// 与owner分离的串行清理队列，系统关闭和执行锁等待都不占用MainActor。
    private let cleanup: DispatchQueue
    /// 内部验收观察点，清理已排队并即将等待执行锁；不代表系统Invalidate已经开始。
    private let willWaitForDecode: (@Sendable () -> Void)?
    /// 内部验收观察点，清理队列即将调用VT时通知；生产为nil，不影响状态机。
    private let willInvalidate: (@Sendable () -> Void)?

    /// 接管新建会话；调用者不能再用原始引用解码或失效。
    init(session: VTDecompressionSession, cleanup: DispatchQueue,
         willWaitForDecode: (@Sendable () -> Void)? = nil, willInvalidate: (@Sendable () -> Void)? = nil) {
        self.session = session
        self.cleanup = cleanup
        self.willWaitForDecode = willWaitForDecode
        self.willInvalidate = willInvalidate
    }

    /// 关闭标志的短锁快照，不代表系统已经完成清理。
    var isOpen: Bool { lock.withLock { !closing } }

    /// 在后台同步解码一个样本；回调只发布到自己的锁槽，系统对象不跨async返回。
    func decode(_ sample: CMSampleBuffer, into slot: H264OutputSlot, didOutput: (@Sendable () -> Void)? = nil) throws -> OSStatus {
        guard decoding.try() else { throw PAGError.mediaFailure("concurrentVideoDecode") }
        defer { decoding.unlock() }
        guard let session = lock.withLock({ closing ? nil : self.session }) else { throw CancellationError() }
        // flags=[]保证返回前完成回调；执行锁覆盖两者，强引用本身不能防止VT内部被并行销毁。
        return VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, buffer, time, _ in
            slot.publish(status: status, buffer: buffer, time: time)
            didOutput?()
        }
    }

    /// 同步撤销输入资格并投递一次关闭；可以从任意取消回调调用，不等待VT。
    func close() {
        lock.withLock {
            guard !closing else { return }
            closing = true
            // 投递与标志一起排序，后续drain不能越过尚未入队的关闭任务。
            cleanup.async { self.invalidate() }
        }
    }

    /// 仅后台owner在VT调用返回后使用；排空关闭后才允许创建替代会话，限制清理积压。
    func closeAndDrain() {
        dispatchPrecondition(condition: .notOnQueue(cleanup))
        precondition(!Thread.isMainThread)
        close()
        cleanup.sync {}
    }

    /// 在专用清理队列等待Decode及同步回调退出，再取走引用失效；不持状态短锁调用系统。
    private func invalidate() {
        dispatchPrecondition(condition: .onQueue(cleanup))
        willWaitForDecode?()
        // 实测并行Invalidate可损坏RemoteVideoDecoder内部锁；只能在同步Decode彻底返回后销毁。
        decoding.lock()
        defer { decoding.unlock() }
        let previous = lock.withLock {
            let result = session
            session = nil
            return result
        }
        if let previous {
            willInvalidate?()
            VTDecompressionSessionInvalidate(previous)
        }
    }
}

/// 一次媒体请求的取消资格；checked Sendable状态只引用有锁会话桥，不包含裸系统对象。
final class VideoDecodeRequest: Sendable {
    /// 令牌结束与取消必须在同一短锁中排序，避免旧取消关闭后续请求复用的会话。
    private let state = Mutex(VideoDecodeRequestState())

    /// 注册当前会话；若排队期间已经取消，立即关闭它并拒绝继续解码。
    func install(_ session: VideoSessionLifetime) throws {
        try state.withLock {
            guard !$0.finished, !$0.cancelled else {
                session.close()
                throw CancellationError()
            }
            $0.session = session
        }
    }

    /// 取消只安排独立清理；短锁内close不会执行系统失效或等待其完成。
    func cancel() {
        state.withLock {
            guard !$0.finished else { return }
            $0.cancelled = true
            $0.session?.close()
        }
    }

    /// 结束后取消不再触碰会话；owner退出同步工作段之前必须调用。
    func finish() {
        state.withLock {
            $0.finished = true
            $0.session = nil
        }
    }
}

/// 取消令牌的纯同步状态，不决定播放代数或显示许可。
private struct VideoDecodeRequestState: Sendable {
    /// 请求曾被取消，初始false；结束前只能单向变true。
    var cancelled = false
    /// 请求不再拥有会话取消权，结束后不可重新注册。
    var finished = false
    /// 当前工作会话；尚未进入owner或已经结束时为nil。
    var session: VideoSessionLifetime?
}
