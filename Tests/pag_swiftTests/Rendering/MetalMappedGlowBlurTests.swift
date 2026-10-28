#if os(macOS)
import Metal
import Testing
@testable import pag_swift

/// 局部Glow两轴与完整平铺纹理的GPU像素对照，验证缩小网格和边缘采样没有被裁剪改变。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalMappedGlowBlurTests {
    /// 紧致/全域内容及整数/分数显示原点均须让局部Glow逐像素匹配完整网格。
    @Test(arguments: [false, true], [false, true])
    func croppedGridMatchesFullGrid(_ fillsComposition: Bool, _ fractionalOrigin: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = try PAGSize(width: 10, height: 10)
        let matrix = fractionalOrigin ? try SceneAffine(a: 0.85, b: 0, c: 0, d: 0.85,
            tx: 0.37, ty: 0.21) : .identity
        let clip = FrameClip(size: size, matrix: matrix)
        let tile = try FrameMotionTile(SampledMotionTile(center: ScenePoint(x: 5, y: 5),
            tileWidth: 100, tileHeight: 100, outputWidth: 300, outputHeight: 300,
            mirrorEdges: false, phase: 0, horizontalPhaseShift: false), compositionSize: size)
        let glow = SampledGlow(threshold: 1, radius: 300, intensity: 1)
        let visible = try RenderBounds(left: 0, top: 0, right: 10, bottom: 10)
        let cropped = try #require(try TileGlowBulgeLayout(clip: clip, tile: tile,
            glow: glow, bulge: nil, visible: visible))
        let complete = try #require(try TileGlowBulgeLayout(clip: clip, tile: tile,
            glow: glow, bulge: nil, visible: cropped.tileBounds))
        let grid = try MappedGlowGrid(layout: cropped, glow: glow)
        let sampling = grid.sampling
        let content = fillsComposition ? RenderPixelRect(x: 0, y: 0, width: 10, height: 10) :
            RenderPixelRect(x: 2, y: 2, width: 6, height: 6)
        let source = try Self.texture(device, width: content.width, height: content.height)
        var red = [UInt8](repeating: 0, count: content.width * content.height * 4)
        for pixel in 0..<(content.width * content.height) {
            red[pixel * 4 + 2] = 255
            red[pixel * 4 + 3] = 255
        }
        red.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, content.width, content.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: content.width * 4)
        }
        let fullTile = try Self.texture(device, width: complete.sample.width,
            height: complete.sample.height)
        let localTile = try Self.texture(device, width: cropped.sample.width,
            height: cropped.sample.height)
        let fullHorizontal = try Self.texture(device, width: Int(sampling.blurWidth),
            height: Int(sampling.blurHeight))
        let fullVertical = try Self.texture(device, width: Int(sampling.blurWidth),
            height: Int(sampling.blurHeight))
        let localHorizontal = try Self.texture(device, width: grid.horizontal.width,
            height: grid.horizontal.height)
        let localVertical = try Self.texture(device, width: grid.vertical.width,
            height: grid.vertical.height)
        let pipelines = try MetalPipelines(device: device)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        try MetalMappedMotionTilePass(source: source, destination: fullTile,
            contentRect: content, layout: complete, clip: clip, tile: tile)
            .encode(commandBuffer: command, pipeline: pipelines.mappedMotionTile)
        try MetalMappedMotionTilePass(source: source, destination: localTile,
            contentRect: content, layout: cropped, clip: clip, tile: tile)
            .encode(commandBuffer: command, pipeline: pipelines.mappedMotionTile)
        try MetalGlowBlurPass(source: fullTile, destination: fullHorizontal,
            sampling: sampling, horizontal: true)
            .encode(commandBuffer: command, pipeline: pipelines.glowBlur)
        try MetalGlowBlurPass(source: fullHorizontal, destination: fullVertical,
            sampling: sampling, horizontal: false)
            .encode(commandBuffer: command, pipeline: pipelines.glowBlur)
        try MetalMappedGlowBlurPass(source: localTile, destination: localHorizontal,
            layout: cropped, grid: grid, horizontal: true)
            .encode(commandBuffer: command, pipeline: pipelines.mappedGlowBlur)
        try MetalMappedGlowBlurPass(source: localHorizontal, destination: localVertical,
            layout: cropped, grid: grid, horizontal: false)
            .encode(commandBuffer: command, pipeline: pipelines.mappedGlowBlur)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let fullPixels = Self.pixels(fullVertical)
        let localPixels = Self.pixels(localVertical)
        for y in 0..<grid.vertical.height {
            for x in 0..<grid.vertical.width {
                let sourceIndex = ((y + grid.vertical.y) * fullVertical.width
                    + x + grid.vertical.x) * 4
                let targetIndex = (y * grid.vertical.width + x) * 4
                // 完整结果和局部结果都经两次BGRA8量化，逐通道应完全相同。
                #expect(Array(fullPixels[sourceIndex..<(sourceIndex + 4)]) ==
                    Array(localPixels[targetIndex..<(targetIndex + 4)]))
            }
        }
    }

    /// 建立既可作为局部渲染目标又可被下一轴读取的共享BGRA8纹理。
    private static func texture(_ device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// 测试边界读取GPU完成后的局部纹理；播放热路径没有CPU读回。
    private static func pixels(_ texture: any MTLTexture) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }
}
#endif
