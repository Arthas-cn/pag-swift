import Testing
@testable import pag_swift

/// 一次性完成门闩的顺序边界与并发竞争，防止 continuation 漏恢复或双恢复。
struct LoadWaiterTests {
    /// 解析先于 continuation 安装完成时，迟到等待者仍应收到一次成功。
    @Test func completionBeforeRegistrationIsRetained() async throws {
        let file = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "red.pag"))
        let waiter = LoadWaiter()
        #expect(waiter.resolve(.success(file)))
        #expect(!waiter.resolve(.success(file)))
        waiter.cancel()
        #expect(try await waiter.value().storage === file.storage)
    }

    /// 取消先于 continuation 安装时，迟到成功不能复活请求。
    @Test func cancellationBeforeRegistrationWins() async throws {
        let file = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "red.pag"))
        let waiter = LoadWaiter()
        waiter.cancel()
        #expect(!waiter.resolve(.success(file)))
        await #expect(throws: CancellationError.self) { try await waiter.value() }
    }

    /// 完成与取消并发竞争时，只接受实际赢得 Mutex 状态转换的一方。
    @Test func concurrentTerminalTransitionsHaveOneWinner() async throws {
        let file = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "red.pag"))
        let waiter = LoadWaiter()
        async let accepted = waiter.resolve(.success(file))
        async let cancelled: Void = waiter.cancel()
        let (didAccept, _) = await (accepted, cancelled)
        if didAccept { #expect(try await waiter.value().storage === file.storage) }
        else { await #expect(throws: CancellationError.self) { try await waiter.value() } }
    }
}
