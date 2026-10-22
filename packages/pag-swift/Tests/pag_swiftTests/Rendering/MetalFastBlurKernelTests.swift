#if os(macOS)
import Metal
import Testing
@testable import pag_swift

/// FastBlur的Clamp与透明边界两种单轴GPU行为，尚不代表完整Glow→FastBlur效果链。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalFastBlurKernelTests {
    /// 大sigma透明边界把64×64红输入扩到200×200，中心留红而远角保持透明。
    @Test func largeSigmaDecalExpandsLocalOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try texture(device: device, width: 64, height: 64)
        let value = try FastBlurSampling(SampledFastBlur(blurriness: 68, direction: 0,
            repeatEdgePixels: false), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        let layout = try FastBlurTextureLayout(value, width: 64, height: 64)
        #expect(layout.x.outputLength == 200 && layout.y.outputLength == 200)
        let reduced = try texture(device: device, width: layout.x.reducedLength,
                                  height: layout.y.reducedLength)
        let horizontal = try texture(device: device, width: layout.x.reducedLength,
                                     height: layout.y.reducedLength)
        let vertical = try texture(device: device, width: layout.x.reducedLength,
                                   height: layout.y.reducedLength)
        let output = try texture(device: device, width: layout.x.outputLength,
                                 height: layout.y.outputLength)
        var input = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for index in 0..<(64 * 64) {
            input[index * 4 + 2] = 255
            input[index * 4 + 3] = 255
        }
        input.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: 64 * 4)
        }
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pipelines = try MetalPipelines(device: device)
        let xInput = layout.x.sourceTransform, yInput = layout.y.sourceTransform
        try MetalFastBlurResamplePass(source: source, destination: reduced,
            transform: SIMD4(xInput.scale, yInput.scale, xInput.translate, yInput.translate),
            repeatEdgePixels: false).encode(commandBuffer: command, pipeline: pipelines.fastBlurResample)
        let xKernel = try #require(layout.x.kernel)
        let yKernel = try #require(layout.y.kernel)
        try MetalFastBlurPass(source: reduced, destination: horizontal, axis: xKernel,
            horizontal: true, shiftX: 0, shiftY: 0, repeatEdgePixels: false)
            .encode(commandBuffer: command, pipeline: pipelines.fastBlur)
        try MetalFastBlurPass(source: horizontal, destination: vertical, axis: yKernel,
            horizontal: false, shiftX: 0, shiftY: 0, repeatEdgePixels: false)
            .encode(commandBuffer: command, pipeline: pipelines.fastBlur)
        let xOutput = layout.x.outputTransform, yOutput = layout.y.outputTransform
        try MetalFastBlurResamplePass(source: vertical, destination: output,
            transform: SIMD4(xOutput.scale, yOutput.scale, xOutput.translate, yOutput.translate),
            repeatEdgePixels: false).encode(commandBuffer: command, pipeline: pipelines.fastBlurResample)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let result = pixels(of: output)
        let center = (100 * 200 + 100) * 4
        #expect(result[0] == 0 && result[1] == 0 && result[2] == 0 && result[3] == 0)
        #expect(result[center] == 0 && result[center + 1] == 0)
        #expect(result[center + 2] > 50 && result[center + 3] > 50)
        #expect(result[center + 2] == result[center + 3])
    }

    /// 真实68模糊量经缩采、两轴sigma10核和裁回后，Clamp整幅纯色仍保持原颜色。
    @Test func largeSigmaPassChainPreservesConstantClamp() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try texture(device: device, width: 5, height: 5)
        let value = try FastBlurSampling(SampledFastBlur(blurriness: 68, direction: 0,
            repeatEdgePixels: true), effectScaleX: 1, effectScaleY: 1, sourceScale: 1)
        let layout = try FastBlurTextureLayout(value, width: 5, height: 5)
        let reduced = try texture(device: device, width: layout.x.reducedLength,
                                  height: layout.y.reducedLength)
        let horizontal = try texture(device: device, width: layout.x.reducedLength,
                                     height: layout.y.reducedLength)
        let vertical = try texture(device: device, width: layout.x.reducedLength,
                                   height: layout.y.reducedLength)
        let output = try texture(device: device, width: layout.x.outputLength,
                                 height: layout.y.outputLength)
        var red = [UInt8](repeating: 0, count: 25 * 4)
        for index in 0..<25 {
            red[index * 4 + 2] = 255
            red[index * 4 + 3] = 255
        }
        red.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 5, 5), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: 20)
        }
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pipelines = try MetalPipelines(device: device)
        let xInput = layout.x.sourceTransform, yInput = layout.y.sourceTransform
        try MetalFastBlurResamplePass(source: source, destination: reduced,
            transform: SIMD4(xInput.scale, yInput.scale, xInput.translate, yInput.translate),
            repeatEdgePixels: true).encode(commandBuffer: command, pipeline: pipelines.fastBlurResample)
        let xKernel = try #require(layout.x.kernel)
        let yKernel = try #require(layout.y.kernel)
        try MetalFastBlurPass(source: reduced, destination: horizontal, axis: xKernel,
            horizontal: true, shiftX: 0, shiftY: 0, repeatEdgePixels: true)
            .encode(commandBuffer: command, pipeline: pipelines.fastBlur)
        try MetalFastBlurPass(source: horizontal, destination: vertical, axis: yKernel,
            horizontal: false, shiftX: 0, shiftY: 0, repeatEdgePixels: true)
            .encode(commandBuffer: command, pipeline: pipelines.fastBlur)
        let xOutput = layout.x.outputTransform, yOutput = layout.y.outputTransform
        try MetalFastBlurResamplePass(source: vertical, destination: output,
            transform: SIMD4(xOutput.scale, yOutput.scale, xOutput.translate, yOutput.translate),
            repeatEdgePixels: true).encode(commandBuffer: command, pipeline: pipelines.fastBlurResample)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let result = pixels(of: output)
        #expect((0..<25).allSatisfy { index in
            let pixel = index * 4
            return result[pixel] == 0 && result[pixel + 1] == 0 &&
                result[pixel + 2] == 255 && result[pixel + 3] == 255
        })
    }

    /// 源边缘为红色时，Clamp保留不透明红，透明边缘则因源外样本降低alpha。
    @Test func edgeModeChangesBoundaryPixel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try texture(device: device, width: 3, height: 1)
        let repeated = try texture(device: device, width: 3, height: 1)
        let transparent = try texture(device: device, width: 3, height: 1)
        let input = [UInt8](repeating: 255, count: 3 * 4)
        input.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 3, 1), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: 3 * 4)
        }
        let axis = try #require(try FeatherGaussianAxis.make(1))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pipeline = try MetalPipelines(device: device).fastBlur
        try MetalFastBlurPass(source: source, destination: repeated, axis: axis,
                              horizontal: true, shiftX: 0, shiftY: 0,
                              repeatEdgePixels: true).encode(commandBuffer: command, pipeline: pipeline)
        try MetalFastBlurPass(source: source, destination: transparent, axis: axis,
                              horizontal: true, shiftX: 0, shiftY: 0,
                              repeatEdgePixels: false).encode(commandBuffer: command, pipeline: pipeline)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let clamped = pixels(of: repeated)
        let decal = pixels(of: transparent)
        #expect(clamped[2] == 255 && clamped[3] == 255)
        #expect(decal[2] < 255 && decal[3] < 255)
        #expect(decal[2] == decal[3])
        #expect(decal[4 + 2] > decal[2])
    }

    /// 输出扩边坐标必须相对源偏移，且禁止同一纹理在一个pass里同时读写。
    @Test func transparentHaloAndAliasingGate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try texture(device: device, width: 1, height: 1)
        let output = try texture(device: device, width: 3, height: 1)
        let red: [UInt8] = [0, 0, 255, 255]
        red.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        let axis = try #require(try FeatherGaussianAxis.make(1))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pipeline = try MetalPipelines(device: device).fastBlur
        try MetalFastBlurPass(source: source, destination: output, axis: axis,
                              horizontal: true, shiftX: 1, shiftY: 0,
                              repeatEdgePixels: false).encode(commandBuffer: command, pipeline: pipeline)
        #expect(throws: PAGError.self) {
            try MetalFastBlurPass(source: source, destination: source, axis: axis,
                                  horizontal: true, shiftX: 0, shiftY: 0,
                                  repeatEdgePixels: false).encode(commandBuffer: command, pipeline: pipeline)
        }
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let values = pixels(of: output)
        #expect(values[2] > 0 && values[6] > values[2])
        #expect(values[2] == values[10])
        #expect(values[3] == values[2])
    }

    /// 建立可CPU检查的测试纹理；生产路径只使用池化私有附件。
    private func texture(device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// 只在测试命令完成后读取纹理字节，核对GPU像素结果。
    private func pixels(of texture: any MTLTexture) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }
}
#endif
