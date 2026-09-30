import CoreVideo
import Foundation

/// 已解码只读输入的一次性交接槽；短锁保证只有一个RenderOwner能取得缓冲，不改变像素。
final class VideoFrameTransfer: @unchecked Sendable {
    /// 序列内容与实际PTS共同确定的资源身份。
    let identity: VideoFrameID
    /// PAG颜色区域的正像素尺寸，不含alpha区域或补齐像素。
    let size: PAGSize
    /// PAG透明度区域横向偏移，0与纵向0一起表示不透明。
    let alphaStartX: Int
    /// PAG透明度区域纵向偏移，不能假定总为0。
    let alphaStartY: Int
    /// 当前输入缓冲的实际保活成本，逐帧计划与GPU预算另外计费。
    let byteCount: Int
    /// 保护单次消费，只用于引用交换，不执行任何系统资源准备。
    private let lock = NSLock()
    /// 只读输入，消费后为nil；媒体缓存可同时持有只读引用。
    private var buffer: CVPixelBuffer?

    /// 在媒体owner域内保活一次输入引用；尺寸来源必须是已经完整验证的序列。
    init(_ frame: VideoDecodedFrame, sequence: SourceVideoSequence) throws {
        identity = VideoFrameID(sequence: sequence.identity, frame: frame.frame)
        size = try PAGSize(width: Double(sequence.width), height: Double(sequence.height))
        alphaStartX = sequence.alphaStartX
        alphaStartY = sequence.alphaStartY
        byteCount = frame.byteCount
        buffer = frame.buffer
    }

    /// RenderOwner同步取得原始缓冲并负责保活到GPU完成；重复消费明确失败。
    func take() throws -> CVPixelBuffer {
        try lock.withLock {
            guard let value = buffer else { throw PAGError.mediaFailure("videoFrameAlreadyConsumed") }
            buffer = nil
            return value
        }
    }

    /// GPU已缓存相同帧或准备放弃时释放本次交接引用；不影响媒体缓存或已消费的资源。
    func discard() { lock.withLock { buffer = nil } }
}
