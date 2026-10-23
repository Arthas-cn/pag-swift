import SwiftUI
import pag_swift

/// 详情的真实调试面板：按文件、控制、准备、呈现和资源预算拆开，避免一行摘要掩盖失败阶段。
struct DemoDiagnosticsView: View {
    /// 只读每 250ms 更新的会话快照，不由界面访问逐帧对象。
    let session: DemoSession

    /// 元数据与计数可复制；日志过滤只影响显示，不删掉导出报告里的诊断。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("实时诊断").font(.title3.bold())
                Spacer()
                Button("导出 JSON", systemImage: "square.and.arrow.up") { session.export() }
            }
            GroupBox("文件与构建") { identity }
            GroupBox("播放状态") { playback }
            GroupBox("载入与解析缓存") { loading }
            if let value = session.diagnostics {
                GroupBox("准备与首帧耗时") { timings(value) }
                GroupBox("提交与实际呈现") { presentation(value) }
                GroupBox("资源与动态内容") { resources(value) }
            }
            DemoDiagnosticConsole(actions: session.actions, content: session.contentEvents,
                                  frames: session.diagnostics?.events ?? [])
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let url = session.reportURL {
                ShareLink("分享报告", item: url)
                Text(url.path).font(.caption2)
            }
            Text("系统呈现表示 drawable 已显示；画面内容是否正确需要另行核对。预算计费不等于进程内存，未观测值显示为不可用。")
                .foregroundStyle(.secondary)
        }
        .font(.caption).monospacedDigit().textSelection(.enabled)
        .accessibilityIdentifier("detail.diagnostics")
    }

    /// 来源、内容摘要和构建身份共同决定复现条件，不能只显示一个文件名。
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("资源", session.resource?.id ?? "未选择")
            row("完整路径", session.resource?.url.path ?? "不可用")
            row("文件大小", bytes(session.resource?.byteCount))
            row("文档 SHA-256", session.loadReport?.documentIdentity ?? "尚未解析")
            row("runID", session.runID.uuidString)
            row("播放器", session.diagnostics?.playerID.uuidString ?? "尚未准备")
            row("安装会话", session.diagnostics?.sessionID.uuidString ?? "尚未准备")
            row("设备 / 系统", "\(session.environment.device) · \(session.environment.system)")
            row("构建", "\(session.environment.build) · \(session.environment.configuration)")
            row("构建 ID", session.environment.artifact?["buildID"] ?? "未随包提供")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 接受位置、GPU 完成位置和系统呈现各自独立，暂停时仍可检查最后一个已提交位置。
    private var playback: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("状态", session.status)
            row("文件信息", session.metadata)
            if let value = session.playback {
                row("根请求位置", time(value.position))
                row("最近有效 GPU 完成位置", value.presentedTime.map(time) ?? "尚未提交")
                row("总时长", value.duration.map(time) ?? "未安装")
                row("已完成轮数 / 总次数", "\(value.completedIterations) / \(value.repeatCount <= 0 ? "无限" : String(value.repeatCount))")
                row("合成版本", String(value.revision))
                row("主播放错误", value.failure.map { String(describing: $0) } ?? "无")
            }
            row("真实槽位", "\(session.slots.count) · 文字 \(session.slots.filter { $0.kind == .text }.count) · 图像 \(session.slots.filter { $0.kind == .image }.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 当前文件的历史加载阶段与共享 loader 的实时累计占用分开展示。
    private var loading: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let report = session.loadReport {
                row("加载策略 / 结果", "\(report.policy) · \(report.status.rawValue) · \(report.cache.rawValue)")
                row("读取 / 摘要", "\(milliseconds(report.readSeconds)) / \(milliseconds(report.digestSeconds))")
                row("解析 / 共享等待", "\(milliseconds(report.parseSeconds)) / \(milliseconds(report.sharedWaitSeconds))")
                row("本次加载总耗时", milliseconds(report.totalSeconds))
                if let error = report.error { row("加载错误", error) }
            }
            if let cache = session.cacheStatistics {
                row("缓存命中 / 未命中 / 共享", "\(cache.hits) / \(cache.misses) / \(cache.sharedRequests)")
                row("实际解析 / 在途", "\(cache.parses) / \(cache.inFlightParses)")
                row("淘汰 / 失效 / 丢弃旧结果", "\(cache.evictions) / \(cache.invalidations) / \(cache.discardedResults)")
                row("解析缓存留存", "\(cache.cachedFiles) 份 · \(bytes(cache.cachedBytes)) / \(bytes(cache.byteLimit))")
                row("失败 / 取消", "\(cache.failures) / \(cache.cancellations)")
            }
            Text("缓存命中仍包含读取与摘要；共享等待可能与解析重叠，不能直接相加。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 首帧阶段以安装会话起点计时，显示最近和最坏帧准备成本以定位突刺。
    private func timings(_ value: PAGPlaybackDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("场景准备", milliseconds(value.preparationSeconds))
            row("首次提交 / GPU 完成", "\(milliseconds(value.firstSubmitSeconds)) / \(milliseconds(value.firstGPUCompletionSeconds))")
            row("首次有效系统呈现", milliseconds(value.firstPresentationSeconds))
            row("帧准备 · 最近 / 最大", "\(milliseconds(value.framePreparationSeconds)) / \(milliseconds(value.maximumFramePreparationSeconds))")
            row("GPU 时间累计", milliseconds(value.totalGPUSeconds))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 不把请求合并、GPU 完成、系统丢弃混算成一个未经测量的丢帧率。
    private func presentation(_ value: PAGPlaybackDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("命令提交 / GPU 完成", "\(value.submittedFrames) / \(value.gpuCompletedFrames)")
            row("系统实际呈现", value.presentedFrames.map(String.init) ?? "未观测")
            row("过期呈现 / 零时间跳过", "\(value.stalePresentedFrames) / \(value.skippedPresentations)")
            row("请求合并 / 过期结果", "\(value.coalescedRequests) / \(value.discardedRequests)")
            row("drawable 获取失败", String(value.drawableFailures))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// CPU 帧、GPU 输入和局部附件分列；单槽失败和当前活动跑马灯可直接查看。
    private func resources(_ value: PAGPlaybackDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("当前帧 RGBA 输入", bytes(value.frameImageBytes))
            row("GPU 输入 LRU / 上限", "\(bytes(value.retainedInputBytes)) / \(bytes(value.inputByteLimit))")
            row("局部效果 / Picture 纹理", "\(bytes(value.groupTextureBytes)) / \(bytes(value.pictureTextureBytes))")
            row("动图当前帧 / 工作预算", "\(bytes(value.animatedFrameBytes)) / \(bytes(value.animatedFrameByteLimit))")
            row("动图在途预留", bytes(value.animatedDecodingBytes))
            row("动图解码 / 排队", "\(value.animatedDecodingFrames.map(String.init) ?? "不适用") / \(value.animatedPendingFrames.map(String.init) ?? "不适用")")
            row("宿主帧变化 / 失败", "\(value.hostFrameChanges) / \(value.hostFrameFailures.map(String.init) ?? "不适用")")
            row("活动跑马灯实例", String(value.activeMarqueeInstances))
            if let failure = value.lastHostFrameFailure { row("最近宿主帧错误", failure) }
            let failed = session.contentEvents.filter { [.failed, .timedOut, .cancelled, .discarded].contains($0.status) }
            row("当前有限内容记录", "\(session.contentEvents.count) 条 · 失败/超时/取消/丢弃 \(failed.count) 条")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 使用可换行值避免长摘要或路径挤压标签；复制时保留完整内容。
    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
    }

    /// 微秒和秒一起显示，便于复现边界而不丢掉整数精度。
    private func time(_ value: PAGTime) -> String {
        String(format: "%.6f s", Double(value.microseconds) / 1_000_000) + " · \(value.microseconds) μs"
    }

    /// nil 明确表示未执行或未观测，不能格式化为零耗时。
    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f ms", $0 * 1000) } ?? "不可用"
    }

    /// 所有字节值沿用库的保守计费口径，不包装成进程 RSS。
    private func bytes(_ value: Int?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "不可用"
    }
}

/// 可筛选的有限事件控制台；默认保留重要阶段，高频提交事件由用户显式展开。
private struct DemoDiagnosticConsole: View {
    /// 宿主操作，最多 128 条。
    let actions: [DemoLogEntry]
    /// provider 生命周期，最多 256 条。
    let content: [PAGContentEvent]
    /// 库内帧阶段，最多 128 条。
    let frames: [PAGPlaybackDiagnosticEvent]
    /// 标签、阶段、版本或错误关键字均可过滤。
    @State private var query = ""
    /// 默认隐藏正常的逐帧提交/GPU/呈现，避免刷屏掩盖操作与错误。
    @State private var includesFrames = false
    /// 用户可冻结当前可见日志用于阅读，后台记录与报告继续更新。
    @State private var isFrozen = false
    /// 冻结瞬间的文本快照，解冻后重新读取实际有界输入。
    @State private var frozenLines: [String] = []

    /// 日志显示固定高度并可复制，过滤不修改真实日志。
    var body: some View {
        GroupBox("事件控制台") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("筛选 tag、阶段、版本或错误", text: $query)
                HStack {
                    Toggle("逐帧事件", isOn: $includesFrames)
                    Spacer()
                    Button(isFrozen ? "继续更新" : "冻结显示") {
                        if !isFrozen { frozenLines = lines }
                        isFrozen.toggle()
                    }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text((isFrozen ? frozenLines : lines).filter {
                        query.isEmpty || $0.localizedCaseInsensitiveContains(query)
                    }.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(height: 240)
                .accessibilityIdentifier("detail.console")
            }
        }
    }

    /// 各来源使用自己的明确时间基准，不把墙钟、请求耗时和会话经过时间混排成伪时间线。
    private var lines: [String] {
        let host = actions.suffix(40).map {
            "[\($0.date.formatted(date: .omitted, time: .standard))] ACTION \($0.operation) \($0.tag ?? "") \($0.detail)"
        }
        let requests = content.suffix(64).map {
            "[请求 +\(String(format: "%.3f", $0.elapsedSeconds))s] \($0.status.rawValue) tag=\($0.tag) type=\($0.contentType ?? "待返回") version=\($0.contentVersion) \($0.detail ?? "")"
        }
        let stages = frames.filter {
            includesFrames || ![.submitted, .gpuCompleted, .presented].contains($0.stage)
        }.suffix(64).map {
            "[会话 +\(String(format: "%.3f", $0.elapsedSeconds))s] \($0.stage.rawValue) root=\($0.timeMicroseconds.map(String.init) ?? "—")μs accepted=\($0.accepted.map(String.init) ?? "—") request=\($0.requestID?.uuidString ?? "—")"
        }
        return host + requests + stages
    }
}
