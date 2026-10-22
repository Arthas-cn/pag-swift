#if os(macOS)
import Metal
import Testing
@testable import pag_swift

/// Glow独立两轴GPU核的像素与资源前置条件；整层效果顺序仍由后续生产接线验证。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalGlowKernelTests {
    /// 原尺寸与缩小尺寸都经两个BGRA8附件执行五点核，不把半径零误当恒等效果。
    @Test(arguments: [0.0, 750.0]) func twoAxesBlurAColorPixel(_ radius: Double) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 5, height: 5, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let sampling = try GlowSampling(SampledGlow(threshold: 1, radius: radius, intensity: 1),
                                        inputWidth: 5, inputHeight: 5)
        let blurDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(sampling.blurWidth), height: Int(sampling.blurHeight), mipmapped: false)
        blurDescriptor.storageMode = .shared
        blurDescriptor.usage = [.shaderRead, .renderTarget]
        let middle = try #require(device.makeTexture(descriptor: blurDescriptor))
        let result = try #require(device.makeTexture(descriptor: blurDescriptor))
        var input = [UInt8](repeating: 0, count: 5 * 5 * 4)
        input[(2 * 5 + 2) * 4 + 2] = 255
        input[(2 * 5 + 2) * 4 + 3] = 255
        input.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 5, 5), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: 5 * 4)
        }
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pipeline = try MetalPipelines(device: device).glowBlur
        try MetalGlowBlurPass(source: source, destination: middle, sampling: sampling,
                              horizontal: true).encode(commandBuffer: command, pipeline: pipeline)
        try MetalGlowBlurPass(source: middle, destination: result, sampling: sampling,
                              horizontal: false).encode(commandBuffer: command, pipeline: pipeline)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let width = Int(sampling.blurWidth)
        let height = Int(sampling.blurHeight)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            result.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let center = (height / 2 * width + width / 2) * 4
        #expect((35...50).contains(Int(pixels[center + 2])))
        #expect(pixels[center + 2] == pixels[center + 3])
        #expect(pixels[center] == 0)
        #expect(pixels[center + 1] == 0)
    }

    /// 同一纹理不能在单轴pass同时作为采样源和颜色附件。
    @Test func sameTextureIsRejectedBeforeEncoding() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 5, height: 5, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pipeline = try MetalPipelines(device: device).glowBlur
        let sampling = try GlowSampling(SampledGlow(threshold: 1, radius: 0, intensity: 1),
                                        inputWidth: 5, inputHeight: 5)
        #expect(throws: PAGError.self) {
            try MetalGlowBlurPass(source: texture, destination: texture, sampling: sampling,
                                  horizontal: true).encode(commandBuffer: command, pipeline: pipeline)
        }
    }
}
#endif
