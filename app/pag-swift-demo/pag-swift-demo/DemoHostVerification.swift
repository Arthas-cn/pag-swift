import Foundation
import pag_swift

/// Xcode运行时的有限宿主验收流程；只使用公开控制API与真实视图，不承担播放实现。
@MainActor struct DemoHostVerification {
    /// SwiftUI面板固定持有的播放器。
    let swiftUIPlayer: PAGPlayer
    /// UIKit/AppKit面板固定持有的播放器。
    let nativePlayer: PAGPlayer
    /// 改变SwiftUI树中的实际挂载状态，结束旧View并建立新View。
    let setMounted: @MainActor (Bool) -> Void
    /// 改变原生宿主的祖先hidden，不能用业务pause模拟。
    let setNativeHidden: @MainActor (Bool) -> Void
    /// 调整两个真实宿主的点高度；零表示不可呈现，恢复后继续原播放器。
    let setHeight: @MainActor (Double) -> Void

    /// 仅显式传入启动参数时执行自动验收，普通演示启动不操作用户界面。
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--verify-pag-hosts") }

    /// 逐项等待真实快照；失败保留原因并暂停两个播放器，不伪报通过。
    func run() async -> String {
        do {
            for player in players { _ = try await wait(player, "首帧") { $0.presentedTime != nil } }
            report("两个宿主首帧")
            try await playBoth()
            report("系统刷新自动推进")
            setNativeHidden(true)
            _ = try await wait(nativePlayer, "祖先隐藏") { $0.state == .suspended }
            guard await swiftUIPlayer.snapshot.state == .playing else { throw VerificationFailure("隐藏原生宿主影响了SwiftUI") }
            report("祖先隐藏暂停原生呈现")
            for player in players { await player.pause() }
            setNativeHidden(false)
            _ = try await align(to: PAGTime(microseconds: 1_000_000))
            for player in players {
                guard await player.snapshot.state == .paused else { throw VerificationFailure("恢复显示覆盖主动暂停") }
            }
            report("恢复显示保留主动暂停，同帧定位")
            try await playBoth()
            setHeight(0)
            for player in players { _ = try await wait(player, "零布局") { $0.state == .suspended } }
            setHeight(100)
            for player in players { _ = try await wait(player, "布局恢复") { $0.state == .playing } }
            report("零布局及正尺寸恢复")
            setMounted(false)
            for player in players { _ = try await wait(player, "离窗") { $0.state == .suspended } }
            setMounted(true)
            for player in players { _ = try await wait(player, "重挂") { $0.state == .playing } }
            report("移除及重挂保留播放意图")
            for player in players {
                await player.pause()
                await player.setScaleMode(.aspectFit)
            }
            let represented = try await align(to: PAGTime(microseconds: 2_000_000))
            report("最终两个宿主均暂停在\(represented.microseconds)μs")
            return "宿主验收通过（7项）"
        } catch {
            for player in players { await player.pause() }
            let message = "宿主验收失败：\(error)"
            print("[PAG Host Verification] \(message)")
            return message
        }
    }

    /// 两个已有播放器，不在验收中重新创建播放核心。
    private var players: [PAGPlayer] { [swiftUIPlayer, nativePlayer] }

    /// 验证实际刷新能从请求位置推进，而非只进入名为playing的状态。
    private func playBoth() async throws {
        for player in players {
            let previous = await player.snapshot.presentedTime ?? .zero
            try await player.play()
            _ = try await wait(player, "自动推进") { snapshot in
                snapshot.state == .playing && snapshot.presentedTime.map { $0 > previous } == true
            }
        }
    }

    /// 在实际时长内定位并比较公开提交结果；源帧量化仍由库完成，不在demo重写时间轴。
    private func align(to preferred: PAGTime) async throws -> PAGTime {
        guard let duration = await swiftUIPlayer.snapshot.duration else { throw VerificationFailure("缺少素材时长") }
        // 短动画不能沿用srgb的1秒/2秒固定期望；取中点留出有效帧，避免请求末端再误等原时间。
        let time = preferred < duration ? preferred : PAGTime(microseconds: duration.microseconds / 2)
        var represented: PAGTime?
        for player in players {
            try await player.seek(to: time)
            guard case .submitted(let actual, _) = try await player.render(at: time) else {
                throw VerificationFailure("定位时显示目标不可用")
            }
            if let represented, represented != actual { throw VerificationFailure("两个宿主的量化帧不一致") }
            represented = actual
            _ = try await wait(player, "同帧定位") { $0.position == time && $0.presentedTime == actual }
        }
        guard let represented else { throw VerificationFailure("没有宿主完成定位") }
        return represented
    }

    /// 以快照事件完成等待；15秒仅是失败上限，不用sleep制造预期的布局或播放时序。
    private func wait(_ player: PAGPlayer, _ label: String,
                      matching predicate: @escaping @Sendable (PAGPlaybackSnapshot) -> Bool) async throws -> PAGPlaybackSnapshot {
        try await withThrowingTaskGroup(of: PAGPlaybackSnapshot.self) { group in
            group.addTask {
                for await snapshot in await player.snapshots() {
                    try Task.checkCancellation()
                    if let failure = snapshot.failure { throw failure }
                    if predicate(snapshot) { return snapshot }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw VerificationFailure("\(label)超时")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Xcode控制台按验收事件记录一次，不逐帧刷日志。
    private func report(_ value: String) { print("[PAG Host Verification] PASS \(value)") }
}

/// 仅属于demo验收的失败，不混入库公开错误模型。
private struct VerificationFailure: Error, Sendable, CustomStringConvertible {
    /// 未达到的验收条件或超时阶段。
    let description: String

    /// 保存明确的验收失败原因。
    init(_ description: String) { self.description = description }
}
