import Dispatch
import Foundation

/// 同步系统/宿主 decoder 的唯一串行执行域，不参与显示采样或播放状态控制。
actor AnimatedFrameDecoder {
    /// 阻塞式系统调用不占主线程，也不占 Swift 协作线程池。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.animated.decode", qos: .userInitiated)
    /// 所有可变 decoder 访问都固定在此专用队列。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// 读取并验证一张完整画布；返回小值结果，调用者负责身份、缓存及错误诊断。
    func decode(_ image: PAGImage, index: Int, maximumBytes: Int) -> AnimatedFrameDecodeResult {
        dispatchPrecondition(condition: .onQueue(executor))
        do {
            try Task.checkCancellation()
            guard let animation = image.animation else { return .frame(image) }
            let identity = try animation.identity(for: index)
            let storage: StillImageStorage
            if let source = animation.externalSource {
                let frame: PAGImageFrame?
                do { frame = try source.frame(at: index) }
                catch is CancellationError { return .cancelled }
                catch { return .hostFailure("hostAnimatedFrame: \(error)") }
                try Task.checkCancellation()
                guard let frame else { return .unavailable }
                guard Double(frame.width) == animation.size.width, Double(frame.height) == animation.size.height else {
                    return .hostFailure("hostAnimatedCanvasChanged")
                }
                storage = try frame.storage(identity: identity)
            } else {
                storage = try StillImageDecoder.decodeFrame(animation.data, index: index,
                    identity: identity, maximumDecodedBytes: maximumBytes)
                guard storage.size == animation.size, storage.sourceType == animation.sourceType else {
                    throw PAGError.unsupportedAnimatedImage(animation.sourceType)
                }
            }
            try Task.checkCancellation()
            return .frame(PAGImage(storage: storage))
        } catch is CancellationError { return .cancelled }
        catch let error as PAGError { return .failure(error) }
        catch { return .failure(.mediaFailure("animatedDecode: \(error)")) }
    }
}

/// 完整帧与可恢复缺帧分开表达；取消不会被计为宿主失败。
enum AnimatedFrameDecodeResult: Sendable {
    /// 已验证可发布的完整不可变 RGBA。
    case frame(PAGImage)
    /// 宿主暂未提供帧，继续保持最近已显示内容。
    case unavailable
    /// 宿主解码错误，仅记录并回退对应素材。
    case hostFailure(String)
    /// 库内解码终态错误，仍通过原可选媒体失败路径处理。
    case failure(PAGError)
    /// 工作被撤销，不发布结果。
    case cancelled
}

/// 最近显示记录按实例区分；内部直接采样没有实例时使用素材身份。
enum AnimatedFrameScope: Hashable, Sendable {
    /// 同一素材的不同 PAG 实例有独立最近帧，不因一方预取而提前显示。
    case layer(PAGLayerID)
    /// 精确探针与无实例内部调用的素材级作用域。
    case material(DocumentIdentity)
}

/// 唯一工作或有限队列中的不可变请求，输入像素/编码字节只按值共享。
struct AnimatedFrameRequest: Sendable {
    /// 工作唯一身份，拒绝迟到完成覆盖另一项任务状态。
    let id: UUID
    /// 带不可变动画时间表与宿主帧源的素材。
    let image: PAGImage
    /// 当前素材身份，绝不只按文件名或 tag 匹配帧。
    let material: DocumentIdentity
    /// 已按素材时长选出的帧索引。
    let index: Int
    /// 请求者的显示记录身份，用于合并最新需求。
    let scope: AnimatedFrameScope
    /// 源画布、转换及输出三份 RGBA 的保守字节预算。
    let reservation: Int
    /// 精确入口沿用单帧缓存语义；实时入口可保留相邻预取帧。
    let exact: Bool
}

/// 一张缓存完整帧；全局 LRU 同时限制帧数、素材数和字节。
struct AnimatedFrameEntry: Sendable {
    /// 帧所属的不可变动画素材。
    let material: DocumentIdentity
    /// 此素材内部的帧索引。
    let index: Int
    /// 不带动画 owner 的完整 RGBA 输入。
    let image: PAGImage
}

/// 实例最近实际选中的帧，只保存身份，不绕过帧缓存额外保活像素。
struct AnimatedFrameSelection: Sendable {
    /// 实例或无实例内部采样的身份。
    let scope: AnimatedFrameScope
    /// 当前安装的素材，换素材后不可复用旧帧记录。
    let material: DocumentIdentity
    /// 最近确实选入帧计划的 RGBA 内容身份，预取完成不改此值。
    let frame: DocumentIdentity
}
