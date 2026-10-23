import SwiftUI
import Observation
import pag_swift

/// 完整批次报告；未运行的候选可由 plannedPaths 与 results 明确区分，不偷换成成功。
nonisolated struct DemoBatchReport: Sendable, Codable {
    /// 此次整目录验收身份，与逐资源 JSON 相同。
    let runID: UUID
    /// 固定 fullIteration，避免把首帧冒烟误叫完整播放。
    let mode: String
    /// 原始稳定目录顺序，取消后尚未运行的文件仍保留在这里。
    let plannedPaths: [String]
    /// 实际已尝试资源的完整结果。
    let results: [DemoResourceReport]
    /// 明确记录用户或页面生命周期取消。
    let cancelled: Bool
    /// 完成一轮且有 GPU 完成证据的数量，不等于人工画面通过数量。
    let completedIterations: Int
    /// 加载、渲染或完整播放超时失败数量。
    let failures: Int
}

/// 批次只有一个显示播放器；逐份失败继续，取消立即撤销当前拥有任务。
@MainActor @Observable final class DemoBatchSession {
    /// 整次批播身份，用于目录名和报告关联。
    let runID = UUID()
    /// 唯一播放器的宿主会话，不为全目录预创建播放器。
    let session: DemoSession
    /// 当前相对路径，尚未开始为等待文本。
    private(set) var currentPath = "等待开始"
    /// 当前资源序号，从零开始用于进度。
    private(set) var index = 0
    /// 此次目录总数，启动时固定。
    private(set) var total = 0
    /// 已完成完整一轮的资源数量。
    private(set) var completed = 0
    /// 已明确失败的数量。
    private(set) var failed = 0
    /// 已尝试的逐文件报告，按目录顺序排列。
    private(set) var results: [DemoResourceReport] = []
    /// 整轮任务尚在运行，包括当前文件保存阶段。
    private(set) var isRunning = false
    /// 用户或页面生命周期取消后为 true。
    private(set) var cancelled = false
    /// 已实际保存的汇总路径；未保存或保存失败为 nil。
    private(set) var reportURL: URL?
    /// 报告写入失败与播放失败分开展示。
    private(set) var reportError: String?
    /// 批播工作的唯一句柄，按钮和父任务取消都传到同一任务。
    @ObservationIgnored private var operation: Task<Void, Never>?

    /// 把共同 runID 注入单资源会话。
    init() { session = DemoSession(runID: runID) }

    /// 正常退出仍等待 run 收尾；销毁时额外取消未完成工作。
    isolated deinit { operation?.cancel() }

    /// 视图 task 持有整次运行；取消不丢弃已产生的逐文件报告。
    func run(_ resources: [DemoResource]) async {
        guard operation == nil else { return }
        let task = Task { await execute(resources) }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// 停止当前解析、等待和播放，run 仍负责导出已完成部分并清理。
    func cancel() { operation?.cancel() }

    /// 每份完整一轮；超时上限为两倍源时长加十秒且至少二十秒，失败继续下一份。
    private func execute(_ resources: [DemoResource]) async {
        total = resources.count
        isRunning = true
        for (index, resource) in resources.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            self.index = index
            currentPath = resource.id
            var reason = "finishedIteration"
            var failure: String?
            do {
                try await session.load(resource, repeatCount: 1)
                let deadline = ContinuousClock.now.advanced(by: .seconds(max(20, session.duration * 2 + 10)))
                while true {
                    try Task.checkCancellation()
                    let snapshot = await session.player.snapshot
                    if let error = snapshot.failure { throw error }
                    if snapshot.state == .finished { break }
                    guard ContinuousClock.now < deadline else { throw PAGError.renderingFailure("batchFullIterationTimeout") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                // 系统实际呈现可能晚于末帧 GPU 回调；有限等待只用于收集证据，不伪造画面状态。
                let presentationDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
                while await session.player.diagnostics?.presentedFrames == nil, ContinuousClock.now < presentationDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                completed += 1
            } catch is CancellationError {
                cancelled = true
                reason = "cancelled"
            } catch {
                failed += 1
                reason = "failed"
                failure = String(describing: error)
                session.append("batchFailure", detail: failure ?? "")
            }
            if let report = await session.report(endReason: reason, error: failure) {
                results.append(report)
                do { _ = try await DemoReportStore.save(report, runID: runID, name: String(format: "%04d", index)) }
                catch { reportError = String(describing: error) }
            }
            await session.player.cancelContentRequests()
            await session.player.pause()
            if cancelled { break }
        }
        let summary = DemoBatchReport(runID: runID, mode: "fullIteration", plannedPaths: resources.map(\.id),
            results: results, cancelled: cancelled, completedIterations: completed, failures: failed)
        do { reportURL = try await DemoReportStore.save(summary, runID: runID, name: "summary") }
        catch { reportError = String(describing: error) }
        await session.shutdown()
        isRunning = false
    }
}

/// 一键完整播放所有候选，失败和取消都保留可导出结果。
struct DemoBatchView: View {
    /// 启动时冻结的目录稳定顺序，不受随后首页搜索影响。
    let resources: [DemoResource]
    /// 此页面拥有的一次批播。
    @State private var batch = DemoBatchSession()

    /// 真实播放器、整批进度及每份状态同时可见，人工画面不自动打勾。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(batch.cancelled ? "已取消" : (batch.isRunning ? "完整播放一轮" : "批次已结束")).font(.title2.bold())
            Text(batch.currentPath).font(.headline).textSelection(.enabled)
            PAGView(player: batch.session.player).frame(height: 260).background(.gray.opacity(0.12))
            ProgressView(value: Double(batch.results.count), total: Double(max(1, batch.total)))
            HStack {
                Text("\(batch.results.count)/\(batch.total) · 完整播放 \(batch.completed) · 失败 \(batch.failed)")
                Spacer()
                Button("取消") { batch.cancel() }.disabled(!batch.isRunning)
            }
            .monospacedDigit()
            Text("逐份等待自然结束；单份失败或超时继续。画面状态仍需单独核对。")
                .font(.caption).foregroundStyle(.secondary)
            if let url = batch.reportURL {
                ShareLink("导出完整汇总 JSON", item: url)
                Text(url.path).font(.caption2).textSelection(.enabled)
            }
            if let error = batch.reportError { Text("报告写入失败：\(error)").foregroundStyle(.red) }
            List(batch.results, id: \.resource.id) { result in
                VStack(alignment: .leading) {
                    Text(result.resource.id).font(.caption.bold())
                    Text("解析 \(result.parsing) · GPU \(result.rendering) · 播放 \(result.playback) · 画面 \(result.visual)")
                    if let error = result.error { Text(error).foregroundStyle(.red) }
                }
                .font(.caption2).textSelection(.enabled)
            }
        }
        .padding().navigationTitle("顺序播放全部")
        .task { await batch.run(resources) }
        .task { await batch.session.monitor() }
    }
}
