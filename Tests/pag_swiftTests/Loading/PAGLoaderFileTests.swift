import Darwin
import Foundation
import Testing
@testable import pag_swift

/// Public 载入、稳定文件快照、缓存身份和失败语义的真实资源集成测试。
struct PAGLoaderFileTests {
    /// URL/Data 的真实内容一致时共享同一解析存储，无扩展名文件也可以完整载入。
    @Test func urlAndDataShareVerifiedContent() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let temporary = try LoaderTemporaryFile(data: data)
        defer { temporary.remove() }
        let loader = try PAGLoader()
        let fromURL = try await loader.load(from: temporary.url)
        let fromData = try await loader.load(data: data)
        #expect(fromURL.storage === fromData.storage)
        #expect(fromURL.composition.duration.microseconds == 15_000_000)
        #expect(await loader.diagnostics.cachedFiles == 1)
    }

    /// 内容改写后即使恢复相同长度/mtime，下一次独立载入仍必须发现新摘要。
    @Test func restoredMetadataCannotHideChangedContent() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        let temporary = try LoaderTemporaryFile(data: data)
        defer { temporary.remove() }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.url.path)
        let date = try #require(attributes[.modificationDate] as? Date)
        let loader = try PAGLoader()
        let first = try await loader.load(from: temporary.url)
        data[106] = 84
        try data.write(to: temporary.url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temporary.url.path)
        let changed = try await loader.load(from: temporary.url)
        #expect(changed.storage !== first.storage)
        #expect(changed.composition.layers.first?.name == "Thape Layer 1")
        #expect(first.composition.layers.first?.name == "Shape Layer 1")
    }

    /// 普通缓存命中、uncached、reload 和清理各自遵循留存合同。
    @Test func cachePoliciesRemainDistinct() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let loader = try PAGLoader()
        let first = try await loader.load(data: data)
        let hit = try await loader.load(data: data)
        #expect(first.storage === hit.storage)
        let independent = try await loader.load(data: data, policy: .uncached)
        #expect(independent.storage !== first.storage)
        #expect(try await loader.load(data: data).storage === first.storage)
        let reloaded = try await loader.load(data: data, policy: .reload)
        #expect(reloaded.storage !== first.storage)
        #expect(try await loader.load(data: data).storage === reloaded.storage)
        await loader.removeCachedFiles()
        #expect(await loader.diagnostics.cachedBytes == 0)
        #expect(try await loader.load(data: data).storage !== reloaded.storage)
        #expect(first.composition.layers.count == 1)
    }

    /// 零缓存预算禁用留存但不妨碍载入；负预算初始化失败。
    @Test func disabledCacheDoesNotRetain() async throws {
        #expect(throws: PAGError.invalidArgument("cacheByteLimit")) { try PAGLoader(cacheByteLimit: -1) }
        let data = try PAGFixtures.data(named: "red.pag")
        let loader = try PAGLoader(cacheByteLimit: 0)
        let first = try await loader.load(data: data)
        let second = try await loader.load(data: data)
        #expect(first.storage !== second.storage)
        #expect(await loader.diagnostics.cachedFiles == 0)
    }

    /// 非本地 URL、缺失文件和目录分别按 URL/IO 合同失败，不启动网络请求。
    @Test func invalidSourcesReportStableErrors() async throws {
        let loader = try PAGLoader()
        let remote = try #require(URL(string: "https://example.invalid/red.pag"))
        await #expect(throws: PAGError.unsupportedURL) { try await loader.load(from: remote) }
        let temporary = try LoaderTemporaryFile(data: PAGFixtures.data(named: "red.pag"))
        defer { temporary.remove() }
        await #expect(throws: PAGError.ioFailure(domain: NSPOSIXErrorDomain, code: Int(ENOENT))) {
            try await loader.load(from: temporary.directory.appendingPathComponent("missing"))
        }
        await #expect(throws: PAGError.ioFailure(domain: NSPOSIXErrorDomain, code: Int(EINVAL))) {
            try await loader.load(from: temporary.directory)
        }
    }

    /// MP4 只能走未来素材入口；公开 PAGLoader 必须按内容拒绝，失败不能写缓存。
    @Test func mp4DoesNotBecomePAG() async throws {
        let loader = try PAGLoader()
        let data = try PAGFixtures.data(named: "game.mp4")
        await #expect(throws: PAGError.invalidFile(reason: "invalidMagic", offset: 0)) { try await loader.load(data: data) }
        #expect(await loader.diagnostics.cachedFiles == 0)
    }

    /// 读取完成后、身份核对前原子替换路径，必须检测 inode 改变并拒绝混合来源。
    @Test func replacementDuringReadIsDetected() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let temporary = try LoaderTemporaryFile(data: data)
        defer { temporary.remove() }
        await #expect(throws: PAGError.sourceChanged) {
            try await StableFileReader.read(from: temporary.url, limits: .standard) {
                try data.write(to: temporary.url, options: .atomic)
            }
        }
    }

    /// 文件预算在读取大块字节之前生效，不能先读完再检查长度。
    @Test func fileReadHonorsInputBudget() async throws {
        let temporary = try LoaderTemporaryFile(data: PAGFixtures.data(named: "red.pag"))
        defer { temporary.remove() }
        let loader = try PAGLoader(limits: PAGLoadLimits(maximumFileBytes: 164))
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFileBytes")) { try await loader.load(from: temporary.url) }
    }
}
