import Foundation
import Testing
@testable import pag_swift

/// 用明确暂停点验证共享、取消与撤销代数；所有后台任务在用例内放行或取消收尾。
@Suite(.timeLimit(.minutes(1)))
struct PAGLoaderConcurrencyTests {
    /// 一个等待者取消应立即结束自身，共享解析继续服务另一等待者且只解码一次。
    @Test func cancellationIsIndependent() async throws {
        let rig = try LoaderTestRig()
        let data = try PAGFixtures.data(named: "red.pag")
        var events = rig.events.makeAsyncIterator()
        var ready = rig.probe.ready.makeAsyncIterator()
        let first = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 1)
        let second = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(2), in: &events)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await rig.loader.diagnostics.waiters == 1)
        await rig.probe.gate.release(1)
        let remaining = try await second.value
        #expect(await rig.probe.count == 1)
        #expect(try await rig.loader.load(data: data).storage === remaining.storage)
        #expect(await rig.loader.diagnostics.flights == 0)
    }

    /// 最后等待者离开会撤销 flight；忽略取消的旧结果不得污染新任务或缓存。
    @Test func lastCancellationDiscardsLateResult() async throws {
        let rig = try LoaderTestRig()
        let data = try PAGFixtures.data(named: "red.pag")
        var events = rig.events.makeAsyncIterator()
        var ready = rig.probe.ready.makeAsyncIterator()
        let old = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 1)
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await rig.loader.diagnostics.flights == 0)
        let current = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 2)
        await rig.probe.gate.release(2)
        let newFile = try await current.value
        await rig.probe.gate.release(1)
        try await LoaderTestRig.wait(for: .discarded, in: &events)
        #expect(try await rig.loader.load(data: data).storage === newFile.storage)
        #expect(await rig.probe.count == 2)
    }

    /// 清理与 reload 都允许旧调用者完成，但新代先完成时旧结果不能覆盖缓存。
    @Test(arguments: [false, true])
    func invalidationRejectsLateWriteback(_ reload: Bool) async throws {
        let rig = try LoaderTestRig()
        let data = try PAGFixtures.data(named: "red.pag")
        var events = rig.events.makeAsyncIterator()
        var ready = rig.probe.ready.makeAsyncIterator()
        let old = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 1)
        if !reload { await rig.loader.removeCachedFiles() }
        let current = Task { try await rig.loader.load(data: data, policy: reload ? .reload : .useCache) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 2)
        await rig.probe.gate.release(2)
        let newFile = try await current.value
        await rig.probe.gate.release(1)
        let oldFile = try await old.value
        #expect(oldFile.storage !== newFile.storage)
        #expect(try await rig.loader.load(data: data).storage === newFile.storage)
        #expect(await rig.loader.diagnostics.cachedFiles == 1)
    }

    /// uncached 即使与相同内容请求重叠也独立解析，完成后不能替换普通请求的缓存。
    @Test func uncachedDoesNotJoinOrWrite() async throws {
        let rig = try LoaderTestRig()
        let data = try PAGFixtures.data(named: "red.pag")
        var events = rig.events.makeAsyncIterator()
        var ready = rig.probe.ready.makeAsyncIterator()
        let independent = Task { try await rig.loader.load(data: data, policy: .uncached) }
        #expect(await ready.next() == 1)
        #expect(await rig.loader.diagnostics.flights == 0)
        let shared = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 2)
        await rig.probe.gate.release(2)
        let sharedFile = try await shared.value
        await rig.probe.gate.release(1)
        let independentFile = try await independent.value
        #expect(independentFile.storage !== sharedFile.storage)
        #expect(try await rig.loader.load(data: data).storage === sharedFile.storage)
        #expect(await rig.probe.count == 2)
    }

    /// 禁用留存不禁用重叠请求合并；两个等待者仍应共享一次解析结果。
    @Test func zeroCacheBudgetStillSharesFlight() async throws {
        let rig = try LoaderTestRig(cacheByteLimit: 0)
        let data = try PAGFixtures.data(named: "red.pag")
        var events = rig.events.makeAsyncIterator()
        var ready = rig.probe.ready.makeAsyncIterator()
        let first = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(1), in: &events)
        #expect(await ready.next() == 1)
        let second = Task { try await rig.loader.load(data: data) }
        try await LoaderTestRig.wait(for: .joined(2), in: &events)
        await rig.probe.gate.release(1)
        let a = try await first.value
        let b = try await second.value
        #expect(a.storage === b.storage)
        #expect(await rig.probe.count == 1)
        #expect(await rig.loader.diagnostics.cachedBytes == 0)
    }

    /// 清理覆盖仍在准备的内存请求，URL reload 覆盖同来源尚未返回的读取快照。
    @Test(arguments: [false, true])
    func invalidationIncludesSnapshotPreparation(_ reloadURL: Bool) async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let temporary = try LoaderTemporaryFile(data: data)
        defer { temporary.remove() }
        let counter = LoaderRequestCounter()
        let gate = LoaderTestGate()
        let pair = AsyncStream.makeStream(of: Int.self)
        var events = pair.stream.makeAsyncIterator()
        var operations = LoaderOperations()
        operations.prepare = { data, limits in
            let snapshot = try await LoadSnapshot.prepare(data: data, limits: limits)
            let index = await counter.next()
            if index == 1 {
                pair.continuation.yield(index)
                await gate.wait(index)
            }
            return snapshot
        }
        operations.read = { url, limits in
            let snapshot = try await StableFileReader.read(from: url, limits: limits)
            let index = await counter.next()
            if index == 1 {
                pair.continuation.yield(index)
                await gate.wait(index)
            }
            return snapshot
        }
        let loader = try PAGLoader(operations: operations)
        let fetch: @Sendable (PAGLoadPolicy) async throws -> PAGFile = { policy in
            if reloadURL { return try await loader.load(from: temporary.url, policy: policy) }
            return try await loader.load(data: data, policy: policy)
        }
        let old = Task { try await fetch(.useCache) }
        #expect(await events.next() == 1)
        if !reloadURL { await loader.removeCachedFiles() }
        let current = try await fetch(reloadURL ? .reload : .useCache)
        await gate.release(1)
        let previous = try await old.value
        #expect(previous.storage !== current.storage)
        #expect(try await fetch(.useCache).storage === current.storage)
    }
}
