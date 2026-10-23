import Foundation
import Observation

/// 首页目录和三份可见预览的拥有者；停止旧预览后才释放名额给下一行。
@MainActor @Observable final class DemoCatalogModel {
    /// 递归扫描的全部候选，包含当前无法解析的文件。
    private(set) var resources: [DemoResource] = []
    /// 搜索后的稳定顺序，过滤只影响列表，不改变播放全部的集合。
    private(set) var filtered: [DemoResource] = []
    /// 列表直接观察每个活动会话，最多三个。
    private(set) var previews: [String: DemoSession] = [:]
    /// 离屏后仍保留一行最终摘要，不保留其播放器或纹理。
    private(set) var summaries: [String: String] = [:]
    /// 明确扫描失败，不能以空列表掩盖错误。
    private(set) var error: String?
    /// 当前后台扫描状态。
    private(set) var isScanning = false
    /// 实际曾同时分配的预览数，可供验收日志核对。
    private(set) var peakPreviewCount = 0
    /// 当前搜索文本，不参与资源身份。
    private var query = ""
    /// SwiftUI 实际滚动可见性回调维护的行集合。
    private var visible: Set<String> = []
    /// 导航或应用不活跃时禁用全部预览。
    private var isEnabled = true
    /// 每个活动预览的生命周期任务，任务结束包含播放器清理。
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// 单一协调任务，新的可见性只更新目标，不叠加多个释放/创建流程。
    @ObservationIgnored private var reconciliation: Task<Void, Never>?

    /// 取消尚有的生命周期工作；正常页面退出仍通过 stopAndWait 等待清理。
    isolated deinit {
        reconciliation?.cancel()
        for task in tasks.values { task.cancel() }
    }

    /// 重新扫描真实目录并清理已移除资源；不默认打开任一详情页。
    func refresh(root: URL? = DemoResourceCatalog.root) async {
        guard !isScanning else { return }
        isScanning = true
        error = nil
        defer { isScanning = false }
        do {
            guard let root else { throw CocoaError(.fileReadNoSuchFile) }
            resources = try await DemoResourceCatalog.scan(root: root)
            filter(query)
        } catch is CancellationError {
            // 窗口任务已结束，保留已有目录，不能将取消报作资源损坏。
        } catch { self.error = String(describing: error) }
    }

    /// 每次搜索只计算一次过滤结果；已经不在结果中的行立即退出可见集合。
    func filter(_ query: String) {
        self.query = query
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = value.isEmpty ? resources : resources.filter { $0.id.localizedCaseInsensitiveContains(value) }
        visible.formIntersection(Set(filtered.map(\.id)))
        schedule()
    }

    /// 由真实滚动可见性驱动，onAppear 的预加载行为不能直接分配播放器。
    func setVisible(_ id: String, _ value: Bool) {
        if value, filtered.contains(where: { $0.id == id }) { visible.insert(id) }
        else { visible.remove(id) }
        schedule()
    }

    /// 进入详情/批播或后台即关闭首页预览；返回后按仍可见的行重新申请名额。
    func setEnabled(_ value: Bool) {
        isEnabled = value
        schedule()
    }

    /// 为导航交接等待旧预览彻底释放，防止详情与离场行同时占用媒体资源。
    func stopAndWait() async {
        setEnabled(false)
        await reconciliation?.value
    }

    /// 稳定选择最多三行；其余可见行明确显示等待名额。
    private var desired: Set<String> { isEnabled ? Set(visible.sorted().prefix(3)) : [] }

    /// 至多存在一个协调任务；其 await 期间可见集合改变后，下一轮读取最新目标。
    private func schedule() {
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in await self?.reconcile() }
    }

    /// 顺序释放、再分配；不会为全部目录一次创建播放器，也不会忽略不合作的旧任务占用。
    private func reconcile() async {
        defer { reconciliation = nil }
        while !Task.isCancelled {
            let obsolete = Set(previews.keys).subtracting(desired)
            for id in obsolete {
                summaries[id] = previews[id]?.errorMessage ?? previews[id]?.metadata ?? ""
                previews[id] = nil
                tasks[id]?.cancel()
            }
            for id in obsolete {
                await tasks[id]?.value
                tasks[id] = nil
            }
            // 停止可能跨越 await；此处重新读取 desired，不能启动已经滚出屏幕的旧选择。
            for id in desired.subtracting(Set(previews.keys)).sorted() {
                guard let resource = resources.first(where: { $0.id == id }) else { continue }
                let session = DemoSession()
                previews[id] = session
                peakPreviewCount = max(peakPreviewCount, previews.count)
                tasks[id] = Task { await session.run(resource) }
            }
            if Set(previews.keys) == desired { return }
        }
    }
}
