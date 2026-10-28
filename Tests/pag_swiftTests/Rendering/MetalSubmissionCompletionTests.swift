import Testing
@testable import pag_swift

/// 系统回调与提交前放弃竞争时的一次性清理，不依赖GPU回调时机或真实sleep。
struct MetalSubmissionCompletionTests {
    /// GPU失败无论在commit确认前后到达，都保留错误并恰好释放一次租约，迟到成功不能覆盖失败。
    @Test(arguments: [false, true]) func gpuFailureReleasesLeaseOnce(callbackBeforeCommit: Bool) async throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        let lease = try #require(mailbox.acquireConfiguration(for: epoch))
        let error = PAGError.renderingFailure("controlledGPUFailure")
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            let completion = MetalSubmissionCompletion(continuation: continuation, mailbox: mailbox, lease: lease)
            if callbackBeforeCommit {
                completion.gpuFinished(.failure(error))
                #expect(mailbox.snapshot.hasLease)
                completion.didCommit()
            } else {
                completion.didCommit()
                completion.gpuFinished(.failure(error))
            }
            #expect(!mailbox.snapshot.hasLease)
            // 后续配置已经取得新租约：重复GPU回调不能把新拥有者的访问槽一并归还。
            let next = mailbox.acquireConfiguration(for: epoch)
            #expect(next != nil)
            completion.gpuFinished(.success(true))
            #expect(mailbox.snapshot.hasLease)
            if let next { #expect(mailbox.release(next)) }
        }
        #expect(throws: error) { try result.get() }
        #expect(!mailbox.snapshot.hasLease)
    }

    /// 取消先完成后，迟到GPU结果既不能恢复第二次，也不能归还随后新帧持有的租约。
    @Test func cancellationAndLateGPUCallbackFinishOnlyOnce() async throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        let geometry = try DisplayGeometry(size: PAGSize(width: 10, height: 10), scale: 1)
        #expect(mailbox.finishMutation(epoch, configuration: DisplayTargetConfiguration(
            geometry: geometry, isMounted: true, isActive: true)))
        let lease = try #require(mailbox.acquireDrawing(for: epoch))
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            let completion = MetalSubmissionCompletion(continuation: continuation, mailbox: mailbox, lease: lease)
            #expect(completion.abandon(.failure(CancellationError())))
            let later = mailbox.acquireDrawing(for: epoch)
            #expect(later != nil)
            completion.gpuFinished(.success(true))
            #expect(mailbox.snapshot.hasLease)
            if let later { #expect(mailbox.release(later)) }
        }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!mailbox.snapshot.hasLease)
    }

    /// GPU成功先完成后，随后清理不能用失败覆盖成功，租约仍恰好归还一次。
    @Test func completedGPUResultCannotBeOverwrittenByCleanup() async throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        let lease = try #require(mailbox.acquireConfiguration(for: epoch))
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            let completion = MetalSubmissionCompletion(continuation: continuation, mailbox: mailbox, lease: lease)
            completion.didCommit()
            #expect(!completion.abandon(.failure(CancellationError())))
            #expect(mailbox.snapshot.hasLease)
            completion.gpuFinished(.success(true))
            #expect(!completion.abandon(.failure(PAGError.renderingFailure("lateCleanup"))))
        }
        #expect(try result.get() && !mailbox.snapshot.hasLease)
    }

    /// GPU先回调时只存结果，owner离开提交作用域后确认才归还租约，避免同线程回调递归取锁。
    @Test func earlyCallbackWaitsForCommitScopeToExit() async throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        let lease = try #require(mailbox.acquireConfiguration(for: epoch))
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            let completion = MetalSubmissionCompletion(continuation: continuation, mailbox: mailbox, lease: lease)
            completion.gpuFinished(.success(true))
            #expect(mailbox.snapshot.hasLease)
            completion.didCommit()
            #expect(!mailbox.snapshot.hasLease)
            completion.gpuFinished(.failure(PAGError.renderingFailure("duplicateCallback")))
        }
        #expect(try result.get())
    }

    /// 未提交buffer的系统回调先到时仍由owner决定放弃，不能将它误认为已经成功显示。
    @Test func uncommittedCallbackDoesNotOverrideAbandonment() async throws {
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        let lease = try #require(mailbox.acquireConfiguration(for: epoch))
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            let completion = MetalSubmissionCompletion(continuation: continuation, mailbox: mailbox, lease: lease)
            completion.gpuFinished(.failure(PAGError.renderingFailure("uncommittedBuffer")))
            #expect(completion.abandon(.failure(CancellationError())))
            completion.didCommit()
        }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!mailbox.snapshot.hasLease)
    }
}
