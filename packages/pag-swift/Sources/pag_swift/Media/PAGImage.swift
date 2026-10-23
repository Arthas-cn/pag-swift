import Foundation

/// 不暴露 CGImage 或 Metal 对象的不可变替换素材；动态帧由每播放器媒体owner采样。
public struct PAGImage: Sendable {
    /// 已规范化的静态输入或动图首帧；视频时只保存无像素的尺寸标记，帧走独立媒体owner。
    let storage: StillImageStorage
    /// GIF/WebP编码快照及时间表；nil为单帧静图。
    let animation: AnimatedImageStorage?
    /// 外部视频的已验证容器及时间信息；nil表示图像素材。
    let video: ExternalVideoStorage?

    /// 保存不可变素材和可选动图时间表；内部逐帧产物不再携带动画来源。
    init(storage: StillImageStorage, animation: AnimatedImageStorage? = nil) {
        self.storage = storage
        self.animation = animation
        video = nil
    }

    /// 视频只借静图存储的尺寸与身份字段，不发布假的RGBA帧。
    init(video: ExternalVideoStorage) {
        storage = StillImageStorage(identity: video.identity, size: video.size, pixels: Data(),
            bytesPerRow: 0, sourceType: "pag.externalVideo", sourceOrientation: 1)
        animation = nil
        self.video = video
    }

    /// 已应用 EXIF 方向后的原始像素尺寸，不含图层或显示缩放。
    public var size: PAGSize { storage.size }
    /// 动图按独立累计播放进度选帧，只跟随 PAG 播放/暂停；复用同一显示刷新，不启动另一个 Timer。
    public var kind: PAGImageKind { video != nil ? .video : (animation == nil ? .still : .animated) }
    /// 静态素材为nil，动图为一轮总时长。
    public var duration: PAGTime? {
        if let video { return PAGTime(microseconds: video.durationMicroseconds) }
        return animation.map { PAGTime(microseconds: $0.durationMicroseconds) }
    }

    /// 从普通本地文件建立静图或有界GIF/WebP时间表；取消保留CancellationError。
    @concurrent public static func load(from url: URL) async throws -> PAGImage {
        let snapshot = try await StableFileReader.read(from: url, limits: .standard)
        return try AnimatedImageDecoder.decodeIfAnimated(snapshot.data, identity: snapshot.identity,
            maximumDecodedBytes: PAGLoadLimits.standard.maximumDecodedBytes) ??
            StillImageDecoder.decode(snapshot.data, identity: snapshot.identity,
                maximumDecodedBytes: PAGLoadLimits.standard.maximumDecodedBytes)
    }

    /// 从PNG/JPEG/GIF/WebP建立静图或动图素材；损坏及非图像格式失败。
    @concurrent public static func load(data: Data) async throws -> PAGImage {
        let snapshot = try await LoadSnapshot.prepare(data: data, limits: .standard)
        return try AnimatedImageDecoder.decodeIfAnimated(snapshot.data, identity: snapshot.identity,
            maximumDecodedBytes: PAGLoadLimits.standard.maximumDecodedBytes) ??
            StillImageDecoder.decode(snapshot.data, identity: snapshot.identity,
                maximumDecodedBytes: PAGLoadLimits.standard.maximumDecodedBytes)
    }

    /// 从本地MP4/MOV建立已验证的视频句柄，逐帧解码由播放器媒体owner完成且不输出音频。
    @concurrent public static func loadVideo(from url: URL) async throws -> PAGImage {
        try await PAGImage(video: ExternalVideoStorage.load(from: url))
    }

}

/// 对外描述素材的时间特征；不暴露媒体解码器或播放控制权。
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
