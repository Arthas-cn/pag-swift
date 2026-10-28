import Foundation
import Testing
@testable import pag_swift

/// 通过 public loader 验证 LRU 行为和计费，淘汰后旧调用者的文件仍有效。
struct PAGLoaderCacheTests {
    /// 命中必须更新使用顺序；容量只容纳两份时，应淘汰最久未访问的文档。
    @Test func leastRecentlyUsedDocumentIsEvicted() async throws {
        let a = try variant(nameByte: 65)
        let b = try variant(nameByte: 66)
        let c = try variant(nameByte: 67)
        let measuring = try PAGLoader()
        _ = try await measuring.load(data: a)
        let perFile = await measuring.diagnostics.cachedBytes
        #expect(perFile > 0)
        let budget = perFile * 2
        let loader = try PAGLoader(cacheByteLimit: budget)
        let firstA = try await loader.load(data: a)
        let firstB = try await loader.load(data: b)
        #expect(try await loader.load(data: a).storage === firstA.storage)
        _ = try await loader.load(data: c)
        #expect(await loader.diagnostics.cachedFiles == 2)
        #expect(await loader.diagnostics.cachedBytes <= budget)
        #expect(try await loader.load(data: a).storage === firstA.storage)
        let secondB = try await loader.load(data: b)
        #expect(secondB.storage !== firstB.storage)
        #expect(firstB.composition.layers.first?.name == "Bhape Layer 1")
        #expect(await loader.diagnostics.cachedBytes <= budget)
    }

    /// 单文件大于留存预算时仍可正常返回，但后续请求不能命中被偷偷保留的条目。
    @Test func oversizedDocumentIsNotRetained() async throws {
        let loader = try PAGLoader(cacheByteLimit: 1)
        let data = try PAGFixtures.data(named: "red.pag")
        let a = try await loader.load(data: data)
        let b = try await loader.load(data: data)
        #expect(a.storage !== b.storage)
        #expect(await loader.diagnostics.cachedBytes == 0)
        #expect(await loader.diagnostics.cachedFiles == 0)
    }

    /// 已取消的请求即使可以命中缓存也必须抛取消，已有有效缓存仍保留。
    @Test func cancelledRequestCannotReturnCachedSuccess() async throws {
        let loader = try PAGLoader()
        let data = try PAGFixtures.data(named: "red.pag")
        let first = try await loader.load(data: data)
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: PAGFile.self) { group in
                group.cancelAll()
                group.addTask { try await loader.load(data: data) }
                for try await _ in group {}
            }
        }
        #expect(try await loader.load(data: data).storage === first.storage)
        #expect(await loader.diagnostics.flights == 0)
    }

    /// 只修改真实 red 的名称首字节，保持合法布局和相同存储体量，得到不同内容身份。
    private func variant(nameByte: UInt8) throws -> Data {
        var data = try PAGFixtures.data(named: "red.pag")
        data[106] = nameByte
        return data
    }
}
