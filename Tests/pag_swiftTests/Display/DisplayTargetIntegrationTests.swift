import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实 GPU 配置和 CoreAnimation 层关系；沙箱无 GPU 时明确跳过，主机权限另行执行。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct DisplayTargetIntegrationTests {
    /// device 一次性转移到后台 owner，配置/挂载/resize按租约互斥，默认inactive不生成绘制请求。
    @MainActor @Test func configuresOnBackgroundExecutorAndMountsControlledLayer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = RenderOwner(device: device)
        let box = DisplayTargetBox()
        let parent = CALayer()
        let mutation = try #require(box.mailbox.beginMutation())
        let info = try await owner.prepareTarget(box, mutation: mutation)
        #expect(!info.isMainThread && !info.name.isEmpty && info.maximumBufferLength > 0)
        let geometry = try DisplayGeometry(size: PAGSize(width: 123, height: 45), scale: 2)
        #expect(box.mount(to: parent, mutation: mutation))
        #expect(box.resize(to: geometry, mutation: mutation))
        #expect(box.mailbox.finishMutation(mutation,
                    configuration: DisplayTargetConfiguration(geometry: geometry, isMounted: true)))
        #expect(parent.sublayers?.count == 1)
        #expect(parent.sublayers?.first?.frame == CGRect(x: 0, y: 0, width: 123, height: 45))
        #expect(parent.sublayers?.first?.contentsScale == 2)
        #expect(box.mailbox.acquireDrawing(for: mutation) == nil)
        let detach = try #require(box.mailbox.beginMutation())
        #expect(await box.mailbox.waitUntilIdle(for: detach))
        #expect(box.unmount(mutation: detach))
        #expect(box.mailbox.finishMutation(detach, configuration: DisplayTargetConfiguration(geometry: geometry)))
        #expect(parent.sublayers?.isEmpty != false)
        let remount = try #require(box.mailbox.beginMutation())
        #expect(box.mount(to: parent, mutation: remount))
        #expect(box.mailbox.finishMutation(remount,
                    configuration: DisplayTargetConfiguration(geometry: geometry, isMounted: true)))
        await box.shutdown()
        #expect(parent.sublayers?.isEmpty != false)
        #expect(box.mailbox.snapshot.isClosed)
    }

    /// 模拟未结束的平台租约时，异步关闭保持层挂载；归还之后才真正移除。
    @MainActor @Test func shutdownRemovesLayerOnlyAfterOutstandingLease() async throws {
        let pair = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        var events = pair.stream.makeAsyncIterator()
        let box = DisplayTargetBox(observe: { pair.continuation.yield($0) })
        let parent = CALayer()
        let mutation = try #require(box.mailbox.beginMutation())
        let geometry = try DisplayGeometry(size: PAGSize(width: 10, height: 10), scale: 1)
        #expect(box.mount(to: parent, mutation: mutation))
        #expect(box.mailbox.finishMutation(mutation,
                    configuration: DisplayTargetConfiguration(geometry: geometry, isMounted: true, isActive: true)))
        // 此用例只模拟平台访问存活，不在没有真实窗口时申请 drawable。
        let lease = try #require(box.mailbox.acquireDrawing(for: mutation))
        let shutdown = Task { @MainActor in await box.shutdown() }
        #expect(await events.next() == .waitingForClose)
        #expect(parent.sublayers?.count == 1)
        #expect(box.mailbox.acquireDrawing(for: mutation) == nil)
        box.mailbox.release(lease)
        await shutdown.value
        #expect(parent.sublayers?.isEmpty != false)
    }

    /// 已取消或过期的配置调用明确失败且不遗留租约，之后仍能配置当前事务。
    @MainActor @Test func cancelledAndStaleConfigurationReleaseOwnership() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = RenderOwner(device: device)
        let box = DisplayTargetBox()
        let old = try #require(box.mailbox.beginMutation())
        let current = try #require(box.mailbox.beginMutation())
        await #expect(throws: CancellationError.self) { try await owner.prepareTarget(box, mutation: old) }
        let cancelled = Task { try await owner.prepareTarget(box, mutation: current) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!box.mailbox.snapshot.hasLease)
        let info = try await owner.prepareTarget(box, mutation: current)
        #expect(!info.isMainThread)
        await box.shutdown()
    }
}
