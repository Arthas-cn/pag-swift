import Foundation

/// 不暴露 CGImage 或 Metal 对象的不可变替换素材；像素只作为渲染输入。
public struct PAGImage: Sendable {
    /// 后台完整解码并规范化的静态输入资源，跨快照可安全共享。
    let storage: StillImageStorage

    /// 已应用 EXIF 方向后的原始像素尺寸，不含图层或显示缩放。
    public var size: PAGSize { storage.size }
    /// 当前工厂支持的资源为单帧静图。
    public var kind: PAGImageKind { .still }
    /// 静态素材没有自身播放时长。
    public var duration: PAGTime? { nil }

    /// 从普通本地文件完整解码静图；多帧素材暂抛 unsupportedAnimatedImage，取消保留 CancellationError。
    @concurrent public static func load(from url: URL) async throws -> PAGImage {
        let snapshot = try await StableFileReader.read(from: url, limits: .standard)
        return try StillImageDecoder.decode(snapshot.data, identity: snapshot.identity,
                                            maximumDecodedBytes: PAGLoadLimits.standard.maximumDecodedBytes)
    }

    /// 从 PNG/JPEG/静态 WebP/单帧 GIF 建立素材；损坏或其他格式失败，不接受 PAG/MP4。
    @concurrent public static func load(data: Data) async throws -> PAGImage {
        let snapshot = try await LoadSnapshot.prepare(data: data, limits: .standard)
        return try StillImageDecoder.decode(snapshot.data, identity: snapshot.identity,
                                            maximumDecodedBytes: PAGLoadLimits.standard.maximumDecodedBytes)
    }
}

/// 对外描述素材的时间特征；动态工厂按架构在后续阶段实现。
public enum PAGImageKind: Sendable, Hashable {
    /// 一份不可变静态输入，不创建媒体时钟。
    case still
    /// 按每帧时长采样的 GIF/WebP 素材。
    case animated
    /// 从 MP4/MOV 按局部时间采样的外部素材，不是 PAG 文件。
    case video
}

/// 完整静图的安全跨隔离存储；没有裸像素指针或系统图像对象逃逸。
final class StillImageStorage: Sendable {
    /// 静图为完整编码内容身份；bitmap 重建输入按完整序列摘要与采样帧派生。
    let identity: DocumentIdentity
    /// 应用方向后的有限正尺寸。
    let size: PAGSize
    /// sRGB 预乘 RGBA8 输入像素，顶行在前、紧密行布局，供后续上传纹理。
    let pixels: Data
    /// 每行字节数，等于像素宽度乘四。
    let bytesPerRow: Int
    /// 静图为 ImageIO 来源 UTI；bitmap 重建输入使用内部标记 pag.bitmap，不冒充文件 UTI。
    let sourceType: String
    /// 来源 EXIF 方向，范围 1...8；无标记为 1。
    let sourceOrientation: Int

    /// 只接收解码器已完成验证的像素和元数据；不从调用方接受任意假句柄。
    init(identity: DocumentIdentity, size: PAGSize, pixels: Data, bytesPerRow: Int,
         sourceType: String, sourceOrientation: Int) {
        self.identity = identity
        self.size = size
        self.pixels = pixels
        self.bytesPerRow = bytesPerRow
        self.sourceType = sourceType
        self.sourceOrientation = sourceOrientation
    }
}
