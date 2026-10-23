import Foundation
import pag_swift
#if os(iOS)
import UIKit
#endif

/// 宿主操作的有限日志，不在逐帧绘制回调里写入或同步刷盘。
nonisolated struct DemoLogEntry: Sendable, Codable, Identifiable {
    /// 每条交互独立身份，保证 SwiftUI 日志列表稳定。
    let id: UUID
    /// 人类可读的墙钟时间；精确阶段耗时由库诊断提供。
    let date: Date
    /// 用户操作或生命周期阶段。
    let operation: String
    /// 本次目标 tag，没有单槽目标时为 nil。
    let tag: String?
    /// 复现用参数或错误，不包含像素或任意大对象。
    let detail: String

    /// 为本次真实交互分配身份；解码报告时保留原始身份和时间，不重新生成。
    init(operation: String, tag: String?, detail: String) {
        id = UUID()
        date = Date()
        self.operation = operation
        self.tag = tag
        self.detail = detail
    }
}

/// 一份资源的机器可读验收，分别表达解析、渲染、播放和人工画面结果。
nonisolated struct DemoResourceReport: Sendable, Codable {
    /// 一次详情或整次批播的共同身份。
    let runID: UUID
    /// 实际资源相对路径和文件大小。
    let resource: DemoResource
    /// 实际运行环境及构建信息。
    let environment: DemoEnvironment
    /// 播放控制最终状态或超时/取消/失败原因。
    let endReason: String
    /// 解析成功、失败或未执行；与屏幕状态分开。
    let parsing: String
    /// GPU 完成证据，有计数才标记 completed。
    let rendering: String
    /// 只有自然结束一轮才是 finished；预览、手动暂停和冒烟不能冒充完整播放。
    let playback: String
    /// 人工截图或视觉比对状态，默认 pending，不由帧数自动推断。
    let visual: String
    /// 一一对应的本次加载报告；加载早期失败可能只有错误日志。
    let load: PAGLoadReport?
    /// 当前会话帧证据与预算；未准备成功为 nil。
    let diagnostics: PAGPlaybackDiagnostics?
    /// 最后 256 条 provider 事件，包含版本、tag、失败和迟到丢弃。
    let contentEvents: [PAGContentEvent]
    /// 最后 128 条宿主交互参数。
    let actions: [DemoLogEntry]
    /// 错误原文；没有错误为 nil。
    let error: String?
}

/// 比较报告必需的环境条件，不用运行时间冒充构建版本。
nonisolated struct DemoEnvironment: Sendable, Codable {
    /// 系统名称及完整版本。
    let system: String
    /// 设备型号/主机架构说明，不写用户设备昵称。
    let device: String
    /// 工程版本与构建号。
    let build: String
    /// Debug 或 Release，影响性能解释。
    let configuration: String
    /// 构建脚本写入的构建 UUID、配置摘要、构建时间和 SDK；未随包提供时为 nil，不能伪造版本。
    let artifact: [String: String]?
    /// 进程启动时首次捕获的构建标记，之后重新构建磁盘 App 不会改写当前进程的报告身份。
    private static let buildArtifact: [String: String]? = {
        guard let url = Bundle.main.url(forResource: "pag-build", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }()

    /// 平台 UI 信息仅在主 actor 读取，然后转成可传送值。
    @MainActor static func current() -> DemoEnvironment {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if os(iOS)
        let device = UIDevice.current.model
        #else
        let device = "Mac / \(ProcessInfo.processInfo.processorCount) logical CPUs"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return DemoEnvironment(system: ProcessInfo.processInfo.operatingSystemVersionString,
            device: device, build: "\(version) (\(build))", configuration: configuration, artifact: buildArtifact)
    }
}

/// 报告持久化只在导出、单份完成或批播结束时执行；最多保留十个 run 目录。
nonisolated enum DemoReportStore {
    /// 把不可变报告编码到 run 目录；错误向 UI 传播，不伪报导出成功。
    @concurrent static func save<Value: Encodable & Sendable>(_ report: Value, runID: UUID,
                                                              name: String) async throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appending(path: "PAGSwiftReports", directoryHint: .isDirectory)
        let directory = root.appending(path: runID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appending(path: name + ".json")
        try encoder.encode(report).write(to: url, options: .atomic)
        // 只清理本 Demo 自己管理的 run 目录，当前 run 永远不在淘汰集合。
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            .filter { $0 != directory && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        for expired in directories.dropFirst(9) { try FileManager.default.removeItem(at: expired) }
        return url
    }
}
