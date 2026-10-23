import SwiftUI
import pag_swift

/// 资源浏览入口，只组织导航和可见行，实际预览使用库的 PAGView。
struct ContentView: View {
    /// 单窗口目录与可见行预览拥有者。
    @State private var catalog = DemoCatalogModel()
    /// 搜索草稿，变化时由模型生成稳定过滤结果。
    @State private var query = ""
    /// 明确的详情、完整批播和宿主对照路由。
    @State private var path: [DemoRoute] = []
    /// 启动参数只应用一次，避免返回列表又被自动推回详情。
    @State private var appliedLaunchRoute = false
    /// 应用不活跃时释放预览工作，不靠滚动可见性猜测后台状态。
    @Environment(\.scenePhase) private var scenePhase

    /// 列表卡片突出预览、路径、元数据和实际状态；没有固定样例 Picker。
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    HStack {
                        Text("\(catalog.filtered.count) / \(catalog.resources.count) 个 PAG 候选")
                        Spacer()
                        Text("预览 \(catalog.previews.count)").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let error = catalog.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(catalog.filtered) { resource in
                        NavigationLink(value: DemoRoute.detail(resource)) {
                            DemoResourceRow(resource: resource, session: catalog.previews[resource.id],
                                            previous: catalog.summaries[resource.id])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catalog.item.\(resource.id)")
                        .onScrollVisibilityChange(threshold: 0.15) { catalog.setVisible(resource.id, $0) }
                        .onDisappear { catalog.setVisible(resource.id, false) }
                    }
                    if catalog.filtered.isEmpty, !catalog.isScanning {
                        ContentUnavailableView(query.isEmpty ? "未发现 PAG 候选" : "没有匹配的资源",
                            systemImage: "doc.richtext", description: Text("递归扫描 resources；支持无扩展名 PAG。"))
                    }
                }
                .padding()
            }
            .background(.quaternary.opacity(0.35))
            .navigationTitle("PAG 资源库")
            .searchable(text: $query, prompt: "搜索文件名或相对路径")
            .toolbar {
                ToolbarItemGroup {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await catalog.refresh() } }
                        .disabled(catalog.isScanning)
                    NavigationLink(value: DemoRoute.batch) { Label("播放全部", systemImage: "play.rectangle.on.rectangle") }
                        .disabled(catalog.resources.isEmpty)
                        .accessibilityIdentifier("catalog.playAll")
                }
            }
            .refreshable { await catalog.refresh() }
            .navigationDestination(for: DemoRoute.self) { route in
                DemoDestination(route: route, catalog: catalog)
            }
        }
        .frame(minWidth: 340)
        .task {
            await catalog.refresh()
            guard !appliedLaunchRoute else { return }
            appliedLaunchRoute = true
            if CommandLine.arguments.contains("--pag-batch") { path = [.batch] }
            else if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--pag-sample=") }),
                    let resource = catalog.resources.first(where: { $0.id == String(argument.dropFirst("--pag-sample=".count)) }) {
                path = [DemoHostVerification.isRequested ? .hosts(resource) : .detail(resource)]
            }
        }
        .onChange(of: query) { _, value in catalog.filter(value) }
        .onChange(of: path) { _, value in catalog.setEnabled(value.isEmpty && scenePhase == .active) }
        .onChange(of: scenePhase) { _, value in catalog.setEnabled(path.isEmpty && value == .active) }
        .onDisappear { catalog.setEnabled(false) }
    }
}

/// 资源路径是可还原的路由值，不在导航值中持有播放器。
enum DemoRoute: Hashable {
    /// 单份真实资源详情。
    case detail(DemoResource)
    /// 完整目录按稳定顺序播放一轮。
    case batch
    /// 显式进入两个宿主的对照验收页。
    case hosts(DemoResource)
}

/// 单行只有一个顶层卡片；播放器由目录模型按可见性提供，行本身不创建媒体工作。
private struct DemoResourceRow: View {
    /// 当前资源候选，身份和路径始终稳定。
    let resource: DemoResource
    /// 当前可见行的预览会话；尚未创建或已离屏释放时为 nil。
    let session: DemoSession?
    /// 之前一次预览留下的有限文本摘要。
    let previous: String?

    /// 实时预览与文件信息各占一列，失败仍可点击进入详情查看诊断。
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Color.black.opacity(0.08)
                if let session { PAGView(player: session.player) }
                else { Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .frame(width: 112, height: 100).clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(resource.name).font(.headline)
                Text(resource.id).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(session.map { $0.metadata.isEmpty ? resource.sizeLabel : $0.metadata } ?? resource.sizeLabel)
                    .font(.caption).monospacedDigit()
                Text(session?.errorMessage ?? session?.status ?? previous ?? "等待预览")
                    .font(.caption).foregroundStyle(session?.errorMessage == nil ? Color.secondary : Color.red).lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14).background(.background, in: .rect(cornerRadius: 18))
    }
}

/// 导航交接先排空预览，再创建详情/批播播放器，避免旧预览与新重活重叠。
private struct DemoDestination: View {
    /// 当前目的页与资源身份。
    let route: DemoRoute
    /// 首页预览拥有者，只用于等待释放和读取批播目录。
    let catalog: DemoCatalogModel
    /// 预览完全退出后才挂入需要播放的目的页。
    @State private var ready = false

    /// 交接期间明确显示进度；取消导航不会随后偷偷启动旧页面。
    var body: some View {
        Group {
            if ready {
                switch route {
                case .detail(let resource): DemoDetailView(resource: resource).id(resource.id)
                case .batch: DemoBatchView(resources: catalog.resources)
                case .hosts(let resource): DemoHostLab(resource: resource)
                }
            } else { ProgressView("正在释放列表预览…") }
        }
        .task {
            await catalog.stopAndWait()
            if !Task.isCancelled { ready = true }
        }
    }
}
