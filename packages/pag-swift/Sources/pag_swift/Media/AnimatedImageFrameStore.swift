import Dispatch
import Foundation

/// 每个准备场景独占的动图帧owner；ImageIO解码在后台串行域按需进行。
actor AnimatedImageFrameStore {
    /// 同步系统解码不占主线程，也不阻塞Swift协作执行器。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.animated.images", qos: .userInitiated)
    /// 媒体帧缓存与ImageIO调用始终落在本owner队列。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 单次系统解码和当前RGBA帧的输入上限，不按素材总帧数线性增长。
    private let maximumBytes: Int
    /// 当前最近一张完整RGBA输入；已交给旧计划的图像可独立延长生命周期。
    private var entries: [Entry] = []

    /// 创建有限输入缓存；非法预算在实际解码请求时报资源错误。
    init(maximumBytes: Int = 64 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    /// 按图层有效内容时间取得完整帧，取消/失败不发布部分帧。
    func frame(for image: PAGImage, at time: PAGTime) throws -> PAGImage {
        dispatchPrecondition(condition: .onQueue(executor))
        try Task.checkCancellation()
        guard let animation = image.animation else { return image }
        let index = animation.frameIndex(at: time)
        if let position = entries.firstIndex(where: {
            $0.identity == animation.identity && $0.index == index
        }) {
            let entry = entries.remove(at: position)
            entries.append(entry)
            return entry.image
        }
        guard maximumBytes > 0,
              let width = Int(exactly: animation.size.width),
              let height = Int(exactly: animation.size.height),
              width > 0, height > 0 else {
            throw PAGError.resourceLimitExceeded("maximumAnimatedFrameBytes")
        }
        let area = width.multipliedReportingOverflow(by: height)
        guard !area.overflow, area.partialValue <= maximumBytes / 12 else {
            throw PAGError.resourceLimitExceeded("maximumAnimatedFrameBytes")
        }
        // 解码高峰按系统源图、方向转换和目标RGBA三份计费；旧帧先移走。
        entries.removeAll()
        let identity = try animation.identity(for: index)
        let storage = try StillImageDecoder.decodeFrame(animation.data, index: index,
            identity: identity, maximumDecodedBytes: maximumBytes)
        guard storage.size == animation.size, storage.sourceType == animation.sourceType else {
            throw PAGError.unsupportedAnimatedImage(animation.sourceType)
        }
        try Task.checkCancellation()
        let result = PAGImage(storage: storage)
        entries.append(Entry(identity: animation.identity, index: index, image: result))
        return result
    }

    /// 只报告当前owner仍保活的RGBA输入，不含编码字节及已交给GPU的旧帧。
    func retainedBytes() -> Int { entries.reduce(0) { $0 + $1.image.storage.pixels.count } }
}

/// 一张已完整发布的动图帧，身份由原编码摘要与真实帧号共同确定。
private struct Entry {
    /// 同一图像内容可用于多个图层实例，缓存只按内容身份共享。
    let identity: DocumentIdentity
    /// 素材帧索引，不等于PAG根帧号。
    let index: Int
    /// 脱离可变ImageIO状态的RGBA输入。
    let image: PAGImage
}
