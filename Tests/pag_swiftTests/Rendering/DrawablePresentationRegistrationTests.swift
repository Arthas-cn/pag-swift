import Foundation
import Metal
import Testing
@testable import pag_swift

#if !targetEnvironment(simulator)
/// 覆盖公开 Metal 回调到库回执的接线；不把测试替身当作真实屏幕显示证据。
struct DrawablePresentationRegistrationTests {
    /// 系统返回零时间时只记录跳过，正时间则原样交给诊断且通过有效代数核验。
    @Test(arguments: [0.0, 42.5])
    func forwardsSystemPresentationTime(hostTime: Double) async throws {
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

        registerDrawablePresentation(PresentationTestDrawable(hostTime: hostTime), receipt: receipt)
        // 回执刻意离开系统回调后再处理，必须等到诊断变化，不能在登记返回时就断言完成。
        try await waitForPresentationUpdate { diagnostics.snapshot.events.isEmpty == false }
        let snapshot = diagnostics.snapshot
        let event = try #require(snapshot.events.last)
        if hostTime == 0 {
            #expect(event.stage == .presentationSkipped)
            #expect(snapshot.presentedFrames == nil)
            #expect(snapshot.firstPresentationSeconds == nil)
        } else {
            #expect(event.stage == .presented)
            #expect(event.seconds == hostTime)
            #expect(event.accepted == true)
            #expect(snapshot.presentedFrames == 1)
        }
        #expect(snapshot.gpuCompletedFrames == 0)
    }
}

/// 立即交付指定系统时间的不可变 drawable 替身，只验证登记接线，不分配 GPU 或显示资源。
private final class PresentationTestDrawable: NSObject, MTLDrawable {
    /// 模拟系统给出的 host time；零表示该帧没有呈现。
    let presentedTime: CFTimeInterval
    /// 协议所需的固定身份；此测试不参与 CAMetalLayer 的实际帧序列。
    let drawableID: Int = 0

    /// 建立只返回给定时间的替身。
    init(hostTime: Double) { presentedTime = hostTime }

    /// 立即触发系统回调，确保入口读取的是回调 drawable 的 presentedTime。
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) { block(self) }

    /// 测试不提交 GPU；保留协议要求的无参呈现入口。
    func present() {}

    /// 测试不调度屏幕时间；给定时间不产生真实呈现。
    func present(at presentationTime: CFTimeInterval) {}

    /// 测试不调度屏幕间隔；给定时长不产生真实呈现。
    func present(afterMinimumDuration duration: CFTimeInterval) {}
}
#endif
