import Foundation
import Observation
import pag_swift

/// 一份可见资源的宿主会话；内容、调度和 Metal 全部由唯一的库播放器承担。
@MainActor @Observable final class DemoSession {
    /// 此会话固定的播放器，切换 SwiftUI/原生宿主也不创建另一套播放状态。
    let player = PAGPlayer()
    /// 详情或批次的报告身份，批次内各资源复用同一 runID。
    let runID: UUID
    /// 当前实际资源，尚未开始载入为 nil。
    private(set) var resource: DemoResource?
    /// 当前真实源槽目录，不从图层位置或索引猜测。
    private(set) var slots: [PAGContentSlot] = []
    /// 载入和首次 drawable 等待期间为 true。
    private(set) var isLoading = false
    /// 成功安装且可操作当前合成。
    private(set) var isLoaded = false
    /// 实际库状态的可读名称，不代表人工画面通过。
    private(set) var status = "等待预览"
    /// 根进度的节流快照，范围 0...1。
    private(set) var progress = 0.0
    /// 文件逻辑尺寸、时长、帧率的摘要。
    private(set) var metadata = ""
    /// 实际根时长秒数，用于批播截止时间。
    private(set) var duration = 0.0
    /// 原文件根帧率，尚未解析时为 nil，用于调试逐帧定位。
    private(set) var frameRate: Double?
    /// 当前主加载/播放错误，没有错误为 nil。
    private(set) var errorMessage: String?
    /// 与当前文件对应的加载报告。
    private(set) var loadReport: PAGLoadReport?
    /// 每 250ms 更新一次的真实帧诊断，尚未安装为 nil。
    private(set) var diagnostics: PAGPlaybackDiagnostics?
    /// 控制状态与根位置的原始快照，不能用 GPU 完成位置冒充实际显示位置。
    private(set) var playback: PAGPlaybackSnapshot?
    /// 共享 PAG 解析缓存的当前占用；不同于当前文件载入结束时的历史快照。
    private(set) var cacheStatistics: PAGCacheStatistics?
    /// 当前进程的真实构建和系统信息，详情与导出使用相同来源。
    let environment = DemoEnvironment.current()
    /// 库最近的有限内容事件；异步单槽错误不会变成主播放失败。
    private(set) var contentEvents: [PAGContentEvent] = []
    /// 最后 128 条实际宿主操作。
    private(set) var actions: [DemoLogEntry] = []
    /// 成功导出的绝对 URL；失败时不更新为不存在的文件。
    private(set) var reportURL: URL?
    /// 单会话的串行交互任务，退出页面时必须取消并等待。
    @ObservationIgnored private var command: Task<Void, Never>?

    /// 预览/详情默认独立 runID；批播可显式注入共同身份。
    init(runID: UUID = UUID()) { self.runID = runID }

    /// 正常退出由 shutdown 排空；销毁时仍撤销尚未开始的用户命令。
    isolated deinit { command?.cancel() }

    /// 与视图 task 同生共死：载入和低频监控并行，取消后排空资源再返回。
    func run(_ resource: DemoResource, repeatCount: Int = 0) async {
        async let loading: Void = loadForDisplay(resource, repeatCount: repeatCount)
        await monitor()
        _ = await loading
        await shutdown()
    }

    /// 页面载入错误已由 load 固化到 UI；结构化子任务不重复吞掉未记录的失败。
    private func loadForDisplay(_ resource: DemoResource, repeatCount: Int) async {
        do { try await load(resource, repeatCount: repeatCount) }
        catch { /* 保留 load 中的错误与取消记录，父任务统一释放资源。 */ }
    }

    /// 加载真实 PAG 并等待首个 GPU 完成再自动播放；没有可见目标时超时明确报错。
    func load(_ resource: DemoResource, repeatCount: Int = 0,
              policy: PAGLoadPolicy = .useCache, autoplay: Bool = true) async throws {
        let started = Date()
        self.resource = resource
        isLoading = true
        isLoaded = false
        errorMessage = nil
        slots = []
        metadata = ""
        frameRate = nil
        loadReport = nil
        diagnostics = nil
        playback = nil
        contentEvents = []
        actions = []
        progress = 0
        reportURL = nil
        status = "载入中"
        append("load", detail: "\(resource.id) · \(policy) · repeat=\(repeatCount)")
        defer { isLoading = false }
        do {
            await player.cancelContentRequests()
            await player.pause()
            try await player.setComposition(nil)
            let result = try await PAGLoader.shared.loadWithReport(from: resource.url, policy: policy)
            loadReport = result.report
            try Task.checkCancellation()
            let composition = result.file.composition
            slots = result.file.contentSlots
            duration = Double(composition.duration.microseconds) / 1_000_000
            frameRate = composition.frameRate
            metadata = "\(Int(composition.size.width)) × \(Int(composition.size.height)) · " +
                String(format: "%.2fs · %.1f fps", duration, composition.frameRate)
            try await player.setComposition(composition)
            await player.setRepeatCount(repeatCount)
            // 业务默认不提供覆盖；库自行发现源槽并且每个槽只调用一次。
            try await player.setContentProvider { _ in .unchanged }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while await player.snapshot.presentedTime == nil {
                try Task.checkCancellation()
                if let failure = await player.snapshot.failure { throw failure }
                guard ContinuousClock.now < deadline else { throw PAGError.renderingFailure("demoFirstDrawableTimeout") }
                try await Task.sleep(for: .milliseconds(25))
            }
            if autoplay { try await player.play() }
            isLoaded = true
            append(autoplay ? "play" : "prepared", detail: "repeat=\(repeatCount)")
            await refresh()
        } catch is CancellationError {
            append("cancel", detail: "资源载入被页面生命周期撤销")
            throw CancellationError()
        } catch {
            errorMessage = String(describing: error)
            status = "失败"
            if loadReport == nil {
                loadReport = await PAGLoader.shared.recentReports.last {
                    $0.sourcePath == resource.url.path && $0.startedAt >= started
                }
            }
            append("error", detail: String(describing: error))
            throw error
        }
    }

    /// UI 汇总节流为每秒四次，库播放仍使用平台显示时钟，不在此推进时间。
    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
        }
    }

    /// 刷新真实库快照与有界事件，主错误优先保留，避免被 empty 覆盖失败原因。
    func refresh() async {
        let snapshot = await player.snapshot
        if playback?.state != snapshot.state {
            append("state", detail: String(describing: snapshot.state))
        }
        playback = snapshot
        cacheStatistics = await PAGLoader.shared.statistics
        if !isLoading { isLoaded = snapshot.duration != nil && snapshot.failure == nil }
        if errorMessage == nil { status = isLoading ? "载入中" : String(describing: snapshot.state) }
        if let failure = snapshot.failure { errorMessage = String(describing: failure); status = "失败" }
        if let duration = snapshot.duration, duration.microseconds > 0 {
            progress = min(1, max(0, Double(snapshot.position.microseconds) / Double(duration.microseconds)))
        }
        let current = await player.diagnostics
        // 清屏也有 GPU 完成；没有匹配的文件摘要时，不能把清屏报告成该候选渲染成功。
        diagnostics = current?.documentIdentity != nil && current?.documentIdentity == loadReport?.documentIdentity ? current : nil
        contentEvents = await player.contentEvents.filter { $0.documentIdentity == loadReport?.documentIdentity }
    }

    /// 视图取消后的清理不继承其取消状态；等待有限拥有任务退出后释放合成及显示预约。
    func shutdown() async {
        command?.cancel()
        await command?.value
        command = nil
        let player = player
        await Task {
            await player.cancelContentRequests()
            await player.pause()
            try? await player.setComposition(nil)
            await player.detachSurface()
        }.value
        isLoaded = false
    }

    /// 用户命令串行替换前一条；当前命令结束后才执行新命令，错误留在有限日志中。
    func perform(_ operation: String, tag: String? = nil, detail: String = "",
                 action: @escaping @MainActor (PAGPlayer) async throws -> Void) {
        append(operation, tag: tag, detail: detail)
        let previous = command
        previous?.cancel()
        command = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do { try await action(player); await refresh() }
            catch is CancellationError { /* 已由更新交互取代，不能当主错误显示。 */ }
            catch { append("operationFailed", tag: tag, detail: String(describing: error)) }
        }
    }

    /// 只保留可读参数，不向控制台或磁盘逐帧输出。
    func append(_ operation: String, tag: String? = nil, detail: String) {
        actions.append(DemoLogEntry(operation: operation, tag: tag, detail: detail))
        if actions.count > 128 { actions.removeFirst(actions.count - 128) }
    }

    /// 从真实库状态固化报告；默认人工画面仍为 pending，不能自动写 PASS。
    func report(endReason: String, error: String? = nil) async -> DemoResourceReport? {
        guard let resource else { return nil }
        await refresh()
        let snapshot = await player.snapshot
        return DemoResourceReport(runID: runID, resource: resource, environment: .current(),
            endReason: endReason, parsing: loadReport?.status.rawValue ?? "unavailable",
            rendering: (diagnostics?.gpuCompletedFrames ?? 0) > 0 ? "completed" : "unavailable",
            playback: snapshot.state == .finished ? "finished" : String(describing: snapshot.state),
            visual: "pending", load: loadReport, diagnostics: diagnostics,
            contentEvents: contentEvents, actions: actions, error: error ?? errorMessage)
    }

    /// 显式导出快照到可分享 JSON，显示实际文件路径，写入失败留操作错误。
    func export() {
        perform("export") { [weak self] _ in
            guard let self, let report = await report(endReason: "manualExport") else { return }
            reportURL = try await DemoReportStore.save(report, runID: runID, name: "detail")
        }
    }

    /// 从当前资源重新准备或播放；保留总轮数配置，明确区分缓存复用与强制重新解析。
    func reload(policy: PAGLoadPolicy = .useCache, autoplay: Bool = true) {
        guard let resource else { return }
        perform(autoplay ? "reload" : "prepare", detail: String(describing: policy)) { [weak self] player in
            let count = await player.snapshot.repeatCount
            try await self?.load(resource, repeatCount: count, policy: policy, autoplay: autoplay)
        }
    }

    /// 逐帧调试先暂停，再用文件帧率计算相邻根时刻；这不会定位独立 GIF/WebP 的进度。
    func stepFrame(_ direction: Int) {
        guard let frameRate else { return }
        perform("stepFrame", detail: String(direction)) { player in
            await player.pause()
            let current = await player.snapshot.position.microseconds
            let delta = Int64((1_000_000 / frameRate).rounded()) * Int64(direction)
            try await player.seek(to: PAGTime(microseconds: max(0, current + delta)))
        }
    }
}
