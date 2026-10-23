import Foundation

/// 一份待验证的 PAG 候选；候选不保证能解析，损坏文件也必须出现在目录和报告。
nonisolated struct DemoResource: Sendable, Hashable, Identifiable, Codable {
    /// 相对 resources 的完整路径，既是稳定列表身份也是报告复现参数。
    let id: String
    /// 当前 bundle 中的实际位置，不作为内容缓存身份。
    let url: URL
    /// 文件系统报告的字节数；元数据不可读取时为 nil，后续加载仍尝试并报告错误。
    let byteCount: Int?
    /// 文件名只用于标题，目录重名由 id 区分。
    var name: String { url.lastPathComponent }
    /// 展示实际文件大小，不能用零掩盖未能读取元数据。
    var sizeLabel: String {
        byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "大小未知"
    }
}

/// Demo 资源发现，不解析 PAG、不解码媒体，也不筛掉当前未支持的 PAG。
nonisolated enum DemoResourceCatalog {
    /// 工程已有文件夹资源引用保留此层级，缺少目录时让调用者明确报错。
    static var root: URL? { Bundle.main.resourceURL?.appending(path: "PAGSamples/resources", directoryHint: .isDirectory) }

    /// 后台递归收集候选，稳定排序；任何目录遍历错误都抛出，避免静默少报资源。
    @concurrent static func scan(root: URL) async throws -> [DemoResource] {
        try scanSynchronously(root: root)
    }

    /// FileManager 枚举器禁止直接在 async 体内迭代；只从上方后台入口调用此同步 IO 段。
    private static func scanSynchronously(root: URL) throws -> [DemoResource] {
        var directoryError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in directoryError = error; return false }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var result: [DemoResource] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard metadata?.isRegularFile != false else { continue }
            let extensionName = url.pathExtension.lowercased()
            var candidate = extensionName == "pag"
            if extensionName.isEmpty {
                // 仓库现有 1…22 是无扩展名 PAG；即使损坏也保留，不能只用成功解码作目录过滤。
                candidate = !url.lastPathComponent.isEmpty && url.lastPathComponent.allSatisfy(\.isNumber)
                if !candidate, let file = try? FileHandle(forReadingFrom: url) {
                    defer { try? file.close() }
                    candidate = (try? file.read(upToCount: 3)) == Data("PAG".utf8)
                }
            }
            guard candidate else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            result.append(DemoResource(id: String(path.dropFirst(prefix.count)), url: url, byteCount: metadata?.fileSize))
        }
        if let directoryError { throw directoryError }
        return result.sorted { $0.id < $1.id }
    }
}
