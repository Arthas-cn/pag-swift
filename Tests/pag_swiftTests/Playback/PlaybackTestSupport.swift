import Foundation
import Synchronization
import Testing
@testable import pag_swift

/// 每个测试独占的可注入时钟，同步读取不依赖 actor 调度顺序。
final class PlaybackTestClock: Sendable {
    /// 用例指定的单调微秒值。
    private let time = Mutex<UInt64>(0)

    /// 读取当前注入时刻，不推进真实时间。
    func now() -> UInt64 { time.withLock { $0 } }
    /// 由测试显式推进；合法测试使用非递减时间戳。
    func set(_ value: UInt64) { time.withLock { $0 = value } }
}

/// 可控完成的提交协议替身，故意忽略任务取消以模拟已提交 GPU 的迟到回调。
actor PlaybackSubmissionProbe: PlaybackSubmitting {
    /// 已开始的请求流；只有当前测试消费，不用 sleep 等待调度。
    let requests: AsyncStream<PlaybackFrameRequest>
    /// 请求流的生产端，在 continuation 安装后才发布。
    private let signal: AsyncStream<PlaybackFrameRequest>.Continuation
    /// 等待测试放行的实际协议调用，每个 requestID 一份。
    private var pending: [UUID: CheckedContinuation<PlaybackSubmission, any Error>] = [:]
    /// 已进入提交协议的累计次数，用于验证合并而不是无界创建任务。
    private(set) var count = 0

    /// 创建独占事件流，不提供真实 GPU 能力。
    init() {
        let pair = AsyncStream.makeStream(of: PlaybackFrameRequest.self)
        requests = pair.stream
        signal = pair.continuation
    }

    /// 安装可控暂停点；返回 submitted 仅测试控制器合同，不能作为画面验收。
    func submit(_ request: PlaybackFrameRequest) async throws -> PlaybackSubmission {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.token.requestID] = continuation
            signal.yield(request)
        }
    }

    /// 内容返回统一根采样时间，清屏返回独立结果；允许故意在取消后放行旧结果。
    func complete(_ request: PlaybackFrameRequest) throws {
        if let scene = request.scene {
            let time = try SceneTiming.root(at: request.time, in: scene.composition.storage).representedTime
            resolve(request, result: .success(.submitted(time)))
        } else { resolve(request, result: .success(.cleared)) }
    }

    /// 显式放行成功、不可用或失败，每个暂停点必须且只能结束一次。
    func resolve(_ request: PlaybackFrameRequest, result: Result<PlaybackSubmission, any Error>) {
        guard let continuation = pending.removeValue(forKey: request.token.requestID) else {
            Issue.record("提交暂停点不存在或已恢复")
            return
        }
        continuation.resume(with: result)
    }
}

/// 控制器、注入时钟、提交暂停点和诊断流的一套独立测试环境。
struct PlaybackTestRig: Sendable {
    /// 被测真实 actor。
    let controller: PAGPlayer
    /// 控制后台协议的完成顺序。
    let probe: PlaybackSubmissionProbe
    /// 控制操作与 tick 共用的时间原点。
    let clock: PlaybackTestClock
    /// 等待控制器完成状态写回或订阅清理的事件流。
    let events: AsyncStream<PlaybackEvent>

    /// 可另行注入场景准备暂停点；默认仍使用真实 PreparedScene 准备。
    init(prepare: (@Sendable (PAGComposition, PreparedScene?) async throws -> PreparedScene)? = nil) {
        let clock = PlaybackTestClock()
        let probe = PlaybackSubmissionProbe()
        let pair = AsyncStream.makeStream(of: PlaybackEvent.self)
        var operations = PlaybackOperations()
        operations.now = { clock.now() }
        operations.observe = { pair.continuation.yield($0) }
        if let prepare { operations.prepare = prepare }
        self.clock = clock
        self.probe = probe
        events = pair.stream
        controller = PAGPlayer(submitter: probe, operations: operations)
    }

    /// 等到完整状态写回事件，避免把协议返回误当成 controller 已消费结果。
    static func wait(for event: PlaybackEvent, in iterator: inout AsyncStream<PlaybackEvent>.Iterator,
                     isolation: isolated (any Actor)? = #isolation) async throws {
        while let value = await iterator.next(isolation: isolation) {
            if value == event { return }
        }
        throw CancellationError()
    }

    /// 从仓库真实 red.pag 构造有完整验证的场景，不造二进制格式夹具。
    static func composition() async throws -> PAGComposition {
        try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag")).composition
    }
}

/// 真实场景准备之后的确定性暂停点，验证可重入安装事务与调用者取消。
actor PlaybackPreparationProbe {
    /// 已准备完成的序号，测试收到后才开始竞争操作。
    let ready: AsyncStream<Int>
    /// 序号生产端。
    private let signal: AsyncStream<Int>.Continuation
    /// 放行已经准备好的不可变结果。
    let gate = LoaderTestGate()
    /// 每次独立调用的序号。
    private var count = 0
    /// 已在暂停点之后观察到取消的工作序号，证明撤销到达真实 worker。
    private(set) var cancelled: Set<Int> = []

    /// 创建当前用例独占的暂停器。
    init() {
        let pair = AsyncStream.makeStream(of: Int.self)
        ready = pair.stream
        signal = pair.continuation
    }

    /// 先执行真实后台准备，再等待；迟到返回不额外检查取消，交给 controller 校验。
    func prepare(_ composition: PAGComposition, reusing previous: PreparedScene?) async throws -> PreparedScene {
        count += 1
        let index = count
        let prepared = try await PreparedScene.prepare(composition, reusing: previous)
        signal.yield(index)
        await gate.wait(index)
        if Task.isCancelled { cancelled.insert(index) }
        return prepared
    }
}
