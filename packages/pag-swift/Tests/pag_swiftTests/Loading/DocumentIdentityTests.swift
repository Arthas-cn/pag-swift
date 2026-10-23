import CryptoKit
import Foundation
import Testing
@testable import pag_swift

/// 内容身份的分段摘要必须与原有完整拼接字节一致，不能改变缓存键语义。
struct DocumentIdentityTests {
    /// 前缀、载荷跨越块边界且 slice 起点非零时，仍等于独立 SHA-256 的拼接结果。
    @Test(arguments: [0, 1, 262_143, 262_144, 262_145])
    func segmentedDigestMatchesConcatenation(_ count: Int) throws {
        let source = Data(repeating: 37, count: count + 11)
        let data = source[11...]
        let prefixSource = Data(repeating: 83, count: count + 7)
        let prefix = prefixSource[7...]
        var concatenated = Data(prefix)
        concatenated.append(data)
        let expected = Array(SHA256.hash(data: concatenated))
        #expect(try DocumentIdentity(data: data, prefix: prefix).digest == expected)
        #expect(try DocumentIdentity(data: data).digest == Array(SHA256.hash(data: data)))
    }

    /// 宿主帧继续使用原尺寸前缀与 RGBA 的摘要，同字节不同画布不能命中同一纹理。
    @Test func hostFrameIdentityPreservesDimensionsAndPixels() async throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
        let wide = try await PAGImage.make(from: PAGImageFrame(width: 2, height: 1, pixels: pixels))
        let tall = try await PAGImage.make(from: PAGImageFrame(width: 1, height: 2, pixels: pixels))
        var original = Data("pag.hostFrame.2x1".utf8)
        original.append(pixels)
        #expect(wide.storage.identity.digest == Array(SHA256.hash(data: original)))
        #expect(wide.storage.identity != tall.storage.identity)
        #expect(wide.storage.pixels == pixels)
    }

    /// 已取消任务即使输入为空也必须终止，不能绕过分块循环返回成功摘要。
    @Test func emptyInputHonorsCancellation() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentIdentity(data: Data())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
