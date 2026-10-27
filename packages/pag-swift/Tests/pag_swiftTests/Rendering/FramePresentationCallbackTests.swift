import Foundation
import Testing
@testable import pag_swift

/// 模拟系统持有 drawable 内部锁的呈现回调；回调退出不能依赖正在 present 的播放门。
struct FramePresentationCallbackTests {
    /// 提交持锁时系统回调仍能立即退出；异步处理后才产生真实呈现诊断。
    @Test func presentationCallbackReturnsWhileSubmissionHoldsGate() async throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        #expect(mailbox.finishMutation(epoch, configuration: DisplayTargetConfiguration(
            geometry: try DisplayGeometry(size: PAGSize(width: 16, height: 16), scale: 1),
            isMounted: true, isActive: true)))
        let gate = PlaybackSubmissionGate()
        let token = PlaybackRequestToken(documentID: nil, compositionRevision: 1,
            playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
        gate.allow(token)
        let diagnostics = PlaybackDiagnosticSession(playerID: UUID())
        let request = PlaybackFrameRequest(scene: nil, time: .zero, scaleMode: .aspectFit,
            token: token, gate: gate, endsPlayback: false, diagnostics: diagnostics)
        let receipt = FramePresentationReceipt(request: request, mailbox: mailbox,
            placeholderIDs: [], marqueeIDs: [])
        let returned = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let callbackFinished = DispatchSemaphore(value: 0)
                let finishedUnderLock = gate.withPermission(for: token) {
                    DispatchQueue.global().async {
                        receipt.presented(at: request.sampledHostTime + 0.1)
                        callbackFinished.signal()
                    }
                    // 有界等待模拟 Capture present 必须等系统回调退出；旧实现超时后也能释放锁收尾。
                    return callbackFinished.wait(timeout: .now() + 1) == .success
                }
                continuation.resume(returning: finishedUnderLock == true)
            }
        }
        #expect(returned)
        try await waitForPresentationUpdate { diagnostics.snapshot.presentedFrames == 1 }
    }
}

/// 等待实际诊断变化；两秒只作为故障截止，不把固定延时当作处理完成。
func waitForPresentationUpdate(_ predicate: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() {
        // 回调未到不能冒充已处理；截止后给出确定失败而不遗留永久等待。
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
}
