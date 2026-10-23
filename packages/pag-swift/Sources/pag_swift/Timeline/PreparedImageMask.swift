import CoreGraphics
import Foundation

/// 单帧中静态槽位遮罩的引用；像素只保留在 PreparedFrame.images 中并复用 GPU 纹理缓存。
struct FrameImageMask: Sendable {
    /// 静态遮罩的内容摘要，不随头像动图帧号改变。
    let resourceID: DocumentIdentity
    /// 遮罩输入像素画布，供 Metal 验证资源并归一化采样坐标。
    let pixelSize: PAGSize
    /// 遮罩像素到当前显示像素的映射，包含目标槽的原 PAG 图层变换。
    let matrix: SceneAffine
}

/// 安装时准备的一张静态遮罩及其到目标槽逻辑坐标的映射，不包含播放时钟。
struct PreparedImageMask: Sendable {
    /// alpha 覆盖输入；RGB 在 Metal 片元中不使用。
    let image: PAGImage
    /// 遮罩像素到目标原始逻辑框的变换，保留源 PAG 裁边与自定义路径画布。
    let placement: SceneAffine

    /// 后台解析来源或栅格化一次路径；失败/取消不会修改合成编辑。
    @concurrent static func prepare(_ mask: PAGImageMask, for size: PAGSize,
                                    in composition: PAGComposition) async throws -> Self {
        try Task.checkCancellation()
        switch mask {
        case .alphaImage(let image, let mode):
            guard image.kind == .still else { throw PAGError.invalidArgument("animatedMaskImage") }
            return Self(image: image, placement: try placement(from: image.size, to: size, mode: mode))
        case .originalImage(let tag, let mode):
            guard let record = composition.dynamicSlotRecords().first(where: { $0.slot.tag == tag }),
                  record.slot.kind == .image,
                  let source = composition.storage.resources.images[composition.storage.catalog.imageIDs[record.slot.sourceIndex]] else {
                throw PAGError.invalidArgument("maskSourceTag")
            }
            // 始终读取不可变资源表；来源槽已被替换或隐藏，也不能改变此处读取的原始遮罩。
            let local = try ImagePlacement.original(source).following(placement(from: source.logicalSize, to: size, mode: mode))
            return Self(image: source.image, placement: local)
        case .path(let value, let mode):
            return try await rasterize(value.makePath(), canvas: value.coordinateSize, target: size,
                                       mode: mode, evenOdd: value.usesEvenOddFillRule)
        case .circle, .ellipse, .roundedRectangle:
            let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let path: CGPath
            switch mask {
            case .circle:
                let side = min(size.width, size.height)
                path = CGPath(ellipseIn: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                    width: side, height: side), transform: nil)
            case .roundedRectangle(let radius):
                guard radius.isFinite, (0...0.5).contains(radius) else {
                    throw PAGError.invalidArgument("maskCornerRadius")
                }
                let points = min(size.width, size.height) * radius
                path = CGPath(roundedRect: rect, cornerWidth: points, cornerHeight: points, transform: nil)
            default: path = CGPath(ellipseIn: rect, transform: nil)
            }
            return try await rasterize(path, canvas: size, target: size, mode: .stretch, evenOdd: false)
        }
    }

    /// 最长边不超过 2048 的一次性透明 RGBA 输入，后续每帧只采样 alpha；不裁剪头像像素。
    private static func rasterize(_ path: CGPath, canvas: PAGSize, target: PAGSize,
                                  mode: PAGScaleMode, evenOdd: Bool) async throws -> Self {
        let ratio = min(1, 2048 / max(canvas.width, canvas.height))
        let width = max(1, Int(ceil(canvas.width * ratio)))
        let height = max(1, Int(ceil(canvas.height * ratio)))
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: color,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PAGError.mediaFailure("maskRasterAllocation")
            }
            // CGContext 用户空间默认 y 向上；纹理首行约定为顶行，必须翻转以保留宿主路径的左上原点。
            context.translateBy(x: 0, y: Double(height))
            context.scaleBy(x: Double(width) / canvas.width, y: -Double(height) / canvas.height)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.addPath(path)
            context.drawPath(using: evenOdd ? .eoFill : .fill)
        }
        try Task.checkCancellation()
        let image = try await PAGImage.make(from: PAGImageFrame(width: width, height: height, pixels: data))
        let restore = try SceneAffine.scale(x: canvas.width / Double(width), y: canvas.height / Double(height))
        return Self(image: image, placement: try restore.following(placement(from: canvas, to: target, mode: mode)))
    }

    /// 和图片槽 .none 保持同一左上锚点；其它模式按完整逻辑画布适配。
    private static func placement(from source: PAGSize, to target: PAGSize, mode: PAGScaleMode) throws -> SceneAffine {
        if mode == .none { return .identity }
        return try SceneAffine(display: DisplayTransform(contentSize: source, targetSize: target, scale: 1, mode: mode))
    }
}
