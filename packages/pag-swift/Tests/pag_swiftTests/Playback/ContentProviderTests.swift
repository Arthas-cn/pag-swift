import Foundation
import Testing
@testable import pag_swift

/// 业务 provider 的源槽去重、独立编辑和非合作异步生命周期，不依赖显示窗口。
struct ContentProviderTests {
    /// 四个源槽各请求一次，两个文字和多个共享图片实例的完成顺序不会丢失其它编辑。
    @Test(.timeLimit(.minutes(1))) func resolvesSourcesOnceAndMergesDifferentTags() async throws {
        let file = try await EditableFixtures.file()
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        let player = PAGPlayer()
        try await player.setComposition(file.composition)
        var events = await player.contentUpdates().makeAsyncIterator()
        await confirmation(expectedCount: 4) { called in
            try? await player.setContentProvider { slot in
                called()
                return slot.kind == .text ? .text(slot.tag, layout: .automatic) : .image(image)
            }
            for _ in 0..<4 { _ = await next(.applied, in: &events) }
        }
        let composition = try #require(await player.contentComposition)
        #expect(try composition.text(at: 0).text == "text:0")
        #expect(try composition.text(at: 1).text == "text:1")
        #expect(composition.edits.images.count == 5)
        #expect(composition.edits.visibility.isEmpty)
        #expect(file.composition.edits.images.isEmpty)
        #expect(await player.snapshot.failure == nil)
        let appliedTypes = await player.contentEvents.filter { $0.status == .applied }.compactMap(\.contentType)
        #expect(Set(appliedTypes) == ["text", "image.still"])
    }

    /// 连续更新同 tag 会结束旧等待，旧 provider 忽略取消并返回也不能覆盖新版。
    @Test(.timeLimit(.minutes(1))) func lateProviderCannotOverwriteNewContent() async throws {
        let (player, tag) = try await textPlayer()
        let gate = ContentProviderTestGate()
        var entered = gate.requests.makeAsyncIterator()
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.setContentProvider { slot in await gate.value(slot) }
        _ = await entered.next()
        try await player.updateContent(.text("新版", layout: .automatic), forTag: tag)
        _ = await next(.applied, in: &events)
        await gate.releaseAll(.text("迟到旧版", layout: .automatic))
        _ = await next(.discarded, in: &events)
        let composition = try #require(await player.contentComposition)
        #expect(try composition.text(at: 0).text == "新版")
        #expect(await player.contentEvents.last(where: { $0.status == .discarded })?.contentType == "text")
    }

    /// 切换无槽文档撤销旧会话，即使旧 provider 返回成功也不污染新文件。
    @Test(.timeLimit(.minutes(1))) func switchingDocumentRejectsOldProvider() async throws {
        let (player, _) = try await textPlayer()
        let gate = ContentProviderTestGate()
        var entered = gate.requests.makeAsyncIterator()
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.setContentProvider { slot in await gate.value(slot) }
        _ = await entered.next()
        let red = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        try await player.setComposition(red.composition)
        await gate.releaseAll(.hidden)
        _ = await next(.discarded, in: &events)
        #expect(await player.contentSlots.isEmpty)
        #expect(await player.contentComposition?.storage.identity == red.storage.identity)
        #expect(await player.contentComposition?.edits.visibility.isEmpty == true)
        await confirmation(expectedCount: 0) { called in
            try? await player.setContentProvider { _ in called(); return .hidden }
        }
    }

    /// 已就绪但尚未准备的内容被同 tag 更新取代，也必须记录旧版本取消及已知内容类型。
    @Test(.timeLimit(.minutes(1))) func replacingQueuedContentRecordsCancellation() async throws {
        let (player, tag) = try await textPlayer()
        var events = await player.contentUpdates().makeAsyncIterator()
        try await replaceQueuedContent(on: player, tag: tag)
        _ = await next(.applied, in: &events)
        let history = await player.contentEvents
        let requested = try #require(history.first { $0.status == .requested })
        let cancelled = history.filter { $0.contentVersion == requested.contentVersion && $0.status == .cancelled }
        #expect(cancelled.count == 1)
        #expect(cancelled.first?.contentType == "text")
        #expect(try await player.contentComposition?.text(at: 0).text == "新版")
    }

    /// 在同一个 actor 执行段内更新两次，确定性覆盖尚未启动的准备任务，不依赖调度速度。
    private func replaceQueuedContent(on player: isolated PAGPlayer, tag: String) throws {
        try player.updateContent(.text("待安装旧版", layout: .automatic), forTag: tag)
        try player.updateContent(.text("新版", layout: .automatic), forTag: tag)
    }

    /// 超时无需等待宿主退出；明确单槽更新仍可执行，迟到返回记录为丢弃。
    @Test(.timeLimit(.minutes(1))) func timeoutDoesNotWaitForUncooperativeProvider() async throws {
        let (player, tag) = try await textPlayer()
        let gate = ContentProviderTestGate()
        var entered = gate.requests.makeAsyncIterator()
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.setContentProvider({ slot in await gate.value(slot) },
            options: PAGContentOptions(timeout: .seconds(300)))
        _ = await entered.next()
        // 确认非合作宿主已经进入，再触发与计时器相同的门闩终态；全量并发负载不能把本场景偷换成未启动就过期。
        let resolution = try #require(await player.contentState.jobs[tag]?.gate)
        resolution.resolve(.failure(ContentResolutionError.timedOut))
        _ = await next(.timedOut, in: &events)
        try await player.updateContent(.text("超时后继续", layout: .automatic), forTag: tag)
        _ = await next(.applied, in: &events)
        await gate.releaseAll(.text("旧请求", layout: .automatic))
        _ = await next(.discarded, in: &events)
        #expect(try await player.contentComposition?.text(at: 0).text == "超时后继续")
        #expect(await player.snapshot.failure == nil)
    }

    /// 真实短期限无论在排队期间还是宿主等待期间到达，都结束请求且不要求存在迟到宿主结果。
    @Test(.timeLimit(.minutes(1))) func realDeadlineEndsQueuedOrRunningRequest() async throws {
        let (player, _) = try await textPlayer()
        let gate = ContentProviderTestGate()
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.setContentProvider({ slot in await gate.value(slot) },
            options: PAGContentOptions(timeout: .milliseconds(100)))
        _ = await next(.timedOut, in: &events)
        #expect(await player.snapshot.failure == nil)
        #expect(await player.contentState.jobs.isEmpty)
        // 超时前可能根本没获得运行机会；只释放确实进入的宿主，不等待一个并不存在的迟到事件。
        await gate.releaseAll(.unchanged)
    }

    /// 异步错误保留已安装占位，不把可选内容加载错误变成主播放错误。
    @Test(.timeLimit(.minutes(1))) func failureKeepsExplicitPlaceholder() async throws {
        let (player, tag) = try await textPlayer()
        let gate = ContentProviderTestGate()
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.resolveContent(forTag: tag, placeholder: .text("加载中", layout: .automatic)) { slot in
            _ = await gate.value(slot)
            throw PAGError.invalidArgument("hostFailure")
        }
        _ = await next(.placeholder, in: &events)
        await gate.releaseAll(.unchanged)
        _ = await next(.failed, in: &events)
        #expect(try await player.contentComposition?.text(at: 0).text == "加载中")
        #expect(await player.snapshot.failure == nil)
        try await player.updateContent(.original, forTag: tag)
        _ = await next(.applied, in: &events)
        #expect(try await player.contentComposition?.text(at: 0).text == "04.这是一个字幕")
    }

    /// 调用类别、tag 与队列预算在修改前拒绝；provider 自身返回坏类型则记录可选失败。
    @Test(.timeLimit(.minutes(1))) func invalidInputAndProviderMismatchAreObservable() async throws {
        let (player, tag) = try await textPlayer()
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        await #expect(throws: PAGError.invalidArgument("dynamicTag")) {
            try await player.updateContent(.hidden, forTag: "不存在")
        }
        await #expect(throws: PAGError.invalidArgument("dynamicContentKind")) {
            try await player.updateContent(.image(image), forTag: tag)
        }
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.setContentProvider { _ in .image(image) }
        let failure = await next(.failed, in: &events)
        #expect(failure?.detail?.contains("dynamicContentKind") == true)
        #expect(await player.contentComposition?.edits.texts.isEmpty == true)
        let multi = try await EditableFixtures.file()
        try await player.setComposition(multi.composition)
        await #expect(throws: PAGError.resourceLimitExceeded("pendingContentRequests")) {
            try await player.setContentProvider({ _ in .hidden },
                options: PAGContentOptions(maximumConcurrentRequests: 1, maximumPendingRequests: 3))
        }
    }

    /// 页面退出取消立即撤销供给；播放器释放不被挂起 provider 保活，订阅同时结束。
    @Test(.timeLimit(.minutes(1))) func cancellationAndReleaseDoNotRetainPlayer() async throws {
        let gate = ContentProviderTestGate()
        var entered = gate.requests.makeAsyncIterator()
        var player: PAGPlayer? = try await textPlayer().0
        weak let weakPlayer = player
        let log = try #require(await player?.contentState.log)
        var events = try #require(await player?.contentUpdates()).makeAsyncIterator()
        try await player?.setContentProvider { slot in await gate.value(slot) }
        _ = await entered.next()
        let controlTasks = try #require(await player?.contentState.running.values.map { $0 })
        await player?.cancelContentRequests()
        _ = await next(.cancelled, in: &events)
        // 取消门闩后，控制任务可能正在 actor 队列上做最后一次弱引用回调。
        // 等它们退出再检查释放；宿主 gate 仍未放行，因此这里也验证取消不等待宿主。
        for task in controlTasks { await task.value }
        player = nil
        // 控制任务仅弱引用播放器，释放不以宿主主动处理取消为前提。
        #expect(weakPlayer == nil)
        let ended = await events.next(isolation: #isolation)
        #expect(ended == nil)
        await gate.releaseAll(.hidden)
        #expect(log.snapshot.contains { $0.status == .cancelled })
    }

    /// 不合作旧请求继续计入十六个硬配额，重复更新不能无界创建宿主任务。
    @Test(.timeLimit(.minutes(1))) func abandonedProvidersRemainWithinHardBudget() async throws {
        let (player, tag) = try await textPlayer()
        let gate = ContentProviderTestGate()
        var entered = gate.requests.makeAsyncIterator()
        var events = await player.contentUpdates().makeAsyncIterator()
        for _ in 0..<16 {
            try await player.resolveContent(forTag: tag) { slot in await gate.value(slot) }
            _ = await entered.next()
        }
        try await player.resolveContent(forTag: tag) { slot in await gate.value(slot) }
        let failure = await next(.failed, in: &events)
        #expect(failure?.detail?.contains("outstandingContentProviders") == true)
        // 已就绪的内容不占宿主配额，恢复/隐藏仍能继续工作。
        try await player.updateContent(.hidden, forTag: tag)
        _ = await next(.applied, in: &events)
        await gate.releaseAll(.unchanged)
        #expect(await gate.totalRequests == 16)
    }

    /// 真实 TEXT04 提供一个可编辑源槽，不为测试编造 PAG 二进制。
    private func textPlayer() async throws -> (PAGPlayer, String) {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let player = PAGPlayer()
        try await player.setComposition(file.composition)
        return (player, try #require(file.contentSlots.first?.tag))
    }

    /// 按事件等待真实状态变化；测试分钟上限负责发现死锁，不通过固定 sleep 猜测完成。
    private func next(_ status: PAGContentEventStatus,
                      in iterator: inout AsyncStream<PAGContentEvent>.Iterator,
                      isolation: isolated (any Actor)? = #isolation) async -> PAGContentEvent? {
        while let event = await iterator.next(isolation: isolation) {
            if event.status == status { return event }
        }
        Issue.record("内容事件流结束前未收到 \(status)")
        return nil
    }
}

/// 故意忽略取消的宿主供给缝，用 continuation 精确控制旧请求何时返回。
private actor ContentProviderTestGate {
    /// 测试可观察的进入事件，不依赖后台线程调度顺序。
    nonisolated let requests: AsyncStream<PAGContentSlot>
    /// 只有 gate actor 追加进入事件。
    private let continuation: AsyncStream<PAGContentSlot>.Continuation
    /// 不响应 Task.cancel 的挂起调用，测试结束前显式恢复。
    private var waiting: [CheckedContinuation<DynamicContent, Never>] = []
    /// 累计真实进入宿主的次数，用于硬预算断言。
    private(set) var totalRequests = 0
    /// releaseAll 可能先于排队任务进入；后进入调用直接使用终态，避免测试自身制造泄漏。
    private var released: DynamicContent?

    /// 建立独立有界进入流；测试至多发起十六个挂起请求。
    init() {
        let pair = AsyncStream.makeStream(of: PAGContentSlot.self, bufferingPolicy: .bufferingNewest(32))
        requests = pair.stream
        continuation = pair.continuation
    }

    /// 记录一次调用并挂起，故意不装取消处理器来验证库自己的撤销边界。
    func value(_ slot: PAGContentSlot) async -> DynamicContent {
        totalRequests += 1
        continuation.yield(slot)
        if let released { return released }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// 一次恢复全部挂起宿主工作，释放测试占用的后台配额。
    func releaseAll(_ content: DynamicContent) {
        released = content
        let pending = waiting
        waiting.removeAll()
        for item in pending { item.resume(returning: content) }
    }
}
