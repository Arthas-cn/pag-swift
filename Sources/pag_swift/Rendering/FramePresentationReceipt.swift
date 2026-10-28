import Foundation
import Metal

/// 系统呈现回调所需的小值及同步时钟；不持有播放器、PreparedScene 或 GPU 批次。
struct FramePresentationReceipt: Sendable {
    /// 先离开 Core Animation 的内部锁，再按顺序核验播放许可；队列中只保留小值，不保留 drawable。
    private static let callbacks = DispatchQueue(label: "pag.presentation", qos: .userInteractive)
    /// 完整控制代数，用于拒绝 seek/暂停/换内容后的迟到呈现。
    let token: PlaybackRequestToken
    /// 与播放器控制共用的短锁许可。
    let gate: PlaybackSubmissionGate
    /// 实际显示目标的当前代数和可见性。
    let mailbox: DisplayTargetMailbox
    /// 当前占位素材实例的同步时钟；没有占位为 nil。
    let placeholderClock: PresentationActivationClock?
    /// 当前滚动文字实例的同步时钟；没有跑马灯为 nil。
    let marqueeClock: PresentationActivationClock?
    /// 本帧实际显示的占位实例，空集合也必须冻结旧实例。
    let placeholderIDs: [PAGLayerID]
    /// 本帧实际显示的滚动实例，空集合也必须冻结旧实例。
    let marqueeIDs: [PAGLayerID]
    /// 会话诊断记录，不反向持有控制器。
    let diagnostics: PlaybackDiagnosticSession?
    /// 本帧根时间，用于报告复现参数。
    let time: PAGTime
    /// 采样时播放器累计活动时间，暂停内容不继续增加。
    let auxiliaryTime: PAGTime
    /// 是否应将采样到实际呈现的间隔计入活动时间。
    let isPlaying: Bool
    /// 系统 host time 的请求采样点，与 presentedTime 同原点。
    let sampledHostTime: Double

    /// 只复制回调需要的身份和独立同步状态，避免 drawable 持有整个场景图。
    init(request: PlaybackFrameRequest, mailbox: DisplayTargetMailbox,
         placeholderIDs: [PAGLayerID], marqueeIDs: [PAGLayerID]) {
        token = request.token
        gate = request.gate
        self.mailbox = mailbox
        placeholderClock = request.scene?.placeholderClock
        marqueeClock = request.scene?.marqueeClock
        self.placeholderIDs = placeholderIDs
        self.marqueeIDs = marqueeIDs
        diagnostics = request.diagnostics
        time = request.time
        auxiliaryTime = request.auxiliaryTime
        isPlaying = request.isPlaying
        sampledHostTime = request.sampledHostTime
    }

    /// 系统回调只异步交付标量，不能同步取提交门；Metal Capture 的 present 可能正在等待该回调退出。
    func presented(at hostTime: Double) {
        Self.callbacks.async { applyPresentation(at: hostTime) }
    }

    /// 离开系统回调后核验当前代数；正呈现时间才可启动时钟，零值不能以 GPU 完成代替。
    private func applyPresentation(at hostTime: Double) {
        guard hostTime.isFinite, hostTime > 0 else {
            diagnostics?.record(.presentationSkipped, token: token, time: time)
            return
        }
        let delay = isPlaying ? max(0, hostTime - sampledHostTime) : 0
        let micros = Double(auxiliaryTime.microseconds) + delay * 1_000_000
        let activeTime = PAGTime(microseconds: Int64(min(micros, Double(Int64.max - 2048))))
        // 与提交一致的锁序：播放许可 → 显示代数 → 单实例时钟，不能反向进入 player actor。
        let accepted = gate.withPresentationPermission(for: token) {
            mailbox.withCompletedEpochPermission(for: token.targetEpoch) {
                placeholderClock?.activate(placeholderIDs, at: activeTime)
                marqueeClock?.activate(marqueeIDs, at: activeTime)
                return true
            } == true
        } == true
        diagnostics?.record(.presented, token: token, time: time, seconds: hostTime, accepted: accepted)
    }
}

/// 在 command buffer `present` 之前登记屏幕呈现回调。
/// 真机和 macOS 使用系统 API；模拟器缺少公开的呈现通知，故不登记，也不激活依赖实际呈现的附加时钟。
func registerDrawablePresentation(_ drawable: any MTLDrawable, receipt: FramePresentationReceipt) {
    #if targetEnvironment(simulator)
    // Simulator SDK 的 MTLDrawable.h 未声明这两个 API，当前运行时也不响应对应选择子。
    // 不绕过 SDK 调用隐藏实现；没有实际呈现证据时保留诊断 nil，不能用 GPU 完成时间冒充。
    return
    #else
    drawable.addPresentedHandler { displayed in
        // Core Animation 可能仍持有 drawable 内部锁；只读标量并异步交付，不能同步取播放门。
        receipt.presented(at: displayed.presentedTime)
    }
    #endif
}
