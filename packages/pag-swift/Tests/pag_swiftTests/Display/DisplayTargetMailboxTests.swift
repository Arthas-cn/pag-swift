import Foundation
import Testing
@testable import pag_swift

/// 不借助平台对象验证租约与显示事务的互斥、撤销、排空和关闭。
@Suite(.timeLimit(.minutes(1)))
struct DisplayTargetMailboxTests {
    /// 没有布局/挂载/显式active任一条件时都不能取绘制租约，事务提交后只允许一份。
    @Test func drawingRequiresAllPresentationConditions() throws {
        let mailbox = DisplayTargetMailbox()
        #expect(mailbox.acquireDrawing(for: mailbox.snapshot.epoch) == nil)
        let geometry = try geometry()
        var configuration = DisplayTargetConfiguration()
        for step in 0..<3 {
            let mutation = try #require(mailbox.beginMutation())
            if step == 0 { configuration.geometry = geometry }
            if step == 1 { configuration.isMounted = true }
            if step == 2 { configuration.isActive = true }
            #expect(mailbox.finishMutation(mutation, configuration: configuration))
            let lease = mailbox.acquireDrawing(for: mutation)
            if step < 2 { #expect(lease == nil) }
            else {
                let actual = try #require(lease)
                #expect(actual.kind == .drawing(geometry))
                #expect(mailbox.acquireDrawing(for: mutation) == nil)
                #expect(mailbox.release(actual))
                #expect(!mailbox.release(actual))
            }
        }
    }

    /// 撤销立即让旧租约失效，但主层树变更必须等旧平台访问实际归还。
    @Test func mutationWaitsForRevokedLeaseToExit() async throws {
        let rig = DisplayMailboxRig()
        var events = rig.events.makeAsyncIterator()
        let epoch = try activate(rig.mailbox)
        let old = try #require(rig.mailbox.acquireDrawing(for: epoch))
        let mutation = try #require(rig.mailbox.beginMutation())
        #expect(!rig.mailbox.isCurrent(old))
        #expect(rig.mailbox.acquireMainMutation(for: mutation) == nil)
        #expect(rig.mailbox.acquireConfiguration(for: mutation) == nil)
        let waiting = Task { await rig.mailbox.waitUntilIdle(for: mutation) }
        #expect(await events.next() == .waitingForMutation(mutation))
        #expect(rig.mailbox.snapshot.hasLease && rig.mailbox.snapshot.waitingCount == 1)
        #expect(!rig.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration()))
        rig.mailbox.release(old)
        #expect(await waiting.value)
        let main = try #require(rig.mailbox.acquireMainMutation(for: mutation))
        #expect(rig.mailbox.acquireConfiguration(for: mutation) == nil)
        rig.mailbox.release(main)
        #expect(rig.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration()))
    }

    /// 新事务取消旧等待而不偷释放旧租约；最终只允许新事务提交。
    @Test func newerMutationSupersedesOldWaiter() async throws {
        let rig = DisplayMailboxRig()
        var events = rig.events.makeAsyncIterator()
        let epoch = try activate(rig.mailbox)
        let old = try #require(rig.mailbox.acquireDrawing(for: epoch))
        let first = try #require(rig.mailbox.beginMutation())
        let firstWait = Task { await rig.mailbox.waitUntilIdle(for: first) }
        #expect(await events.next() == .waitingForMutation(first))
        let second = try #require(rig.mailbox.beginMutation())
        #expect(await firstWait.value == false)
        #expect(rig.mailbox.snapshot.hasLease)
        let secondWait = Task { await rig.mailbox.waitUntilIdle(for: second) }
        #expect(await events.next() == .waitingForMutation(second))
        rig.mailbox.release(old)
        #expect(await secondWait.value)
        #expect(!rig.mailbox.finishMutation(first, configuration: DisplayTargetConfiguration()))
        #expect(rig.mailbox.finishMutation(second, configuration: DisplayTargetConfiguration()))
    }

    /// 主 actor 修改与后台配置租约严格互斥，释放错误身份不能绕过互斥。
    @Test func configurationAndMainAccessCannotOverlap() throws {
        let mailbox = DisplayTargetMailbox()
        let mutation = try #require(mailbox.beginMutation())
        let configuration = try #require(mailbox.acquireConfiguration(for: mutation))
        #expect(mailbox.acquireMainMutation(for: mutation) == nil)
        let fake = DisplayTargetLease(id: UUID(), epoch: mutation, kind: .configuration)
        #expect(!mailbox.release(fake))
        #expect(mailbox.isCurrent(configuration))
        mailbox.release(configuration)
        let main = try #require(mailbox.acquireMainMutation(for: mutation))
        #expect(mailbox.acquireConfiguration(for: mutation) == nil)
        mailbox.release(main)
        #expect(mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration()))
        #expect(mailbox.acquireMainMutation(for: mutation) == nil)
    }

    /// 永久关闭取消旧事务，却继续等剩余访问退出；取消清理任务也不能提前拆层。
    @Test func closeIsPermanentAndCleanupWaitsDespiteCancellation() async throws {
        let rig = DisplayMailboxRig()
        var events = rig.events.makeAsyncIterator()
        let epoch = try activate(rig.mailbox)
        let lease = try #require(rig.mailbox.acquireDrawing(for: epoch))
        let mutation = try #require(rig.mailbox.beginMutation())
        let waiting = Task { await rig.mailbox.waitUntilIdle(for: mutation) }
        #expect(await events.next() == .waitingForMutation(mutation))
        rig.mailbox.close()
        #expect(await waiting.value == false)
        let cleanup = Task { await rig.mailbox.waitUntilReleased() }
        #expect(await events.next() == .waitingForClose)
        cleanup.cancel()
        #expect(rig.mailbox.snapshot.hasLease)
        #expect(rig.mailbox.beginMutation() == nil)
        #expect(!rig.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration()))
        rig.mailbox.release(lease)
        await cleanup.value
        #expect(rig.mailbox.snapshot.isClosed && !rig.mailbox.snapshot.hasLease)
        #expect(rig.mailbox.snapshot.waitingCount == 0)
        #expect(rig.mailbox.acquireDrawing(for: rig.mailbox.snapshot.epoch) == nil)
        await rig.mailbox.waitUntilReleased()
    }

    /// 几何随租约捕获；新配置更新后旧代数无法获取新尺寸，旧值也不会被倒写。
    @Test func leaseCapturesGeometryAndRejectsOldEpoch() throws {
        let mailbox = DisplayTargetMailbox()
        let first = try activate(mailbox)
        let old = try #require(mailbox.acquireDrawing(for: first))
        mailbox.release(old)
        let second = try #require(mailbox.beginMutation())
        let geometry = try DisplayGeometry(size: PAGSize(width: 200, height: 100), scale: 3)
        let configuration = DisplayTargetConfiguration(geometry: geometry, isMounted: true, isActive: true)
        #expect(mailbox.finishMutation(second, configuration: configuration))
        #expect(mailbox.acquireDrawing(for: first) == nil)
        let current = try #require(mailbox.acquireDrawing(for: second))
        #expect(current.kind == .drawing(geometry))
        #expect(current.kind != old.kind)
        mailbox.release(current)
    }

    /// 最后同步提交只接受当前绘制租约，配置租约、外来身份和已撤销代数不会执行body。
    @Test func finalSubmissionRequiresCurrentDrawingLease() throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try activate(mailbox)
        let lease = try #require(mailbox.acquireDrawing(for: epoch))
        var count = 0
        #expect(mailbox.withDrawingPermission(for: lease) { count += 1; return 7 } == 7)
        let fake = DisplayTargetLease(id: UUID(), epoch: epoch, kind: lease.kind)
        #expect(mailbox.withDrawingPermission(for: fake) { count += 1; return 7 } == nil)
        let next = try #require(mailbox.beginMutation())
        #expect(mailbox.withDrawingPermission(for: lease) { count += 1; return 7 } == nil)
        mailbox.release(lease)
        let configuration = try #require(mailbox.acquireConfiguration(for: next))
        #expect(mailbox.withDrawingPermission(for: configuration) { count += 1; return 7 } == nil)
        mailbox.release(configuration)
        #expect(count == 1)
    }

    /// 建立合法小布局，仅供纯租约状态测试。
    private func geometry() throws -> DisplayGeometry {
        try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 2)
    }

    /// 通过真实事务进入允许呈现的值状态；不声称已有实际窗口或 GPU。
    private func activate(_ mailbox: DisplayTargetMailbox) throws -> UUID {
        let epoch = try #require(mailbox.beginMutation())
        let configuration = DisplayTargetConfiguration(geometry: try geometry(), isMounted: true, isActive: true)
        #expect(mailbox.finishMutation(epoch, configuration: configuration))
        return epoch
    }
}

/// 确定性观察 continuation 已安装的测试环境，不依赖 yield/sleep 轮询。
private struct DisplayMailboxRig: Sendable {
    /// 被测纯值信箱。
    let mailbox: DisplayTargetMailbox
    /// 独占的等待注册事件流。
    let events: AsyncStream<DisplayTargetEvent>

    /// 创建只属于一个用例的观察通道。
    init() {
        let pair = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        events = pair.stream
        mailbox = DisplayTargetMailbox(observe: { pair.continuation.yield($0) })
    }
}
