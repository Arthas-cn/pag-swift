import Foundation
import pag_swift

/// 测量真实资源的解析缓存及场景准备；不挂载窗口，也不把准备耗时当成 GPU 或屏幕性能。
@main struct CachePerformanceProbe {
    /// 使用固定构建的库并保存原始样本；任何加载错误都返回失败，不筛掉慢样本。
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Cache performance probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 每份资源交替清缓存/命中，再执行八路并发；OS 文件页缓存不被清除。
    private static func run() async throws {
        let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let output = URL(filePath: CommandLine.arguments[2])
        let buildURL = URL(filePath: CommandLine.arguments[3])
        let artifact = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: buildURL))
        let paths = ["red.pag", "test2.pag", "editing/replace.pag", "shanzi_video.pag"]
        var samples: [PerformanceSample] = []
        for path in paths {
            let url = root.appending(path: path)
            let loader = try PAGLoader()
            for iteration in 0..<20 {
                await loader.removeCachedFiles()
                let cold = try await loader.loadWithReport(from: url)
                samples.append(PerformanceSample(path: path, scenario: "parsedCacheEmpty", iteration: iteration,
                    load: cold.report, preparationSeconds: nil))
                let warm = try await loader.loadWithReport(from: url)
                guard cold.report.cache == .miss, warm.report.cache == .hit else {
                    throw PerformanceFailure(message: "\(path) 没有出现预期 miss/hit")
                }
                // 新播放器隔离可变编辑与媒体 owner；这里只有 CPU 准备，没有显示目标或 drawable。
                let player = PAGPlayer()
                try await player.setComposition(warm.file.composition)
                let preparation = await player.diagnostics?.preparationSeconds
                samples.append(PerformanceSample(path: path, scenario: "parsedCacheHit", iteration: iteration,
                    load: warm.report, preparationSeconds: preparation))
                try await player.setComposition(nil)
            }
            for iteration in 0..<5 {
                await loader.removeCachedFiles()
                let before = await loader.statistics.parses
                let reports = try await withThrowingTaskGroup(of: PAGLoadReport.self) { group in
                    for _ in 0..<8 { group.addTask { try await loader.loadWithReport(from: url).report } }
                    var values: [PAGLoadReport] = []
                    for try await value in group { values.append(value) }
                    return values
                }
                guard await loader.statistics.parses == before + 1 else {
                    throw PerformanceFailure(message: "\(path) 八路加载重复解析")
                }
                samples += reports.map {
                    PerformanceSample(path: path, scenario: "eightConcurrentLoads", iteration: iteration,
                        load: $0, preparationSeconds: nil)
                }
            }
        }
        let report = PerformanceReport(runID: UUID(), date: Date(), artifact: artifact,
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            logicalCPUs: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, samples: samples,
            conditions: "Debug 库；每份 20 对解析空缓存/命中，5 组八路并发；不清 OS 页缓存；场景准备不含 GPU/呈现；未挂载窗口")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: output, options: .atomic)
        print("Saved \(samples.count) raw samples to \(output.path)")
    }
}

/// 保留每次原始阶段值，后处理可重新计算分位数而不依赖打印摘要。
nonisolated private struct PerformanceSample: Codable {
    /// 仓库资源相对路径。
    let path: String
    /// 解析缓存为空、命中或八路并发，不把 OS 缓存状态混入名称。
    let scenario: String
    /// 同一场景重复次数的零基序号。
    let iteration: Int
    /// 库给出的真实阶段耗时和缓存结果。
    let load: PAGLoadReport
    /// 新播放器场景准备耗时；没有执行此阶段时为 nil。
    let preparationSeconds: Double?
}

/// 可复现实测条件与全部原始样本，不自动给性能打 PASS。
nonisolated private struct PerformanceReport: Codable {
    /// 此次测量独立身份。
    let runID: UUID
    /// 测量结束的墙钟时间。
    let date: Date
    /// 实际链接的固定构建身份及配置。
    let artifact: [String: String]
    /// 完整系统版本。
    let system: String
    /// 逻辑核数，用于解释并发测量环境。
    let logicalCPUs: Int
    /// 设备物理内存，不等于本次进程占用。
    let physicalMemoryBytes: UInt64
    /// 未过滤的每次成功样本；失败会终止并明确报错。
    let samples: [PerformanceSample]
    /// 影响结果解释的操作与未测量边界。
    let conditions: String
}

/// 测量的不变量错误，避免产出不满足场景定义的数据。
nonisolated private struct PerformanceFailure: Error {
    /// 哪份资源、哪个测量约定不满足。
    let message: String
}
