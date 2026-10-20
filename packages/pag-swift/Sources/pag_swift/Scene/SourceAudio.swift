import Foundation

/// 合成保留的原始音频元数据，不解析媒体、不负责播放或同步。
struct SourceAudio: Sendable {
    /// 非空原始容器字节；nil表示tag55显式编码零长度，不是解码失败。
    let bytes: Data?
    /// 合成时间线上的ReadTime原始帧值，允许负值；尚未增加实例偏移或转微秒。
    let startFrame: Int64
}
