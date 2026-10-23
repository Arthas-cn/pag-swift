import AppKit
import Foundation
import pag_swift

/// 用 Demo 的真实批播模型验证失败继续和取消；挂载小 drawable，不启动另一个 Demo App。
@main struct DemoBatchProbe {
    /// 失败返回非零，成功保存独立逻辑验收报告；不把此探针作为人工画面证据。
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // 真实 PAGNSView 依赖 AppKit 的可见性通知和显示 link；普通命令行 async main 不能冒充 App runloop。
        Task {
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Demo batch probe failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    /// 顺序运行失败继续与中途取消，两个场景复用一个临时宿主窗口。
    @MainActor private static func run() async throws {
        _ = NSApplication.shared
        let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let output = URL(filePath: CommandLine.arguments[2])
        let temporary = FileManager.default.temporaryDirectory.appending(path: "pag-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let broken = temporary.appending(path: "broken.pag")
        try Data("invalid PAG candidate".utf8).write(to: broken)
        let bad = DemoResource(id: "broken.pag", url: broken, byteCount: nil)
        let good = DemoResource(id: "0.pag", url: root.appending(path: "0.pag"), byteCount: nil)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 180, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · batch lifecycle evidence"
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let continued = DemoBatchSession()
        mount(continued, in: window)
        await continued.run([bad, good])
        try require(continued.results.count == 2 && continued.failed == 1 && continued.completed == 1,
                    "损坏候选没有失败继续到下一份完整播放；\(windowState(window))；summary=\(continued.reportURL?.path ?? "unavailable")")
        try require(continued.results[0].parsing == "failed" && continued.results[0].rendering == "unavailable",
                    "损坏候选被清屏 GPU 错记成渲染成功")
        try require(continued.results[1].playback == "finished" && continued.results[1].diagnostics?.presentedFrames != nil,
                    "正常候选没有完整结束及系统呈现证据")
        // 命令行 Swift Testing 的单次提交不能要求 WindowServer 必须呈现；系统允许跳过 drawable。
        // 在真正 AppKit runloop 和生产宿主的完整播放中验证三个阶段，不能只把 GPU 完成记作呈现。
        guard let presented = continued.results[1].diagnostics else {
            throw BatchProbeFailure(message: "正常候选缺少诊断")
        }
        try require(presented.submittedFrames > 0 && presented.gpuCompletedFrames > 0 &&
            (presented.presentedFrames ?? 0) > 0 && presented.firstPresentationSeconds != nil &&
            presented.events.contains { $0.stage == .presented && $0.accepted == true && ($0.seconds ?? 0) > 0 },
            "提交、GPU 完成和正系统呈现时间没有各自独立证据")
        try require(continued.reportURL != nil && continued.reportError == nil, "完整汇总没有实际保存")

        let cancelled = DemoBatchSession()
        mount(cancelled, in: window)
        let task = Task { await cancelled.run([good, good, good]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while cancelled.results.isEmpty {
            guard ContinuousClock.now < deadline else {
                task.cancel()
                await task.value
                throw BatchProbeFailure(message: "首份完整播放超时")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        cancelled.cancel()
        await task.value
        try require(cancelled.cancelled && !cancelled.isRunning && cancelled.completed == 1,
                    "取消未结束批次或继续完整播放后续资源")
        try require(cancelled.results.count < 3 && cancelled.reportURL != nil && cancelled.reportError == nil,
                    "取消没有保留部分报告或仍运行完整目录")
        try require(await cancelled.session.player.snapshot.state == .empty, "取消后播放器仍持有合成")
        let report = BatchProbeReport(failureThenSuccess: continued.reportURL!.path,
            cancelled: cancelled.reportURL!.path,
            checks: ["damaged candidate failed", "clear frame not reported as success", "next candidate fully played",
                     "actual presentation callback", "submission GPU and positive presentation distinguished",
                     "cancel stops remainder", "partial summary saved", "composition released"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        print("Batch lifecycle checks passed: \(report.checks.count); \(output.path)")
    }

    /// 把当前批次唯一播放器交给正式 AppKit 宿主，不在探针里替代帧调度。
    @MainActor private static func mount(_ batch: DemoBatchSession, in window: NSWindow) {
        let view = PAGNSView(player: batch.session.player)
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
        window.contentView = view
        window.orderFront(nil)
        window.displayIfNeeded()
        print("Mounted probe host: \(windowState(window))")
    }

    /// 只读取本探针持有窗口的显示前提，失败时区分隐藏/遮挡与播放核心错误，不检查其它应用。
    @MainActor private static func windowState(_ window: NSWindow) -> String {
        "visible=\(window.isVisible), occlusionVisible=\(window.occlusionState.contains(.visible)), " +
        "miniaturized=\(window.isMiniaturized), appHidden=\(NSApplication.shared.isHidden), " +
        "hasScreen=\(window.screen != nil)"
    }

    /// 每项断言失败明确终止，不过滤失败后继续输出成功摘要。
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BatchProbeFailure(message: message) }
    }
}

/// 指向实际批播报告的索引，仍保持人工画面状态独立。
nonisolated private struct BatchProbeReport: Codable {
    /// 损坏文件后继续正常文件的完整汇总位置。
    let failureThenSuccess: String
    /// 中途取消后保存的部分汇总位置。
    let cancelled: String
    /// 确实通过的生命周期与报告不变量。
    let checks: [String]
}

/// 探针不变量错误的简短定位信息。
nonisolated private struct BatchProbeFailure: Error {
    /// 未满足的行为约定。
    let message: String
}
