import Foundation
import Testing
@testable import pag_swift

/// 提交临界区的完整身份校验与撤销；测试不创建离屏目标或伪称实际 GPU 验证。
struct PlaybackSubmissionGateTests {
    /// 每一个身份字段都参与校验，只有当前完整 token 能进入提交段。
    @Test func everyIdentityComponentIsRequired() throws {
        let gate = PlaybackSubmissionGate()
        let token = try token()
        #expect(gate.withPermission(for: token) { true } == nil)
        gate.allow(token)
        #expect(gate.withPermission(for: token) { 7 } == 7)
        let otherDocument = try DocumentIdentity(data: Data([2]))
        let variants = [
            PlaybackRequestToken(documentID: otherDocument, compositionRevision: token.compositionRevision,
                                 playbackEpoch: token.playbackEpoch, targetEpoch: token.targetEpoch,
                                 requestID: token.requestID),
            PlaybackRequestToken(documentID: token.documentID, compositionRevision: 2,
                                 playbackEpoch: token.playbackEpoch, targetEpoch: token.targetEpoch,
                                 requestID: token.requestID),
            PlaybackRequestToken(documentID: token.documentID, compositionRevision: 1,
                                 playbackEpoch: UUID(), targetEpoch: token.targetEpoch, requestID: token.requestID),
            PlaybackRequestToken(documentID: token.documentID, compositionRevision: 1,
                                 playbackEpoch: token.playbackEpoch, targetEpoch: UUID(), requestID: token.requestID),
            PlaybackRequestToken(documentID: token.documentID, compositionRevision: 1,
                                 playbackEpoch: token.playbackEpoch, targetEpoch: token.targetEpoch, requestID: UUID()),
        ]
        for variant in variants {
            #expect(!gate.permits(variant))
            #expect(gate.withPermission(for: variant) { true } == nil)
        }
        #expect(gate.permits(token))
    }

    /// 旧 render 的迟到取消只能撤销自己的 token，不能误伤已经安装的新工作。
    @Test func conditionalRevocationCannotCancelNewWork() throws {
        let gate = PlaybackSubmissionGate()
        let old = try token()
        let current = try token()
        gate.allow(old)
        gate.revoke(old)
        #expect(!gate.permits(old))
        gate.allow(current)
        gate.revoke(old)
        #expect(gate.permits(current))
        gate.revoke()
        #expect(gate.withPermission(for: current) { true } == nil)
    }

    /// 提交抛错仍释放锁并保留原错误，后续撤销与提交不会死锁。
    @Test func throwingSubmissionReleasesTheMutex() throws {
        let gate = PlaybackSubmissionGate()
        let token = try token()
        gate.allow(token)
        let error = PAGError.renderingFailure("encode")
        #expect(throws: error) {
            try gate.withPermission(for: token) { throw error }
        }
        gate.revoke()
        #expect(!gate.permits(token))
    }

    /// 待处理显式帧先取消后启动时不能重新获得许可；完成与取消只有一方消费旧许可。
    @Test func cancelledWaiterCannotBeReauthorized() throws {
        let gate = PlaybackSubmissionGate()
        let token = try token()
        let waiter = PlaybackRenderWaiter()
        gate.cancel(token, waiter: waiter)
        #expect(!gate.allow(token, unlessCancelled: waiter))
        #expect(!gate.claimCompletion(token))
        let next = try self.token()
        gate.allow(next)
        #expect(gate.claimCompletion(next))
        #expect(!gate.claimCompletion(next))
    }

    /// 构造各用例独占的请求身份，文档摘要只供身份比较，不冒充 PAG 字节夹具。
    private func token() throws -> PlaybackRequestToken {
        PlaybackRequestToken(documentID: try DocumentIdentity(data: Data([1])), compositionRevision: 1,
                             playbackEpoch: UUID(), targetEpoch: UUID(), requestID: UUID())
    }
}
