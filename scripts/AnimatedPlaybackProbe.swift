import Foundation
import Synchronization
@testable import pag_swift

/// 真实 SD 双动图的同条件 CPU 帧准备比较；显示时间按 120Hz 推进，不冒称实际屏幕 FPS。
@main struct AnimatedPlaybackProbe {
    /// 正常 decoder 与额外 25ms 慢解码各比较精确等待和实时非等待，报告独立保存。
    static func main() async {
        do {
            let root = URL(filePath: CommandLine.arguments[1])
            var reports: [AnimatedPlaybackMeasurement] = []
            for delay in [0.0, 0.025] {
                for waits in [true, false] {
                    reports.append(try await measure(root: root, delay: delay, waits: waits))
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reports)
            try data.write(to: URL(filePath: CommandLine.arguments[2]), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("Animated playback probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 每组重新准备同样的素材与场景，固定根位置，只推进两秒独立动图时间。
    private static func measure(root: URL, delay: Double, waits: Bool) async throws -> AnimatedPlaybackMeasurement {
        let file = try await PAGLoader().load(from: root.appending(path: "editing/replace.pag"))
        var composition = file.composition
        var sources: [MeasuredAnimationSource] = []
        let names = ["bear.gif", "webp01.webp"]
        for (tag, name) in zip(["scene.png", "rotation.jpg"], names) {
            let original = try await DemoSDWebImage.load(from: root.appending(path: "media/\(name)"))
            guard let input = original.animation?.externalSource else { throw PAGError.mediaFailure("probeAnimation") }
            let source = MeasuredAnimationSource(input, delay: delay)
            sources.append(source)
            try await composition.apply(.image(PAGImage.animated(from: source)), forTag: tag)
        }
        let scene = try await PreparedScene.prepare(composition)
        let origin = ContinuousClock.now
        var costs: [Double] = []
        var lateness: [Double] = []
        var changes = 0
        var previous: Set<DocumentIdentity> = []
        var peakBytes = 0
        var peakPending = 0
        for tick in 0..<240 {
            let scheduled = origin.advanced(by: .microseconds(tick * 8_333))
            try await ContinuousClock().sleep(until: scheduled)
            let started = ContinuousClock.now
            lateness.append(max(0, milliseconds(scheduled.duration(to: started))))
            let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: composition.size,
                scale: 1, mode: .aspectFit, isPlaying: true,
                imageAnimationTime: PAGTime(microseconds: Int64(tick) * 8_333), waitsForAnimatedImages: waits)
            costs.append(milliseconds(started.duration(to: .now)))
            let current = Set(frame.images.filter { $0.value.storage.sourceType == "pag.hostFrame" }.keys)
            if !previous.isEmpty, current != previous { changes += 1 }
            previous = current
            if let state = await scene.animatedImages?.diagnostics {
                peakBytes = max(peakBytes, state.retainedBytes + state.decodingBytes)
                peakPending = max(peakPending, state.pendingFrames)
                guard state.retainedBytes + state.decodingBytes <= state.byteLimit,
                      state.decodingFrames <= 1, state.pendingFrames <= 16 else {
                    throw PAGError.resourceLimitExceeded("probeAnimatedBudget")
                }
            }
        }
        let elapsed = milliseconds(origin.duration(to: .now))
        await scene.animatedImages?.waitForCurrentWork()
        guard changes > 0 else { throw PAGError.mediaFailure("probeAnimationNeverChanged") }
        let sorted = costs.sorted()
        return AnimatedPlaybackMeasurement(mode: waits ? "exactWait" : "liveNonblocking",
            injectedDecodeDelayMilliseconds: delay * 1000, samples: costs.count,
            elapsedMilliseconds: elapsed, medianMilliseconds: sorted[sorted.count / 2],
            p95Milliseconds: sorted[Int(Double(sorted.count - 1) * 0.95)],
            maximumMilliseconds: sorted.last ?? 0, maximumSamplingLatenessMilliseconds: lateness.max() ?? 0,
            selectedFrameChanges: changes, decoderCalls: Dictionary(uniqueKeysWithValues: zip(names, sources.map(\.count))),
            peakCacheAndDecodeReservationBytes: peakBytes, peakPendingFrames: peakPending)
    }

    /// 只转换墙钟 Duration，不把计划耗时混入 GPU 或系统呈现指标。
    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}

/// 透明计数包装真实 SD 源；延迟只模拟同步 decoder 慢帧，不替换实际图片解码。
private final class MeasuredAnimationSource: PAGAnimatedImageSource {
    /// 宿主提供的逐帧时间表原样保留。
    let info: PAGAnimatedImageInfo
    /// 真实 SD 完整帧读取边界。
    private let source: any PAGAnimatedImageSource
    /// 测试额外阻塞秒数，正常场景为零。
    private let delay: Double
    /// 同步 worker 与报告读取之间的短锁计数。
    private let calls = Mutex(0)
    /// 包含建立素材首帧在内的实际读取次数。
    var count: Int { calls.withLock { $0 } }

    /// 包装已加载源；工厂及播放阶段均执行相同延迟策略。
    init(_ source: any PAGAnimatedImageSource, delay: Double) {
        self.source = source
        self.delay = delay
        info = source.info
    }

    /// 仅在同步源入口模拟耗时，实时播放调用由独立解码队列执行，主线程不会在这里等待。
    func frame(at index: Int) throws -> PAGImageFrame? {
        calls.withLock { $0 += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return try source.frame(at: index)
    }
}

/// 单组实际测量，所有毫秒字段仅代表后台计划或采样调度，不代表屏幕帧率。
private struct AnimatedPlaybackMeasurement: Encodable {
    /// 精确等待或生产实时采样路径。
    let mode: String
    /// 人为注入的每次同步解码延迟；零为原始 SD 行为。
    let injectedDecodeDelayMilliseconds: Double
    /// 两秒内计划采样数，固定 240。
    let samples: Int
    /// 本组采样实际墙钟时长。
    let elapsedMilliseconds: Double
    /// 帧准备中位耗时。
    let medianMilliseconds: Double
    /// 帧准备第 95 百分位耗时。
    let p95Milliseconds: Double
    /// 最慢单次帧准备耗时。
    let maximumMilliseconds: Double
    /// 采样启动相对于预定刷新时刻的最大落后量。
    let maximumSamplingLatenessMilliseconds: Double
    /// 两槽输入集合发生变化的次数，仅是帧计划证据。
    let selectedFrameChanges: Int
    /// 每种真实素材的源读取次数。
    let decoderCalls: [String: Int]
    /// 每次帧计划完成后观察到的缓存加在途预留最大值；精确等待路径不会观察到已结束的解码预留。
    let peakCacheAndDecodeReservationBytes: Int
    /// 此组实际观察到的最大待请求数。
    let peakPendingFrames: Int
}
