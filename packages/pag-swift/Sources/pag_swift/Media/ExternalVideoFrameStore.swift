import AVFoundation
import CoreVideo
import Dispatch
import Foundation

/// 单场景的外部视频owner；AVPlayerItemVideoOutput只按PAG局部时间请求有限NV12输入。
actor ExternalVideoFrameStore: ExternalVideoSampling {
    /// 同步AVFoundation调用与短轮询不占MainActor或协作执行器。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.external.video", qos: .userInitiated)
    /// 媒体状态与播放器回调统一回到当前owner串行域。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 同时保留的一张解码帧和系统会话预算。
    private let maximumBytes: Int
    /// 当前唯一媒体会话；替换来源时旧会话暂停并释放。
    private var session: ExternalVideoSession?
    /// 最近有效输出；外部视频停在末帧时复用原缓冲。
    private var current: ExternalVideoFrame?
    /// 每次请求递增，旧seek在暂停点返回后必须丢弃。
    private var generation: UInt64 = 0

    /// 给系统解码和一张留存NV12输入设置上限；非法值在实际取帧时失败。
    init(maximumBytes: Int = 64 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    /// 取所属图层时间上的一帧；seek撤销过时请求，短素材结束后保持最后有效帧。
    func frame(for source: ExternalVideoStorage, at time: PAGTime,
               isPlaying: Bool = false) async throws -> VideoFrameTransfer {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw PAGError.resourceLimitExceeded("maximumVideoFrameBytes") }
        generation &+= 1
        let request = generation
        let interval = max(1, Int64((1_000_000 / source.frameRate).rounded()))
        let last = max(0, source.durationMicroseconds - interval)
        let target = min(max(0, time.microseconds), last)
        if let current, current.identity == source.identity, current.requestedTime == target {
            if !isPlaying { session?.player.pause() }
            return VideoFrameTransfer(external: current, size: source.size)
        }
        let active: ExternalVideoSession
        if let session, session.identity == source.identity {
            active = session
        } else {
            session?.player.pause()
            session = nil
            current = nil
            // 文件可在载入与首次播放之间被替换；重开前逐字节核对，不混入旧句柄。
            let identity = try await StableFileReader.identity(from: source.url, limits: .standard)
            guard request == generation else { throw CancellationError() }
            guard identity == source.identity else { throw PAGError.sourceChanged }
            active = try ExternalVideoSession(source: source)
            session = active
        }
        // 只由仍拥有最新请求的事务暂停会话，迟到seek不能停掉后继取帧。
        defer { if request == generation && !isPlaying { active.player.pause() } }
        active.item.cancelPendingSeeks()
        active.player.play()
        // AVPlayerItemVideoOutput只有在item进入ready并推进会话后才稳定交付seek目标帧。
        for _ in 0..<200 where active.item.status == .unknown {
            try await Task.sleep(for: .milliseconds(10))
            guard request == generation else { throw CancellationError() }
        }
        guard active.item.status == .readyToPlay else { throw PAGError.mediaFailure("externalVideoNotReady") }
        let requested = CMTime(value: target, timescale: 1_000_000)
        if isPlaying, let current, current.identity == source.identity,
           target > current.requestedTime, target - current.requestedTime <= 250_000 {
            var display = CMTime.invalid
            if let buffer = active.output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &display),
               display.isValid, display.seconds <= requested.seconds + 0.001,
               requested.seconds - display.seconds <= 1 / source.frameRate {
                let selected = try ExternalVideoFrame(source: source, requestedTime: target,
                    displayTime: display, buffer: buffer, maximumBytes: maximumBytes)
                self.current = selected
                return VideoFrameTransfer(external: selected, size: source.size)
            }
            // 解码器尚未交付新帧时保留上一个真实输入，下一显示tick再请求目标时间。
            return VideoFrameTransfer(external: current, size: source.size)
        }
        await active.player.seek(to: requested, toleranceBefore: .zero, toleranceAfter: .zero)
        guard request == generation else { throw CancellationError() }
        try Task.checkCancellation()
        let decoded: ExternalVideoFrame
        var result: ExternalVideoFrame?
        for _ in 0..<100 {
            var display = CMTime.invalid
            if let buffer = active.output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &display),
               display.isValid, abs(display.seconds - requested.seconds) <= 1 / source.frameRate {
                result = try ExternalVideoFrame(source: source, requestedTime: target,
                    displayTime: display, buffer: buffer,
                    maximumBytes: maximumBytes)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
            guard request == generation else { throw CancellationError() }
            try Task.checkCancellation()
        }
        guard let result else {
            if let current, current.identity == source.identity {
                return VideoFrameTransfer(external: current, size: source.size)
            }
            throw PAGError.mediaFailure("externalVideoMissingFrame")
        }
        decoded = result
        guard request == generation else { throw CancellationError() }
        current = decoded
        return VideoFrameTransfer(external: decoded, size: source.size)
    }

    /// 报告owner留存的当前NV12输入成本，系统内部参考帧另由硬件解码器管理。
    func retainedBytes() -> Int { current?.byteCount ?? 0 }

    /// 主播放暂停/隐藏后立即停止系统预取；保留最后一帧供同位置重绘。
    func pause() { session?.player.pause() }
}

/// 一份owner独占的静音系统播放器及指定420v输出，不跨隔离传递给场景或渲染器。
private final class ExternalVideoSession {
    /// 编码文件身份，不能只按路径决定是否继续使用已有会话。
    let identity: DocumentIdentity
    /// 当前系统媒体项；轨道错误和seek状态从这里判定。
    let item: AVPlayerItem
    /// 只做系统解码与seek，PAG帧计划仍是显示时钟。
    let player: AVPlayer
    /// 直接交付IOSurface兼容NV12，不读取CPU像素或创建RGBA中转帧。
    let output: AVPlayerItemVideoOutput

    /// 建立静音系统视频项；调用前来源身份已在owner域复核。
    init(source: ExternalVideoStorage) throws {
        var attributes = CVPixelBufferAttributes(pixelFormatTypes: [
            CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ], compatibility: [.metalTexture])
        attributes.backing = .ioSurface
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        let item = AVPlayerItem(asset: AVURLAsset(url: source.url))
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        identity = source.identity
        self.item = item
        self.player = player
        self.output = output
    }

    /// 会话释放前停止独立系统时钟，后续取帧只会由PAG请求重新推进。
    deinit { player.pause() }
}

/// 一张经尺寸、格式、色彩及预算验证的系统输入，可被多个一次性交接槽只读共享。
final class ExternalVideoFrame {
    /// 来源文件身份，旧文件帧不得混入新文件会话。
    let identity: DocumentIdentity
    /// AVFoundation实际输出时间，作为GPU纹理身份；相邻PAG tick可共用同一视频帧。
    let time: Int64
    /// 最近接受的PAG局部请求时间，与实际输出PTS分开用于连续快路径。
    let requestedTime: Int64
    /// 只读420v双平面缓冲，RenderOwner接管时仍由本owner可选保活。
    let buffer: CVPixelBuffer
    /// 色彩矩阵随视频源而非PAG内嵌视频的601合同决定。
    let colorMatrix: VideoColorMatrix
    /// 平面真实步长成本，不按文件长度或标称分辨率估计。
    let byteCount: Int

    /// 验证真实输出后才发布；未知色彩或不兼容平面明确失败。
    init(source: ExternalVideoStorage, requestedTime: Int64, displayTime: CMTime,
         buffer: CVPixelBuffer, maximumBytes: Int) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              Double(CVPixelBufferGetWidth(buffer)) == source.size.width,
              Double(CVPixelBufferGetHeight(buffer)) == source.size.height else {
            throw PAGError.unsupportedFeature("externalVideoPixelFormat")
        }
        let planes = (0..<2).reduce(0) { $0 + CVPixelBufferGetBytesPerRowOfPlane(buffer, $1) *
            CVPixelBufferGetHeightOfPlane(buffer, $1) }
        let bytes = max(planes, CVPixelBufferGetDataSize(buffer))
        guard bytes > 0, bytes <= maximumBytes else {
            throw PAGError.resourceLimitExceeded("maximumVideoFrameBytes")
        }
        guard let raw = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil),
              let matrix = raw as? String else {
            throw PAGError.unsupportedFeature("externalVideoColorMatrix")
        }
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            colorMatrix = .bt601
        } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
            colorMatrix = .bt709
        } else {
            throw PAGError.unsupportedFeature("externalVideoColorMatrix")
        }
        identity = source.identity
        guard displayTime.seconds.isFinite,
              displayTime.seconds >= 0,
              displayTime.seconds * 1_000_000 < Double(Int64.max) else {
            throw PAGError.mediaFailure("externalVideoDisplayTime")
        }
        time = Int64((displayTime.seconds * 1_000_000).rounded())
        self.requestedTime = requestedTime
        self.buffer = buffer
        byteCount = bytes
    }
}
