import CoreVideo
import Metal

/// RenderOwner独占的NV12输入，保活原始buffer和两个CVMetalTexture到最后一次GPU使用结束。
final class MetalVideoInput {
    /// 原始只读系统缓冲，不锁定CPU地址或修改附件。
    private let buffer: CVPixelBuffer
    /// Apple要求保活CV包装对象，单独保活MTLTexture不足以保证输入生命周期。
    private let lumaWrapper: CVMetalTexture
    /// 与亮度共享系统帧的色度平面包装，GPU完成前不得提前释放。
    private let chromaWrapper: CVMetalTexture
    /// 全尺寸R8亮度，包含PAG颜色和可选alpha区域。
    let luma: any MTLTexture
    /// 半尺寸RG8色度，使用.rg，不能沿用旧OpenGL的.ra通道。
    let chroma: any MTLTexture
    /// 源像素到两平面采样的只读常量，不与宿主颜色策略分叉。
    let uniforms: MetalVideoUniforms
    /// 输入像素和包装成本；同一后备存储的平面分配合计与buffer成本取较大值。
    let byteCost: Int

    /// 将已验证输入映射为纹理；失败释放交接引用，不分配RGBA转换纹理或读回像素。
    init(_ frame: VideoFrameTransfer, cache: CVMetalTextureCache) throws {
        try Task.checkCancellation()
        let buffer = try frame.take()
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2),
              CVPixelBufferGetWidthOfPlane(buffer, 0) == width,
              CVPixelBufferGetHeightOfPlane(buffer, 0) == height,
              CVPixelBufferGetWidthOfPlane(buffer, 1) == width / 2,
              CVPixelBufferGetHeightOfPlane(buffer, 1) == height / 2,
              frame.alphaStartX >= 0, frame.alphaStartY >= 0,
              Double(frame.alphaStartX) + frame.size.width <= Double(width),
              Double(frame.alphaStartY) + frame.size.height <= Double(height) else {
            throw PAGError.mediaFailure("metalVideoPlaneLayout")
        }
        let y = try Self.plane(buffer, index: 0, format: .r8Unorm, cache: cache)
        let uv = try Self.plane(buffer, index: 1, format: .rg8Unorm, cache: cache)
        guard CVMetalTextureIsFlipped(y.wrapper) == CVMetalTextureIsFlipped(uv.wrapper) else {
            throw PAGError.mediaFailure("metalVideoPlaneOrigins")
        }
        let occupied = UInt128(y.texture.allocatedSize) + UInt128(uv.texture.allocatedSize)
        guard let cost = Int(exactly: max(occupied, UInt128(frame.byteCount)) + 1024) else {
            throw PAGError.resourceLimitExceeded("metalVideoBytes")
        }
        self.buffer = buffer
        lumaWrapper = y.wrapper
        chromaWrapper = uv.wrapper
        luma = y.texture
        chroma = uv.texture
        uniforms = MetalVideoUniforms(
            colorRegion: SIMD4(Float(frame.size.width), Float(frame.size.height), 1 / Float(width), 1 / Float(height)),
            alphaRegion: SIMD4(Float(frame.alphaStartX), Float(frame.alphaStartY),
                               frame.alphaStartX != 0 || frame.alphaStartY != 0 ? 1 : 0,
                               CVMetalTextureIsFlipped(y.wrapper) ? 0 : 1)
        )
        byteCost = cost
        try Task.checkCancellation()
    }

    /// 导入一个系统平面，不请求CPU锁定或转换；包装与纹理一起交给当前owner保活。
    private static func plane(_ buffer: CVPixelBuffer, index: Int, format: MTLPixelFormat,
                              cache: CVMetalTextureCache) throws -> (wrapper: CVMetalTexture, texture: any MTLTexture) {
        var raw: CVMetalTexture?
        let width = CVPixelBufferGetWidthOfPlane(buffer, index), height = CVPixelBufferGetHeightOfPlane(buffer, index)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, index, &raw)
        guard status == kCVReturnSuccess, let raw, let texture = CVMetalTextureGetTexture(raw),
              texture.pixelFormat == format, texture.width == width, texture.height == height else {
            throw PAGError.renderingFailure("metalVideoPlane:\(status)")
        }
        return (raw, texture)
    }
}

/// Swift/MSL共用的32字节视频采样常量；颜色转换在fragment内直接作用于显示输出。
struct MetalVideoUniforms: Sendable {
    /// xy为可见颜色像素尺寸，zw为实际完整亮度平面尺寸的倒数。
    let colorRegion: SIMD4<Float>
    /// xy为PAG alpha像素偏移，z为0/1启用标志，w为底部纹理原点的0/1翻转标志。
    let alphaRegion: SIMD4<Float>
}
