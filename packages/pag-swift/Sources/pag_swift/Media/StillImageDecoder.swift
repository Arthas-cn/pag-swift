import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO/CoreGraphics 只在调用的后台解码域中使用，返回纯 Sendable 像素资源。
enum StillImageDecoder {
    /// 完整验证静图并应用方向/颜色空间；必须由后台载入入口调用，像素预算在解码前检查。
    static func decode(_ data: Data, identity: DocumentIdentity, maximumDecodedBytes: Int) throws -> PAGImage {
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let rawType = CGImageSourceGetType(source) else { throw PAGError.mediaFailure("invalidImage") }
        let type = rawType as String
        guard [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier, UTType.gif.identifier].contains(type) else {
            throw PAGError.unsupportedFeature("imageFormat:\(type)")
        }
        let count = CGImageSourceGetCount(source)
        guard count == 1 else {
            if count > 1 { throw PAGError.unsupportedAnimatedImage(type) }
            throw PAGError.mediaFailure("missingImageFrame")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              let width = Int(exactly: rawWidth.doubleValue), let height = Int(exactly: rawHeight.doubleValue),
              width > 0, height > 0 else { throw PAGError.mediaFailure("invalidImageDimensions") }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw PAGError.mediaFailure("invalidImageOrientation") }
        let pixelCount = width.multipliedReportingOverflow(by: height)
        // 给 ImageIO 解码、方向转换和目标 RGBA 各保留一份像素空间，再分配任何大缓冲。
        guard !pixelCount.overflow, pixelCount.partialValue <= maximumDecodedBytes / 12 else {
            throw PAGError.resourceLimitExceeded("maximumDecodedBytes")
        }
        let swapsAxes = orientation >= 5
        let targetWidth = swapsAxes ? height : width
        let targetHeight = swapsAxes ? width : height
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        // maxPixelSize 等于原图最大边，不缩小输入；系统变换负责八种 EXIF 方向。
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              image.width == targetWidth, image.height == targetHeight,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw PAGError.mediaFailure("incompleteImage")
        }
        try Task.checkCancellation()
        let rowBytes = targetWidth * 4
        var pixels = Data(count: pixelCount.partialValue * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: targetWidth, height: targetHeight,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PAGError.mediaFailure("imagePixelAllocation")
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
        try Task.checkCancellation()
        let size = try PAGSize(width: Double(targetWidth), height: Double(targetHeight))
        return PAGImage(storage: StillImageStorage(identity: identity, size: size, pixels: pixels, bytesPerRow: rowBytes,
                                                   sourceType: type, sourceOrientation: orientation))
    }
}
