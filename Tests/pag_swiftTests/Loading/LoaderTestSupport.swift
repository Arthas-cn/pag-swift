import Foundation
import Testing
@testable import pag_swift

/// 每个用例独占的临时目录，保存真实 PAG 字节的副本，不改 resources 原件。
struct LoaderTemporaryFile: Sendable {
    /// 用例唯一目录，清理时只删除此目录。
    let directory: URL
    /// 故意没有扩展名，以验证入口按内容判断。
    let url: URL

    /// 将给定真实内容写到唯一临时路径，IO 失败直接使测试失败。
    init(data: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pag-loader-\(UUID().uuidString)")
        url = directory.appendingPathComponent("real-pag-without-extension")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// 删除本用例目录；清理失败记录为测试问题，不掩盖环境遗留。
    func remove() {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("临时文件清理失败：\(error)") }
    }
}

/// 可预先放行的确定性暂停点；故意不观察取消，以模拟取消后仍完成的底层操作。
actor LoaderTestGate {
    /// 尚在等待的序号及 continuation，每个序号最多登记一次。
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    /// release 早于 wait 时保留的放行序号。
    private var released: Set<Int> = []

    /// 暂停当前调用直到该序号放行；不依赖线程调度或真实时间。
    func wait(_ index: Int) async {
        if released.remove(index) != nil { return }
        await withCheckedContinuation { pending[index] = $0 }
    }

    /// 恢复指定序号；尚未进入时记录许可，避免先通知后等待的竞态。
    func release(_ index: Int) {
        if let continuation = pending.removeValue(forKey: index) { continuation.resume() }
        else { released.insert(index) }
    }
}

/// 对真实完整解码计数并在结果返回前暂停，专门检验 loader 对迟到结果的处理。
actor LoaderDecodeProbe {
    /// 按实际解码调用顺序递增，便于测试精确放行旧/新 flight。
    private(set) var count = 0
    /// 解码结果发布前的暂停点。
    let gate = LoaderTestGate()
    /// 真实解码完成且即将暂停的序号流；测试只在这个明确暂停点后制造竞态。
    let ready: AsyncStream<Int>
    /// 序号流的生产端，只由此 actor 发出。
    private let signal: AsyncStream<Int>.Continuation

    /// 创建本探针独占的事件流，不与其他测试共享状态。
    init() {
        let pair = AsyncStream.makeStream(of: Int.self)
        ready = pair.stream
        signal = pair.continuation
    }

    /// 解码真实快照后等待；返回时故意不自行检查取消，生产 loader 必须补上该检查。
    func decode(_ snapshot: LoadSnapshot, limits: PAGLoadLimits) async throws -> PAGFile {
        count += 1
        let index = count
        let file = try await PAGSceneDecoder.decode(snapshot.data, limits: limits, identity: snapshot.identity)
        signal.yield(index)
        await gate.wait(index)
        return file
    }
}

/// 一套独立 loader、真实解码暂停器和生命周期记录，不依赖全局 singleton。
struct LoaderTestRig {
    /// 被测试的真实 actor。
    let loader: PAGLoader
    /// 控制实际完整解码返回时间。
    let probe: LoaderDecodeProbe
    /// 共享等待者数量及 flight 完成事件，只有当前测试消费。
    let events: AsyncStream<LoaderEvent>

    /// 在 IO/解码边界注入控制，不替换场景或缓存实现。
    init(cacheByteLimit: Int = 67_108_864) throws {
        let probe = LoaderDecodeProbe()
        self.probe = probe
        let pair = AsyncStream.makeStream(of: LoaderEvent.self)
        events = pair.stream
        var operations = LoaderOperations()
        operations.decode = { try await probe.decode($0, limits: $1) }
        operations.observe = { pair.continuation.yield($0) }
        loader = try PAGLoader(cacheByteLimit: cacheByteLimit, operations: operations)
    }

    /// 消费到指定事件，不用 Task.sleep 或调度概率判断内部状态。
    static func wait(for expected: LoaderEvent, in iterator: inout AsyncStream<LoaderEvent>.Iterator,
                     isolation: isolated (any Actor)? = #isolation) async throws {
        // 迭代器只由调用测试持有；把调用方隔离显式传给 next，不能发送 inout 状态到另一域。
        while let event = await iterator.next(isolation: isolation) {
            if event == expected { return }
        }
        throw CancellationError()
    }
}

/// 准备阶段的序号分配器，避免测试用共享可变计数器制造数据竞争。
actor LoaderRequestCounter {
    /// 已分配的调用序号。
    private var count = 0

    /// 返回从一开始递增的序号；测试请求数量很小，不依赖时间戳。
    func next() -> Int {
        count += 1
        return count
    }
}
