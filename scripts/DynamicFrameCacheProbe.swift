import Foundation
import Synchronization
@testable import pag_swift

/// 两个真实 SD 动图在同一 PAG 的帧计划性能探针；只测后台准备，不冒称屏幕帧率。
@main struct DynamicFrameCacheProbe {
    /// 固定两秒、120 Hz 的采样输入，报告实际 decoder 调用次数与每帧 CPU 墙钟耗时。
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Dynamic cache probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 通过真实 tag 安装 GIF 和 WebP；重复运行使用同一资源与时间序列，避免比较不同场景。
    private static func run() async throws {
        let root = URL(filePath: CommandLine.arguments[1])
        let file = try await PAGLoader().load(from: root.appending(path: "editing/replace.pag"))
        let media = ["bear.gif", "webp01.webp"]
        var composition = file.composition
        var sources: [CountedHostSource] = []
        let tags = ["scene.png", "rotation.jpg"]
        for (name, tag) in zip(media, tags) {
            let original = try await DemoSDWebImage.load(from: root.appending(path: "media/\(name)"))
            guard let source = original.animation?.externalSource else {
                throw PAGError.mediaFailure("cacheProbeHostSource")
            }
            let counted = CountedHostSource(source)
            sources.append(counted)
            try await composition.apply(.image(PAGImage.animated(from: counted)), forTag: tag)
        }
        let scene = try await PreparedScene.prepare(composition)
        var milliseconds: [Double] = []
        for tick in 0..<240 {
            let start = ContinuousClock.now
            _ = try await FramePlanner.prepare(scene, at: .zero, targetSize: composition.size,
                scale: 1, mode: .aspectFit, imageAnimationTime: PAGTime(microseconds: Int64(tick) * 8_333))
            let duration = start.duration(to: .now).components
            milliseconds.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        let sorted = milliseconds.sorted()
        let report = CacheProbeResult(samples: milliseconds.count, medianMilliseconds: sorted[sorted.count / 2],
            p95Milliseconds: sorted[Int(Double(sorted.count - 1) * 0.95)],
            maximumMilliseconds: sorted.last ?? 0, decoderCalls: Dictionary(uniqueKeysWithValues:
                zip(media, sources.map(\.count))), retainedBytes: await scene.animatedImages?.retainedBytes())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(filePath: CommandLine.arguments[2]), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}

/// 透明包装真实 SD 帧源，只计调用次数，不替换解码或添加自己的缓存。
private final class CountedHostSource: PAGAnimatedImageSource {
    /// 已由宿主提供的不可变时间表。
    let info: PAGAnimatedImageInfo
    /// 实际解码器仍由宿主保证同步。
    private let source: any PAGAnimatedImageSource
    /// 后台调用与报告读取之间通过短锁同步计数。
    private let calls = Mutex(0)
    /// 包含 PAGImage 工厂读取首帧在内的实际调用总数。
    var count: Int { calls.withLock { $0 } }

    /// 接受已有源，不额外解码或保存帧。
    init(_ source: any PAGAnimatedImageSource) { self.source = source; info = source.info }

    /// 原样转发完整帧，包括 nil 和错误。
    func frame(at index: Int) throws -> PAGImageFrame? {
        calls.withLock { $0 += 1 }
        return try source.frame(at: index)
    }
}

/// 当前构建在固定真实输入上的测量结果，不含 GPU 或 WindowServer 耗时。
private struct CacheProbeResult: Encodable {
    /// 相同采样序列中的实际计划数量。
    let samples: Int
    /// 帧计划墙钟毫秒的中位数。
    let medianMilliseconds: Double
    /// 帧计划墙钟毫秒的第 95 百分位。
    let p95Milliseconds: Double
    /// 此轮最慢帧的毫秒数。
    let maximumMilliseconds: Double
    /// 每个真实素材的 decoder 访问次数。
    let decoderCalls: [String: Int]
    /// owner 当前 RGBA 留存，未建立 owner 时为 nil。
    let retainedBytes: Int?
}
