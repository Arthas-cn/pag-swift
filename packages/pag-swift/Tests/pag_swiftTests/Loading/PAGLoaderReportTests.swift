import Foundation
import Testing
@testable import pag_swift

/// 对外报告必须与真实缓存、取消和编辑隔离一致，不能把缓存命中标成免 IO。
@Suite(.timeLimit(.minutes(1)))
struct PAGLoaderReportTests {
    /// 同一文件第二次免解析但仍读盘和摘要，且返回完整身份和只读占用。
    @Test func hitStillMeasuresReadAndDigest() async throws {
        let temporary = try LoaderTemporaryFile(data: PAGFixtures.data(named: "red.pag"))
        defer { temporary.remove() }
        let loader = try PAGLoader()
        let first = try await loader.loadWithReport(from: temporary.url)
        let second = try await loader.loadWithReport(from: temporary.url)
        #expect(first.file.storage === second.file.storage)
        #expect(first.report.cache == .miss)
        #expect(second.report.cache == .hit)
        #expect(first.report.parseSeconds != nil)
        #expect(second.report.parseSeconds == nil)
        #expect(second.report.readSeconds != nil)
        #expect(second.report.digestSeconds != nil)
        #expect(second.report.documentIdentity?.count == 64)
        #expect(second.report.documentIdentity == first.report.documentIdentity)
        #expect(second.report.sourcePath == temporary.url.path)
        #expect(second.report.statistics.hits == 1)
        #expect(second.report.statistics.misses == 1)
        #expect(second.report.statistics.parses == 1)
        #expect(second.report.statistics.cachedFiles == 1)
        let decoded = try JSONDecoder().decode(PAGLoadReport.self, from: JSONEncoder().encode(second.report))
        #expect(decoded.id == second.report.id)
    }

    /// 共享请求看到同一次解析耗时和自己的等待时间，取消另一个请求不破坏结果。
    @Test func sharedTimingAndIndependentCancellation() async throws {
        let rig = try LoaderTestRig()
        let data = try PAGFixtures.data(named: "red.pag")
        var events = rig.events.makeAsyncIterator()
        var ready = rig.probe.ready.makeAsyncIterator()
        let first = Task { try await rig.loader.loadWithReport(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 1)
        let second = Task { try await rig.loader.loadWithReport(data: data) }
        try await LoaderTestRig.wait(for: .joined(2), in: &events)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await rig.probe.gate.release(1)
        let result = try await second.value
        #expect(result.report.cache == .shared)
        #expect(result.report.parseSeconds != nil)
        #expect(result.report.sharedWaitSeconds != nil)
        #expect(result.report.readSeconds == nil)
        #expect(result.report.statistics.sharedRequests == 1)
        #expect(result.report.statistics.parses == 1)
        #expect(result.report.statistics.cancellations == 1)
        let reports = await rig.loader.recentReports
        #expect(reports.first?.status == .cancelled)
        #expect(reports.first?.parseSeconds == nil)
        #expect(reports.last?.status == .succeeded)
    }

    /// 实际解析失败有错误和摘要；尚未读取便取消的阶段不可用，不能填零冒充测量。
    @Test func failedAndCancelledReportsRemainDistinct() async throws {
        let loader = try PAGLoader()
        await #expect(throws: (any Error).self) { try await loader.loadWithReport(data: Data([1, 2, 3])) }
        let failure = try #require(await loader.recentReports.last)
        #expect(failure.status == .failed)
        #expect(failure.documentIdentity != nil)
        #expect(failure.parseSeconds != nil)
        #expect(failure.error != nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.loadWithReport(data: Data())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = try #require(await loader.recentReports.last)
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.cache == .unavailable)
        #expect(cancelled.documentIdentity == nil)
        #expect(cancelled.digestSeconds == nil)
        #expect(cancelled.statistics.failures == 1)
        #expect(cancelled.statistics.cancellations == 1)
    }

    /// 淘汰计数只包含容量回收；reload 和清空分别计一次失效，历史报告有硬上限。
    @Test func evictionInvalidationAndHistoryAreBounded() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let measuring = try PAGLoader()
        let first = try await measuring.loadWithReport(data: data)
        let loader = try PAGLoader(cacheByteLimit: first.report.statistics.cachedBytes)
        _ = try await loader.load(data: data)
        var variant = data
        // 真实夹具名称字节，沿用既有缓存用例的有证据变体，不制造未知 PAG 布局。
        variant[106] = 65
        _ = try await loader.load(data: variant)
        #expect(await loader.statistics.evictions == 1)
        _ = try await loader.load(data: variant, policy: .reload)
        await loader.removeCachedFiles()
        #expect(await loader.statistics.invalidations == 2)
        #expect(await loader.statistics.evictions == 1)
        #expect(await loader.statistics.cachedBytes == 0)
        for _ in 0..<130 { _ = try await loader.load(data: data) }
        #expect(await loader.recentReports.count == 128)
        let statistics = await loader.statistics
        #expect(statistics.cachedBytes <= statistics.byteLimit)
    }

    /// 零预算仍解析但不留存，uncached 明确报告旁路，不能误计为缓存命中。
    @Test func zeroBudgetAndBypassReportActualWork() async throws {
        let loader = try PAGLoader(cacheByteLimit: 0)
        let data = try PAGFixtures.data(named: "red.pag")
        _ = try await loader.loadWithReport(data: data)
        let second = try await loader.loadWithReport(data: data)
        let bypassed = try await loader.loadWithReport(data: data, policy: .uncached)
        #expect(second.report.cache == .miss)
        #expect(bypassed.report.cache == .bypassed)
        #expect(bypassed.report.statistics.parses == 3)
        #expect(bypassed.report.statistics.misses == 2)
        #expect(bypassed.report.statistics.cachedFiles == 0)
    }

    /// 两个播放器复用同一解析结果时，各自按 tag 替换文字；再次命中仍返回原始文字。
    @Test func sharedParseDoesNotSharePlayerEdits() async throws {
        let loader = try PAGLoader()
        let data = try PAGFixtures.data(named: "editing/TEXT04.pag")
        let file = try await loader.load(data: data)
        let other = try await loader.load(data: data)
        #expect(file.storage === other.storage)
        let slot = try #require(file.contentSlots.first(where: { $0.kind == .text }))
        let original = try file.composition.text(at: slot.sourceIndex).text
        let a = PAGPlayer(), b = PAGPlayer()
        try await a.setComposition(file.composition)
        try await b.setComposition(other.composition)
        var eventsA = await a.contentUpdates().makeAsyncIterator()
        var eventsB = await b.contentUpdates().makeAsyncIterator()
        try await a.updateContent(.text("甲", layout: .automatic), forTag: slot.tag)
        try await b.updateContent(.text("乙", layout: .automatic), forTag: slot.tag)
        while let event = await eventsA.next(), event.status != .applied {}
        while let event = await eventsB.next(), event.status != .applied {}
        #expect(try await a.contentComposition?.text(at: slot.sourceIndex).text == "甲")
        #expect(try await b.contentComposition?.text(at: slot.sourceIndex).text == "乙")
        #expect(try await loader.load(data: data).composition.text(at: slot.sourceIndex).text == original)
    }
}
