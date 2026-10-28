import Dispatch
import Foundation
import Synchronization
import Testing
@testable import pag_swift

/// 可控同步 decoder 验证实时采样不等待、有限预取和跨素材撤销；不靠短 sleep 猜测并发顺序。
@Suite(.timeLimit(.minutes(1)))
struct AnimatedImagePrefetchTests {
    /// 同一素材用于不同实例时，较早实例缺帧不能显示另一实例较晚的已选帧。
    @Test func sharedMaterialKeepsEachInstancesOwnFallback() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, offsets: [0, 0])
        let record = try #require(file.composition.dynamicSlotRecords().first)
        let ids = record.instances.map { file.storage.instances[$0].id }
        try #require(ids.count == 2)
        let source = try GatedAnimatedFrames()
        defer { source.release(32) }
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        var entered = source.entered.makeAsyncIterator()
        _ = try await owner.availableFrame(for: image, at: time(100_000), instance: ids[0], isPlaying: true)
        #expect(await entered.next() == 1)
        source.release()
        await owner.waitForCurrentWork()
        #expect(try await owner.availableFrame(for: image, at: time(100_000), instance: ids[0], isPlaying: false).storage.pixels.first == 2)
        _ = try await owner.availableFrame(for: image, at: time(300_000), instance: ids[1], isPlaying: true)
        #expect(await entered.next() == 3)
        source.release()
        await owner.waitForCurrentWork()
        #expect(try await owner.availableFrame(for: image, at: time(300_000), instance: ids[1], isPlaying: false).storage.pixels.first == 4)
        #expect(try await owner.availableFrame(for: image, at: time(200_000), instance: ids[0], isPlaying: true).storage.pixels.first == 2)
        #expect(await entered.next() == 2)
    }

    /// 一份长动画的历史帧不能随播放时间无限增长，即便字节预算仍有余额也只保留 32 帧。
    @Test func longAnimationRetainsAtMostThirtyTwoFrames() async throws {
        let source = try GatedAnimatedFrames(blocks: false, frameCount: 64)
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        for index in 1...40 {
            _ = try await owner.availableFrame(for: image, at: time(Int64(index) * 100_000), isPlaying: true)
            await owner.waitForCurrentWork()
        }
        #expect(await owner.retainedBytes() == 32 * 8)
        #expect(source.requests.count == 41)
    }

    /// decoder 被门闩挂起时采样和诊断仍返回；暂停清空待请求，至多让当前一项结束。
    @Test func slowDecoderCannotBlockSamplingAndPauseStopsPendingWork() async throws {
        let source = try GatedAnimatedFrames()
        defer { source.release(32) }
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        var entered = source.entered.makeAsyncIterator()
        let first = try await owner.availableFrame(for: image, at: time(100_000), isPlaying: true)
        #expect(first.storage.pixels.first == 1)
        #expect(await entered.next() == 1)
        for _ in 0..<20 {
            #expect(try await owner.availableFrame(for: image, at: time(200_000), isPlaying: true).storage.pixels.first == 1)
        }
        let report = await owner.diagnostics
        #expect(report.decodingFrames == 1 && report.pendingFrames == 1)
        #expect(report.retainedBytes + report.decodingBytes <= report.byteLimit)
        try await owner.retainMaterials([try #require(image.animation?.identity)], isPlaying: false)
        source.release()
        await owner.waitForCurrentWork()
        #expect(source.requests == [0, 1])
        #expect(await owner.diagnostics.pendingFrames == 0)
        #expect(await owner.diagnostics.decodingFrames == 0)
    }

    /// 相邻帧提前解好也不能早于其时长边界显示；有限最后一轮不继续预取首帧。
    @Test func prefetchedFrameWaitsForItsOwnTimeBoundary() async throws {
        let source = try GatedAnimatedFrames(blocks: false, playCount: 1)
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        #expect(try await owner.availableFrame(for: image, at: .zero, isPlaying: true).storage.pixels.first == 1)
        await owner.waitForCurrentWork()
        #expect(source.requests == [0, 1])
        #expect(try await owner.availableFrame(for: image, at: time(99_999), isPlaying: false).storage.pixels.first == 1)
        #expect(try await owner.availableFrame(for: image, at: time(100_000), isPlaying: true).storage.pixels.first == 2)
        await owner.waitForCurrentWork()
        #expect(try await owner.availableFrame(for: image, at: time(200_000), isPlaying: true).storage.pixels.first == 3)
        await owner.waitForCurrentWork()
        #expect(try await owner.availableFrame(for: image, at: time(400_000), isPlaying: true).storage.pixels.first == 4)
        #expect(await owner.diagnostics.decodingFrames == 0)
        #expect(source.requests == [0, 1, 2, 3])
    }

    /// 慢帧期间同一实例的新需求覆盖旧目标，追上独立时间而非顺序补播已经过期的帧。
    @Test func currentTimeReplacesStaleQueuedFrame() async throws {
        let source = try GatedAnimatedFrames()
        defer { source.release(32) }
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        var entered = source.entered.makeAsyncIterator()
        _ = try await owner.availableFrame(for: image, at: time(100_000), isPlaying: true)
        #expect(await entered.next() == 1)
        _ = try await owner.availableFrame(for: image, at: time(200_000), isPlaying: true)
        _ = try await owner.availableFrame(for: image, at: time(300_000), isPlaying: true)
        source.release()
        await owner.waitForCurrentWork()
        _ = try await owner.availableFrame(for: image, at: time(300_000), isPlaying: true)
        #expect(await entered.next() == 3)
        source.release()
        await owner.waitForCurrentWork()
        #expect(try await owner.availableFrame(for: image, at: time(300_000), isPlaying: false).storage.pixels.first == 4)
        #expect(source.requests == [0, 1, 3])
    }

    /// 换素材后当前旧调用可结束，但不能回填缓存；新素材缺帧只显示自己的首帧。
    @Test func lateOldMaterialCannotRepopulateOrLeakIntoNewContent() async throws {
        let old = try GatedAnimatedFrames()
        defer { old.release(32) }
        let new = try GatedAnimatedFrames(offset: 20, blocks: false)
        let oldImage = try await PAGImage.animated(from: old)
        let newImage = try await PAGImage.animated(from: new)
        let owner = AnimatedImageFrameStore()
        var entered = old.entered.makeAsyncIterator()
        _ = try await owner.availableFrame(for: oldImage, at: time(100_000), isPlaying: true)
        #expect(await entered.next() == 1)
        try await owner.retainMaterials([try #require(newImage.animation?.identity)], isPlaying: true)
        #expect(try await owner.availableFrame(for: newImage, at: time(100_000), isPlaying: true).storage.pixels.first == 21)
        old.release()
        await owner.waitForCurrentWork()
        #expect(await owner.retainedBytes() == 0)
        _ = try await owner.availableFrame(for: newImage, at: time(100_000), isPlaying: true)
        await owner.waitForCurrentWork()
        #expect(try await owner.availableFrame(for: newImage, at: time(100_000), isPlaying: false).storage.pixels.first == 22)
    }

    /// 不合作宿主尚未返回也不能保活媒体 owner；释放取消唯一后台任务，不新开替代 worker。
    @Test func blockedWorkerDoesNotRetainOwner() async throws {
        let source = try GatedAnimatedFrames()
        defer { source.release(32) }
        let image = try await PAGImage.animated(from: source)
        var owner: AnimatedImageFrameStore? = AnimatedImageFrameStore()
        weak var reference = owner
        var entered = source.entered.makeAsyncIterator()
        _ = try await owner?.availableFrame(for: image, at: time(100_000), isPlaying: true)
        #expect(await entered.next() == 1)
        owner = nil
        #expect(reference == nil)
    }

    /// 挂起一项后大量其它素材只形成 16 项待请求；逐素材解码完成后缓存仍受字节与素材数限制。
    @Test func requestsAndRetainedFramesRemainBounded() async throws {
        let slow = try GatedAnimatedFrames()
        defer { slow.release(32) }
        let image = try await PAGImage.animated(from: slow)
        let owner = AnimatedImageFrameStore(maximumBytes: 64)
        var entered = slow.entered.makeAsyncIterator()
        _ = try await owner.availableFrame(for: image, at: time(100_000), isPlaying: true)
        #expect(await entered.next() == 1)
        var images: [PAGImage] = []
        for offset: UInt8 in 1...24 {
            let input = try await PAGImage.animated(from: GatedAnimatedFrames(offset: offset, blocks: false))
            images.append(input)
            _ = try await owner.availableFrame(for: input, at: time(100_000), isPlaying: true)
        }
        #expect(await owner.diagnostics.pendingFrames == 16)
        #expect(await owner.diagnostics.decodingFrames == 1)
        slow.release()
        await owner.waitForCurrentWork()
        try await owner.retainMaterials(Set(images.compactMap { $0.animation?.identity }), isPlaying: false)
        for input in images {
            _ = try await owner.availableFrame(for: input, at: time(100_000), isPlaying: true)
            await owner.waitForCurrentWork()
            let state = await owner.diagnostics
            #expect(state.retainedBytes + state.decodingBytes <= state.byteLimit)
        }
        #expect(await owner.retainedBytes() <= 64)
    }

    /// 正式非等待帧计划在宿主 decoder 挂起时完成，证明不仅缓存单方法可响应。
    @Test func liveFramePlannerCompletesWhileHostDecodeIsBlocked() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 60, offsets: [0], fileDuration: 60)
        let source = try GatedAnimatedFrames()
        defer { source.release(32) }
        let image = try await PAGImage.animated(from: source)
        var composition = file.composition
        try composition.replaceImage(image, at: 0)
        let scene = try await PreparedScene.prepare(composition)
        var entered = source.entered.makeAsyncIterator()
        let first = try await FramePlanner.prepare(scene, at: .zero, targetSize: composition.size,
            scale: 1, mode: .aspectFit, isPlaying: true, imageAnimationTime: time(100_000), waitsForAnimatedImages: false)
        #expect(await entered.next() == 1)
        let later = try await FramePlanner.prepare(scene, at: time(500_000), targetSize: composition.size,
            scale: 1, mode: .aspectFit, isPlaying: true, imageAnimationTime: time(200_000), waitsForAnimatedImages: false)
        #expect(!first.plan.commands.isEmpty && !later.plan.commands.isEmpty)
        #expect(later.images[image.storage.identity] != nil)
        #expect(await scene.animatedImages?.diagnostics.decodingFrames == 1)
    }

    /// 测试输入均为独立素材微秒，不借根 PAG 帧率换算。
    private func time(_ value: Int64) -> PAGTime { PAGTime(microseconds: value) }
}

/// 在专用 decoder 队列阻塞的可控源；门闩只用于测试同步宿主，不在生产协作线程等待。
private final class GatedAnimatedFrames: PAGAnimatedImageSource {
    /// 各帧均为 100ms，默认四帧，长序列用于验证缓存条数上限。
    let info: PAGAnimatedImageInfo
    /// 同步帧读取进入后发出明确通知，测试不会用 sleep 推测 worker 状态。
    let entered: AsyncStream<Int>
    /// 通知的唯一生产端，由 decoder 队列调用。
    private let continuation: AsyncStream<Int>.Continuation
    /// 挂起后续帧的门闩；首帧永不阻塞，以便正常建立素材。
    private let gate = DispatchSemaphore(value: 0)
    /// 启用同步阻塞场景，false 用于快速缓存和预算验证。
    private let blocks: Bool
    /// 不同素材使用不同通道偏移，检测跨素材污染。
    private let offset: UInt8
    /// 所有读取帧号在短锁内追加，报告只读取不可变副本。
    private let calls = Mutex<[Int]>([])
    /// 包含工厂首帧在内的实际读取顺序。
    var requests: [Int] { calls.withLock { $0 } }

    /// 建立固定小画布与有限/无限循环元数据，不保存可变平台图片。
    init(offset: UInt8 = 0, blocks: Bool = true, playCount: Int? = nil, frameCount: Int = 4) throws {
        self.offset = offset
        self.blocks = blocks
        info = try PAGAnimatedImageInfo(size: PAGSize(width: 2, height: 1),
            frameDurations: Array(repeating: PAGTime(microseconds: 100_000), count: frameCount), playCount: playCount)
        let pair = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(64))
        entered = pair.stream
        continuation = pair.continuation
    }

    /// 返回完整两像素画布；测试显式控制后续同步调用何时退出。
    func frame(at index: Int) throws -> PAGImageFrame? {
        calls.withLock { $0.append(index) }
        if index > 0 {
            continuation.yield(index)
            if blocks { gate.wait() }
        }
        return try PAGImageFrame(width: 2, height: 1,
            pixels: Data([offset + UInt8(index + 1), 0, 0, 255, 0, 0, 0, 0]))
    }

    /// 测试退出也释放已进入的 worker，避免失败用例遗留挂起同步线程。
    func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
}
