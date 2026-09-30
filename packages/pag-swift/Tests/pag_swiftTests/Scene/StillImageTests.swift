import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import pag_swift

/// 静图输入的真实解码、像素约定、方向、预算和取消；没有 GPU 帧读回。
struct StillImageTests {
    /// 三种真实静图均生成完整输入缓冲，元数据不启动媒体时钟。
    @Test(arguments: ["png", "jpg", "webp"])
    func loadsRealStillImages(_ suffix: String) async throws {
        let data = try PAGFixtures.data(named: "media/imageReplacement.\(suffix)")
        let image = try await PAGImage.load(data: data)
        #expect(image.size == (try PAGSize(width: 110, height: 110)))
        #expect(image.kind == .still && image.duration == nil)
        #expect(image.storage.bytesPerRow == 440 && image.storage.pixels.count == 48_400)
        #expect(image.storage.pixels.contains { $0 != 0 })
    }

    /// 非正方形照片的 EXIF=6 必须应用一次，公开宽高应交换。
    @Test func appliesEXIFOrientation() async throws {
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/rotation.jpg"))
        #expect(image.storage.sourceOrientation == 6)
        #expect(image.size == (try PAGSize(width: 3024, height: 4032)))
        #expect(image.storage.bytesPerRow == 3024 * 4)
        #expect(image.storage.pixels.count == 3024 * 4032 * 4)
    }

    /// 独立 2×2 PNG 验证 RGBA 通道、顶行顺序及 alpha 预乘，防止上传纹理后倒置或变色。
    @Test func normalizedPixelsUseTopFirstPremultipliedRGBA() async throws {
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        #expect(image.size == (try PAGSize(width: 2, height: 2)))
        #expect(Array(image.storage.pixels) == [255, 0, 0, 255, 0, 128, 0, 128,
                                              0, 0, 64, 64, 0, 0, 0, 0])
    }

    /// URL 和非零起点 Data 切片得到同一来源身份与像素，不依赖调用方路径扩展名。
    @Test func URLAndDataSliceAgree() async throws {
        let url = try PAGFixtures.rootURL().appendingPathComponent("media/imageReplacement.png")
        let fromURL = try await PAGImage.load(from: url)
        var prefixed = Data([0xff])
        prefixed.append(try Data(contentsOf: url))
        let sliced = prefixed.dropFirst()
        #expect(sliced.startIndex == 1)
        let fromData = try await PAGImage.load(data: sliced)
        #expect(fromURL.storage.identity == fromData.storage.identity)
        #expect(fromURL.storage.pixels == fromData.storage.pixels)
    }

    /// 单帧 GIF 仍是 still，不因容器种类强行创建动画；编码由系统公开 API 完成。
    @Test func singleFrameGIFIsStill() async throws {
        let sourceData = try PAGFixtures.data(named: "media/imageReplacement.png")
        let source = try #require(CGImageSourceCreateWithData(sourceData as CFData, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, frame, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try await PAGImage.load(data: bytes as Data)
        #expect(image.kind == .still)
        #expect(image.size == (try PAGSize(width: 110, height: 110)))
    }

    /// 真实多帧 GIF/WebP 在 P2 明确拒绝，不能静默返回首帧并伪称动图。
    @Test(arguments: [("bear.gif", UTType.gif.identifier), ("webp01.webp", UTType.webP.identifier)])
    func animatedSourcesFailExplicitly(_ name: String, _ type: String) async throws {
        await #expect(throws: PAGError.unsupportedAnimatedImage(type)) {
            try await PAGImage.load(data: PAGFixtures.data(named: "media/\(name)"))
        }
    }

    /// 预算在分配完整像素前生效，给输入解码、方向和 RGBA 缓冲计三份成本。
    @Test func decodedPixelsAreBudgeted() throws {
        let data = try PAGFixtures.data(named: "media/rgba-corners.png")
        let identity = try DocumentIdentity(data: data)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try StillImageDecoder.decode(data, identity: identity, maximumDecodedBytes: 47)
        }
        let image = try StillImageDecoder.decode(data, identity: identity, maximumDecodedBytes: 48)
        #expect(image.storage.pixels.count == 16)
    }

    /// 截断编码和非图片都失败，不能发布只有尺寸没有像素的资源句柄。
    @Test func invalidInputDoesNotCreateResource() async throws {
        let truncated = try PAGFixtures.data(named: "media/imageReplacement.png").prefix(40)
        await #expect(throws: (any Error).self) { try await PAGImage.load(data: truncated) }
        await #expect(throws: PAGError.mediaFailure("invalidImage")) {
            try await PAGImage.load(data: PAGFixtures.data(named: "red.pag"))
        }
        await #expect(throws: PAGError.mediaFailure("invalidImage")) {
            try await PAGImage.load(data: PAGFixtures.data(named: "game.mp4"))
        }
    }

    /// 预取消任务保持 CancellationError，不把取消包装成媒体损坏。
    @Test func cancelledFactoryDoesNotPublish() async throws {
        let data = try PAGFixtures.data(named: "media/imageReplacement.png")
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: PAGImage.self) { group in
                group.cancelAll()
                group.addTask { try await PAGImage.load(data: data) }
                for try await _ in group {}
            }
        }
    }
}
