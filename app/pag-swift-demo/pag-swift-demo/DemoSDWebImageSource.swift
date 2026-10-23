import CoreGraphics
import Foundation
import SDWebImage
import SDWebImageWebPCoder
import Synchronization
import pag_swift
#if os(macOS)
import AppKit
/// AppKit 图片仅在宿主解码临界区内读取。
private typealias DemoNativeImage = NSImage
#else
import UIKit
/// UIKit 图片仅在宿主解码临界区内读取。
private typealias DemoNativeImage = UIImage
#endif

/// Demo 宿主的图片加载入口；第三方依赖只存在 App target，PAG 库不导入 SDWebImage。
nonisolated enum DemoSDWebImage {
    /// coder 注册只执行一次，动画 WebP 明确使用宿主链接的 libwebp coder。
    private static let registration: Void = {
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    }()

    /// 后台读取本地演示素材并由 SDAnimatedImage 解码，不使用 PAGImage.load 的 ImageIO 替代路径。
    @concurrent static func load(from url: URL) async throws -> PAGImage {
        _ = registration
        try Task.checkCancellation()
        guard url.isFileURL else { throw PAGError.invalidArgument("demoLocalImageURL") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024 else {
            throw PAGError.resourceLimitExceeded("demoImageBytes")
        }
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        let source = try DemoSDImageSource(data: data)
        return try await PAGImage.animated(from: source)
    }
}

/// 一个不可变素材的 SD 解码器适配；可变 decoder 只在 Mutex 内访问，没有 unchecked Sendable。
nonisolated final class DemoSDImageSource: PAGAnimatedImageSource {
    /// 从 SD 动图属性一次取得的时间表和完整画布。
    let info: PAGAnimatedImageInfo
    /// SDAnimatedImage 及其内部 coder 的唯一所有者，不把原生图片对象传出临界区。
    private let decoder: Mutex<SDAnimatedImage>

    /// 接收宿主已读取的字节，校验 SD 解码结果；不调用 preloadAllFrames。
    init(data: Data) throws {
        // macOS 默认强制解码会转为当前屏幕色域，再转 sRGB 可能产生有损往返。
        // lazy 选项保留 SD 返回帧的源色域，实际 RGBA 转换由下方后台 pixels 一次完成。
        guard let image = SDAnimatedImage(data: data, scale: 1, options: [.decodeUseLazyDecoding: true]) else {
            throw PAGError.mediaFailure("SDAnimatedImageDecode")
        }
        let count = Int(image.animatedImageFrameCount)
        guard count <= 8192 else { throw PAGError.resourceLimitExceeded("demoSDFrameCount") }
        guard let first = Self.cgImage(from: image) else { throw PAGError.mediaFailure("SDImagePoster") }
        let durations: [PAGTime]
        if count > 1 {
            durations = try (0..<count).map { index in
                let seconds = image.animatedImageDuration(at: UInt(index))
                let value = (seconds * 1_000_000).rounded()
                guard value.isFinite, value > 0, let microseconds = Int64(exactly: value) else {
                    throw PAGError.mediaFailure("SDImageFrameDuration")
                }
                return PAGTime(microseconds: microseconds)
            }
        } else {
            // SD 对静图返回帧数零；传单帧时间表让库归一为 still，不制造假动画。
            durations = [PAGTime(microseconds: 100_000)]
        }
        let loops = Int(image.animatedImageLoopCount)
        // SD GIF coder 原样读取 ImageIO 的总轮数，WebP coder 原样读取 WebPDemux LOOP_COUNT。
        // 二者零均表示无限；这里不擅自增加一轮。
        info = try PAGAnimatedImageInfo(size: PAGSize(width: Double(first.width), height: Double(first.height)),
            frameDurations: durations, playCount: loops == 0 ? nil : loops)
        decoder = Mutex(image)
    }

    /// 在后台媒体 owner 上读取完整帧；WebP coder 在内部处理 blend/dispose，不把 patch 当画布。
    func frame(at index: Int) throws -> PAGImageFrame? {
        guard info.frameDurations.indices.contains(index) else { throw PAGError.invalidArgument("SDFrameIndex") }
        return try decoder.withLock { image in
            try autoreleasepool {
                try Task.checkCancellation()
                let frame = image.animatedImageFrameCount > 1 ? image.animatedImageFrame(at: UInt(index)) : image
                guard let frame, let cgImage = Self.cgImage(from: frame) else {
                    throw PAGError.mediaFailure("SDAnimatedFrameUnavailable")
                }
                return try Self.pixels(from: cgImage)
            }
        }
    }

    /// 原生平台图片只在后台解码临界区使用，像素转换后不跨 actor 共享 UIImage/NSImage。
    private static func cgImage(from image: DemoNativeImage) -> CGImage? {
        #if os(macOS)
        // SD 用 NSBitmapImageRep 保存原始完整帧，直接读取可避免 AppKit 按显示环境重绘与色彩转换。
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return bitmap.cgImage
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// 统一成库约定的紧密预乘 sRGB RGBA，保留透明区域，不经过 PNG 再编码。
    private static func pixels(from image: CGImage) throws -> PAGImageFrame {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= (64 * 1024 * 1024) / 12 / height else {
            throw PAGError.resourceLimitExceeded("demoSDFrameBytes")
        }
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PAGError.mediaFailure("demoSDPixelAllocation")
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try PAGImageFrame(width: width, height: height, pixels: data)
    }
}
