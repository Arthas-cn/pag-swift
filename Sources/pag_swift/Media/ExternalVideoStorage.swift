import AVFoundation
import Foundation

/// 外部MP4/MOV的不变来源及可呈现轨道元数据；不持有共享AVPlayer或已解码整片。
final class ExternalVideoStorage: Sendable {
    /// 标准化本地路径；每个播放owner重开时仍须核对完整来源身份。
    let url: URL
    /// 工厂读取完整编码文件所得身份，重开后不同则拒绝混用旧句柄。
    let identity: DocumentIdentity
    /// 未旋转的可见视频尺寸，输入缓冲须与之相符。
    let size: PAGSize
    /// 本地媒体有效时长，正数微秒；最后一张有效帧在此后保持。
    let durationMicroseconds: Int64
    /// 用于末帧目标钳制的名义帧率，有限且为正。
    let frameRate: Double

    /// 只保存经过AVFoundation轨道验证的标量，不跨隔离发送AVAsset或Track。
    init(url: URL, identity: DocumentIdentity, size: PAGSize,
         durationMicroseconds: Int64, frameRate: Double) {
        self.url = url
        self.identity = identity
        self.size = size
        self.durationMicroseconds = durationMicroseconds
        self.frameRate = frameRate
    }

    /// 后台核对文件快照、可播放视频轨和正时长；音频轨不建立会话。
    @concurrent static func load(from url: URL) async throws -> ExternalVideoStorage {
        guard ["mp4", "mov"].contains(url.pathExtension.lowercased()) else {
            throw PAGError.unsupportedFeature("externalVideoContainer")
        }
        let identity = try await StableFileReader.identity(from: url, limits: .standard)
        try Task.checkCancellation()
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let asset = AVURLAsset(url: canonical)
        let playable = try await asset.load(.isPlayable)
        let isProtected = try await asset.load(.hasProtectedContent)
        guard playable, !isProtected else {
            throw PAGError.mediaFailure("unplayableVideo")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else { throw PAGError.mediaFailure("videoTrackCount") }
        let track = tracks[0]
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // 旋转/镜像轨道需要在像素到图层的矩阵上单独合成，不能悄悄拿未旋转宽高替代。
        guard transform.isIdentity else { throw PAGError.unsupportedFeature("externalVideoTransform") }
        let duration = try await asset.load(.duration).seconds
        let rate = Double(try await track.load(.nominalFrameRate))
        guard natural.width.isFinite, natural.height.isFinite,
              natural.width > 0, natural.height > 0, natural.width <= 16_384, natural.height <= 16_384,
              natural.width * natural.height <= 16_777_216,
              duration.isFinite, duration > 0, duration * 1_000_000 < Double(Int64.max),
              rate.isFinite, rate > 0, rate <= 240 else {
            throw PAGError.mediaFailure("invalidVideoMetadata")
        }
        let microseconds = Int64((duration * 1_000_000).rounded())
        guard microseconds > 0 else { throw PAGError.mediaFailure("invalidVideoDuration") }
        // AVAsset在第一次字节快照之后另行开文件；元数据读取期间换源不能发表混合句柄。
        let verified = try await StableFileReader.identity(from: canonical, limits: .standard)
        guard verified == identity else { throw PAGError.sourceChanged }
        try Task.checkCancellation()
        return try ExternalVideoStorage(url: canonical, identity: identity,
            size: PAGSize(width: Double(natural.width), height: Double(natural.height)),
            durationMicroseconds: microseconds, frameRate: rate)
    }
}
