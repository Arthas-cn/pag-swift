import Foundation

/// 与第三方图片框架无关的完整画布；像素为顶行在前、sRGB 预乘 RGBA8。
public struct PAGImageFrame: Sendable {
    /// 整数像素宽度，不含 PAG 图层缩放。
    public let width: Int
    /// 整数像素高度，局部补丁帧必须由宿主先合成为完整画布。
    public let height: Int
    /// 紧密行布局的不可变像素，每行 width * 4 字节；透明像素颜色也必须已预乘。
    public let pixels: Data

    /// 验证完整画布的字节数，单帧最多 64 MiB；非法尺寸/字节布局抛 invalidArgument。
    public init(width: Int, height: Int, pixels: Data) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= (64 * 1024 * 1024) / 4 / height,
              pixels.count == width * height * 4 else {
            throw PAGError.invalidArgument("imageFramePixels")
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 帧已经过公开构造器验证，包装为跨隔离素材，不再次进行编码/解码或复制像素。
    func storage(identity: DocumentIdentity) throws -> StillImageStorage {
        StillImageStorage(identity: identity, size: try PAGSize(width: Double(width), height: Double(height)),
            pixels: pixels, bytesPerRow: width * 4, sourceType: "pag.hostFrame", sourceOrientation: 1)
    }
}

/// 宿主动图的不可变时间表；播放时只使用此快照，不反复查询第三方对象。
public struct PAGAnimatedImageInfo: Sendable {
    /// 所有返回帧必须一致的完整像素画布，不能填实例屏幕尺寸。
    public let size: PAGSize
    /// 各帧持续的正微秒数，数量 1...8192；不强制统一帧率。
    public let frameDurations: [PAGTime]
    /// nil 为无限循环，正整数为总播放次数，结束后保持末帧。
    public let playCount: Int?
    /// 已验证的累计帧结束边界，供现有二分采样器使用。
    let ends: [Int64]

    /// 验证尺寸、循环和时长；超出预算抛资源错误，非法数值抛 invalidArgument。
    public init(size: PAGSize, frameDurations: [PAGTime], playCount: Int? = nil) throws {
        guard let width = Int(exactly: size.width), let height = Int(exactly: size.height),
              width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw PAGError.invalidArgument("animatedCanvas")
        }
        // 解码器源图、转换和完整 RGBA 共三份保守计费，与播放媒体 owner 使用同一预算。
        guard width <= (64 * 1024 * 1024) / 12 / height,
              !frameDurations.isEmpty, frameDurations.count <= 8192 else {
            throw PAGError.resourceLimitExceeded("maximumAnimatedFrameBytesOrCount")
        }
        guard playCount == nil || playCount! > 0 else { throw PAGError.invalidArgument("animatedPlayCount") }
        var total: Int64 = 0
        var ends: [Int64] = []
        for duration in frameDurations {
            guard duration.microseconds > 0 else { throw PAGError.invalidArgument("animatedFrameDuration") }
            let sum = total.addingReportingOverflow(duration.microseconds)
            guard !sum.overflow else { throw PAGError.resourceLimitExceeded("animatedDuration") }
            total = sum.partialValue
            ends.append(total)
        }
        self.size = size
        self.frameDurations = frameDurations
        self.playCount = playCount
        self.ends = ends
    }
}

/// 宿主已加载动态图像的读取边界；不暴露图片库类型，不承担网络下载或独立时钟。
public protocol PAGAnimatedImageSource: Sendable {
    /// 素材生命周期内不变的画布、时间表和总播放轮数。
    var info: PAGAnimatedImageInfo { get }
    /// 后台读取一张完整画布，index 位于时间表范围；nil 表示暂未就绪，保留本素材最近帧。
    /// 实现须同步保护 decoder，不等待主线程/网络，不预解无界帧；坏帧抛错后只回退对应槽。
    func frame(at index: Int) throws -> PAGImageFrame?
}

/// 宿主素材接入只归一化数据和身份，逐帧调度继续交给原有播放器。
extension PAGImage {
    /// 后台建立宿主完整静帧的内容身份，不接管其下载或格式解码。
    @concurrent public static func make(from frame: PAGImageFrame) async throws -> PAGImage {
        // 摘要保留尺寸前缀和像素顺序，但不为最多 64 MiB 的输入再复制整张画布。
        let prefix = Data("pag.hostFrame.\(frame.width)x\(frame.height)".utf8)
        let identity = try DocumentIdentity(data: frame.pixels, prefix: prefix)
        return try PAGImage(storage: frame.storage(identity: identity))
    }

    /// 读取宿主时间表与首帧，保持后续按需解码；单帧归一为静图，首帧不可用则抛 mediaFailure。
    @concurrent public static func animated(from source: any PAGAnimatedImageSource) async throws -> PAGImage {
        try Task.checkCancellation()
        let info = source.info
        guard let poster = try source.frame(at: 0), Double(poster.width) == info.size.width,
              Double(poster.height) == info.size.height else { throw PAGError.mediaFailure("hostAnimatedPoster") }
        try Task.checkCancellation()
        if info.frameDurations.count == 1 { return try await make(from: poster) }
        // 同一个宿主对象只能描述不变素材；每次工厂调用有独立身份，避免不同 decoder 错复用纹理。
        let identity = try DocumentIdentity(data: Data(UUID().uuidString.utf8))
        let animation = try AnimatedImageStorage(identity: identity, data: Data(), sourceType: "pag.hostAnimated",
            ends: info.ends, playCount: info.playCount, size: info.size, externalSource: source)
        return try PAGImage(storage: poster.storage(identity: animation.identity(for: 0)), animation: animation)
    }
}
