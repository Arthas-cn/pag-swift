/// 图像槽的播放选择，与输入文件扩展名无关；同一动图可在不同槽位采用不同模式。
public enum PAGImagePlaybackMode: Sendable, Hashable {
    /// 动图使用独立累计进度，静图保持静态，视频沿用其既有内容时间。
    case animated
    /// 图像只显示素材首帧，不创建动图 owner；视频没有静态首帧输入，因此明确拒绝。
    case still
}

/// 按 tag 应用图像时的呈现选项；不持有播放器状态，也不改变原始素材。
public struct PAGImageContentOptions: Sendable {
    /// 是否保留输入的动态图像能力，默认 animated。
    public let playbackMode: PAGImagePlaybackMode
    /// nil 保留 PAG 原有图片适配规则；例如业务头像可以明确使用 aspectFill 填满槽位。
    public let scaleMode: PAGScaleMode?
    /// 只作用于本次替换的静态 alpha；nil 表示不增加槽位遮罩。
    public let mask: PAGImageMask?
    /// 保留素材原有动态属性的默认配置。
    public static let standard = PAGImageContentOptions()

    /// 建立不可变选项；目标素材的类型约束在内容提交前验证。
    public init(playbackMode: PAGImagePlaybackMode = .animated,
                scaleMode: PAGScaleMode? = nil, mask: PAGImageMask? = nil) {
        self.playbackMode = playbackMode
        self.scaleMode = scaleMode
        self.mask = mask
    }

    /// 静态选择只复用首帧，不额外解码；视频的静态选择或槽位遮罩均明确抛调用错误。
    func image(from input: PAGImage) throws -> PAGImage {
        guard mask == nil || input.video == nil else { throw PAGError.invalidArgument("slotMaskForVideo") }
        guard playbackMode == .still else { return input }
        guard input.video == nil else { throw PAGError.invalidArgument("stillImagePlaybackForVideo") }
        return PAGImage(storage: input.storage)
    }
}
