import Dispatch
import Foundation

/// 独立后台串行域中的 bitmap 输入解码器；只缓存素材基底，不读取或缓存显示结果。
actor BitmapFrameStore {
    /// 同步 ImageIO 和矩形复制不占主线程，也不阻塞共享协作执行器。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.bitmap", qos: .userInitiated)
    /// 所有可变基底与缓存操作归同一真实 actor executor。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 缓存和本次重建的保守工作集上限，必须为正。
    private let maximumBytes: Int
    /// 从旧到新的最多四个最近序列，每条仅保留一个完整不可变帧。
    private var entries: [BitmapFrameEntry] = []

    /// 建立有界素材缓存；上限只用于内部策略/测试，不扩大公开 API。
    init(maximumBytes: Int = 64 * 1024 * 1024) {
        self.maximumBytes = maximumBytes
    }

    /// 按合法序列索引得到完整 RGBA 素材；失败/取消不发布局部基底，系统解码调用不能中途抢占。
    func frame(for sequence: SourceBitmapSequence, at index: Int) throws -> PAGImage {
        dispatchPrecondition(condition: .onQueue(executor))
        try Task.checkCancellation()
        guard maximumBytes > 0, sequence.frames.indices.contains(index) else { throw PAGError.invalidArgument("bitmapFrame") }
        let previous = entries.first { $0.sequence == sequence.identity }
        if let previous, previous.index == index {
            entries.removeAll { $0.sequence == sequence.identity }
            entries.append(previous)
            return previous.image
        }
        // 计入旧/新完整基底，以及 ImageIO/方向转换/矩形结果的三份像素暂存。
        let workingBytes = sequence.byteCount * 2 + sequence.maximumPatchBytes * 3
        guard workingBytes <= maximumBytes else { throw PAGError.resourceLimitExceeded("maximumBitmapFrameBytes") }
        while otherBytes(excluding: sequence.identity) > maximumBytes - workingBytes {
            guard let victim = entries.firstIndex(where: { $0.sequence != sequence.identity }) else { break }
            entries.remove(at: victim)
        }
        let start = sequence.starts[index]
        var pixels: Data
        let first: Int
        if let previous, previous.index >= start, previous.index < index {
            pixels = previous.image.storage.pixels
            first = previous.index + 1
        } else {
            pixels = Data(count: sequence.byteCount)
            first = start
        }
        for frameIndex in first...index {
            try Task.checkCancellation()
            let frame = sequence.frames[frameIndex]
            for (patchIndex, patch) in frame.patches.enumerated() {
                try Task.checkCancellation()
                let decoded = try StillImageDecoder.decode(patch.data, identity: sequence.identity,
                                                            maximumDecodedBytes: sequence.maximumPatchBytes * 3)
                guard decoded.size.width == Double(patch.width), decoded.size.height == Double(patch.height) else {
                    throw PAGError.mediaFailure("bitmapPatchDimensionsChanged")
                }
                if patchIndex == 0, frame.isKeyframe, patch.width != sequence.width || patch.height != sequence.height {
                    // 部分尺寸关键帧不能遗留上一画面的像素；无矩形的帧不走清空分支。
                    pixels.resetBytes(in: 0..<pixels.count)
                }
                try Self.overwrite(patch, with: decoded.storage.pixels, in: &pixels, rowBytes: sequence.width * 4)
            }
        }
        try Task.checkCancellation()
        let image = PAGImage(storage: StillImageStorage(
            identity: try sequence.imageIdentity(at: index), size: try PAGSize(width: Double(sequence.width), height: Double(sequence.height)),
            pixels: pixels, bytesPerRow: sequence.width * 4, sourceType: "pag.bitmap", sourceOrientation: 1
        ))
        // 到这里才替换完整基底。没有 await，因此两个请求不能在局部重建中互相覆盖缓存。
        entries.removeAll { $0.sequence == sequence.identity }
        if entries.count == 4 { entries.removeFirst() }
        entries.append(BitmapFrameEntry(sequence: sequence.identity, index: index, image: image))
        return image
    }

    /// 返回有界缓存的保活成本，供内部验收确认未全片解码和预算约束。
    func retainedBytes() -> Int {
        entries.reduce(0) { $0 + $1.image.storage.pixels.count }
    }

    /// 计算当前请求以外的缓存成本，旧请求基底已由 workingBytes 单独计入。
    private func otherBytes(excluding identity: DocumentIdentity) -> Int {
        entries.reduce(0) { $0 + ($1.sequence == identity ? 0 : $1.image.storage.pixels.count) }
    }

    /// 逐行覆盖预乘像素，透明通道同样覆盖；源像素始终是输入素材，不来自 GPU 读回。
    private static func overwrite(_ patch: SourceBitmapPatch, with source: Data, in target: inout Data, rowBytes: Int) throws {
        try target.withUnsafeMutableBytes { destination in
            try source.withUnsafeBytes { input in
                guard let output = destination.baseAddress, let bytes = input.baseAddress else {
                    throw PAGError.mediaFailure("bitmapPixelStorage")
                }
                let length = patch.width * 4
                for row in 0..<patch.height {
                    if row.isMultiple(of: 64) { try Task.checkCancellation() }
                    output.advanced(by: (patch.y + row) * rowBytes + patch.x * 4)
                        .copyMemory(from: bytes.advanced(by: row * length), byteCount: length)
                }
            }
        }
    }
}

/// 一个完整输入基底；从缓存淘汰不破坏已交给计划或 GPU 准备的不可变资源。
private struct BitmapFrameEntry {
    /// 编码序列的完整内容身份，不能只用文件内重复的合成编号。
    let sequence: DocumentIdentity
    /// 该基底实际重建的序列帧索引。
    let index: Int
    /// 完整、不可变、预乘 RGBA8 素材帧。
    let image: PAGImage
}
