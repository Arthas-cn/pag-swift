#if os(macOS)
import Metal
import Testing
@testable import pag_swift

/// 预合成平铺在完整域重复紧致内容的实际GPU像素，及局部附件映射边界。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalMappedMotionTileTests {
    /// 中央和相邻平铺块取同一红色内容，原预合成内容矩形外保持透明。
    @Test func compactContentRepeatsInSemanticOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sourceSize = try PAGSize(width: 10, height: 10)
        let clip = FrameClip(size: sourceSize, matrix: .identity)
        let tile = try FrameMotionTile(SampledMotionTile(center: ScenePoint(x: 5, y: 5),
            tileWidth: 100, tileHeight: 100, outputWidth: 300, outputHeight: 300,
            mirrorEdges: false, phase: 0, horizontalPhaseShift: false), compositionSize: sourceSize)
        let visible = try RenderBounds(left: 0, top: 0, right: 10, bottom: 10)
        let layout = try #require(try TileGlowBulgeLayout(clip: clip, tile: tile,
            glow: SampledGlow(threshold: 1, radius: 0, intensity: 1),
            bulge: nil, visible: visible))
        let contentRect = RenderPixelRect(x: 2, y: 2, width: 6, height: 6)
        let input = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 6, height: 6, mipmapped: false)
        input.storageMode = .shared
        input.usage = [.shaderRead, .renderTarget]
        let source = try #require(device.makeTexture(descriptor: input))
        let resultDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: layout.sample.width, height: layout.sample.height, mipmapped: false)
        resultDescriptor.storageMode = .shared
        resultDescriptor.usage = [.shaderRead, .renderTarget]
        let result = try #require(device.makeTexture(descriptor: resultDescriptor))
        let red = [UInt8](repeating: 0, count: 6 * 6 * 4).enumerated().map { index, _ in
            index % 4 >= 2 ? UInt8(255) : UInt8(0)
        }
        red.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 6, 6), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 24)
        }
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        try MetalMappedMotionTilePass(source: source, destination: result,
            contentRect: contentRect, layout: layout, clip: clip, tile: tile)
            .encode(commandBuffer: command, pipeline: MetalPipelines(device: device).mappedMotionTile)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: layout.sample.width * layout.sample.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            result.getBytes(bytes.baseAddress!, bytesPerRow: layout.sample.width * 4,
                from: MTLRegionMake2D(0, 0, layout.sample.width, layout.sample.height), mipmapLevel: 0)
        }
        // 第二块落在显示范围外但位于Bulge/Glow采样halo内，证明局部附件未重定义平铺周期。
        let center = ((5 - layout.sample.y) * layout.sample.width + 5 - layout.sample.x) * 4
        let repeated = ((5 - layout.sample.y) * layout.sample.width + 15 - layout.sample.x) * 4
        let empty = ((5 - layout.sample.y) * layout.sample.width - layout.sample.x) * 4
        #expect(pixels[center + 2] == 255)
        #expect(pixels[center + 3] == 255)
        #expect(pixels[repeated + 2] == 255)
        #expect(pixels[repeated + 3] == 255)
        #expect(pixels[empty + 3] == 0)
    }
}
#endif
