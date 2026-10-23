import Foundation
import pag_swift

/// 独立宿主逻辑验收：真实目录扫描、损坏候选保留、可见预览名额和取消释放，不启动 Demo。
@main struct DemoCatalogProbe {
    /// 运行失败输出错误并返回非零，成功保存可复现 JSON。
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Demo catalog probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 用真实 PAG 副本和明确无效候选验证目录与生命周期，再扫描仓库原资源。
    @MainActor private static func run() async throws {
        let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let output = URL(filePath: CommandLine.arguments[2])
        let temporary = FileManager.default.temporaryDirectory.appending(path: "pag-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary.appending(path: "nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try Data(contentsOf: root.appending(path: "red.pag"))
        for name in ["a.pag", "nested/b.pag", "opaque", "ignored.gif", "ignored.png"] {
            try data.write(to: temporary.appending(path: name))
        }
        for name in ["1", "broken.pag", "readme"] { try Data("invalid".utf8).write(to: temporary.appending(path: name)) }
        let candidates = try await DemoResourceCatalog.scan(root: temporary)
        try expect(candidates.map(\.id) == ["1", "a.pag", "broken.pag", "nested/b.pag", "opaque"], "候选类型或稳定排序错误")
        let catalog = DemoCatalogModel()
        await catalog.refresh(root: temporary)
        try expect(catalog.error == nil && catalog.resources.count == 5, "目录模型扫描失败")
        for resource in candidates.prefix(4) { catalog.setVisible(resource.id, true) }
        try await wait { catalog.previews.count == 3 }
        weak let previous = catalog.previews["1"]
        catalog.setVisible("1", false)
        try await wait { catalog.previews["nested/b.pag"] != nil && previous == nil }
        try expect(catalog.peakPreviewCount == 3, "预览超过三份或旧行未释放")
        catalog.filter("nested")
        try await wait { catalog.previews.count == 1 }
        try expect(catalog.filtered.map(\.id) == ["nested/b.pag"], "搜索错误")
        await catalog.stopAndWait()
        try expect(catalog.previews.isEmpty, "离开列表后仍有预览")
        catalog.setEnabled(true)
        try await wait { catalog.previews.count == 1 }
        catalog.setVisible("不存在的旧行", true)
        await catalog.stopAndWait()
        try expect(catalog.previews.isEmpty, "返回再退出没有释放")
        let actual = try await DemoResourceCatalog.scan(root: root)
        let summary = CatalogProbeReport(candidateCount: actual.count, extensionless: actual.filter { $0.url.pathExtension.isEmpty }.map(\.id),
            peakPreviews: catalog.peakPreviewCount,
            checks: ["recursive scan", "damaged candidates retained", "replacement media excluded", "stable order",
                     "search", "three preview limit", "offscreen release", "row replacement", "leave and return"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(summary)
        try encoded.write(to: output, options: .atomic)
        print(String(decoding: encoded, as: UTF8.self))
    }

    /// 有截止地等待真实异步清理结果，不以固定延时猜测任务已经结束。
    @MainActor private static func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ProbeFailure(message: "异步生命周期等待超时") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 每项不变量失败都终止探针，不输出假成功报告。
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeFailure(message: message) }
    }
}

/// 可供后续报告比较的纯值目录和生命周期证据，不包含屏幕验收结论。
nonisolated private struct CatalogProbeReport: Codable {
    /// 实际仓库资源候选总数。
    let candidateCount: Int
    /// 按内容/已知名称识别的无扩展名 PAG 路径。
    let extensionless: [String]
    /// 实际预览分配峰值。
    let peakPreviews: Int
    /// 已执行并通过的宿主逻辑断言。
    let checks: [String]
}

/// 探针本身的不变量错误，保留可定位的文字。
nonisolated private struct ProbeFailure: Error {
    /// 失败条件说明。
    let message: String
}
