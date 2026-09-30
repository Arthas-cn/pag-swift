import Metal
import Testing
@testable import pag_swift

/// GPU数值验收只读取少量标量buffer，不创建或读取播放画面，参照来自上游颜色/坐标公式。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"), .timeLimit(.minutes(1)))
struct MetalVideoMathTests {
    /// 合法/越界YUV、透明度上下界、218分母和先钳制再预乘，在GPU上符合独立Double参照。
    @Test func conversionMatchesSourceColorAndAlphaRules() async throws {
        var probes: [VideoMathProbe] = [], expected: [SIMD4<Float>] = []
        let unused = MetalVideoUniforms(colorRegion: .one, alphaRegion: .zero)
        for y in [0, 16, 17, 128, 235, 255] {
            for u in [0, 16, 128, 240, 255] {
                for v in [0, 16, 128, 240, 255] {
                    for alpha in [0, 16, 17, 125, 233, 234, 235, 255] {
                        for enabled in [false, true] {
                            let input = SIMD4(Float(y), Float(u), Float(v), Float(alpha)) / 255
                            probes.append(VideoMathProbe(values: input, selection: SIMD4(0, enabled ? 1 : 0, 0, 0), video: unused))
                            let luma = Double(input.x) - 16.0 / 255
                            let cb = Double(input.y) - 0.5, cr = Double(input.z) - 0.5
                            let channels = [1.164384 * luma + 1.596027 * cr,
                                            1.164384 * luma - 0.391762 * cb - 0.812968 * cr,
                                            1.164384 * luma + 2.017232 * cb]
                            let a = enabled ? min(1, max(0, (Double(input.w) * 255 - 16) / 218)) : 1
                            let values = channels.map { Float(min(1, max(0, $0)) * a) }
                            expected.append(SIMD4(values[0], values[1], values[2], Float(a)))
                        }
                    }
                }
            }
        }
        #expect(probes.count == 2400)
        try await VideoMathTestOwner(device: #require(MTLCreateSystemDefaultDevice())).verify(probes, expected: expected)
    }

    /// 左右/上下alpha、奇数可见宽、单像素区域和两种原点，都先夹到半像素内侧再作完整平面映射。
    @Test func coordinatesPreserveRegionAndTextureOrigin() async throws {
        let layouts = [(720, 1080, 720, 0, 1440, 1080), (1280, 720, 0, 720, 1280, 1440),
                       (405, 720, 406, 0, 812, 720), (720, 333, 0, 0, 720, 334), (1, 1, 1, 1, 2, 2)]
        var probes: [VideoMathProbe] = [], expected: [SIMD4<Float>] = []
        for (width, height, x, y, fullWidth, fullHeight) in layouts {
            for flip in [false, true] {
                let video = MetalVideoUniforms(colorRegion: SIMD4(Float(width), Float(height), 1 / Float(fullWidth), 1 / Float(fullHeight)),
                    alphaRegion: SIMD4(Float(x), Float(y), x == 0 && y == 0 ? 0 : 1, flip ? 1 : 0))
                for u: Float in [-2, 0, 0.001, 0.5, 0.999, 1, 2] {
                    for v: Float in [-2, 0, 0.001, 0.5, 0.999, 1, 2] {
                        probes.append(VideoMathProbe(values: SIMD4(u, v, 0, 0), selection: SIMD4(1, 0, 0, 0), video: video))
                        let px = min(Double(width) - 0.5, max(0.5, Double(u) * Double(width)))
                        let py = min(Double(height) - 0.5, max(0.5, Double(v) * Double(height)))
                        let top = py / Double(fullHeight), alphaTop = (py + Double(y)) / Double(fullHeight)
                        expected.append(SIMD4(Float(px / Double(fullWidth)), Float(flip ? 1 - top : top),
                                              Float((px + Double(x)) / Double(fullWidth)), Float(flip ? 1 - alphaTop : alphaTop)))
                    }
                }
            }
        }
        #expect(probes.count == 490)
        try await VideoMathTestOwner(device: #require(MTLCreateSystemDefaultDevice())).verify(probes, expected: expected)
    }
}

/// 数值内核的64字节输入，全部字段都是可发送标量，不包含纹理或像素缓冲。
private struct VideoMathProbe: Sendable {
    /// 颜色测试为Y/U/V/alpha，坐标测试前两个值为可见区域UV。
    let values: SIMD4<Float>
    /// x为0颜色/1坐标选择，y为颜色测试的alpha开关，zw固定0。
    let selection: SIMD4<Float>
    /// 与生产Swift/MSL共用的采样参数。
    let video: MetalVideoUniforms
}

/// 专属GPU数值测试域，系统对象不跨actor，完成回调只恢复空值。
private actor VideoMathTestOwner {
    /// 一次性转交的测试设备，不归主actor所有。
    private let device: any MTLDevice

    /// 接收断开其他隔离域别名的设备。
    init(device: sending any MTLDevice) { self.device = device }

    /// 运行共享生产数学，GPU完成后读取有限数值，与Double参照比较，不构造整帧图像。
    func verify(_ probes: [VideoMathProbe], expected: [SIMD4<Float>]) async throws {
        let source = "#include <metal_stdlib>\nusing namespace metal;\n" + MetalVideoMath.source + """
        /// 与Swift的VideoMathProbe布局一致。
        struct Probe {
            /// Y/U/V/alpha或可见UV。
            float4 values;
            /// 模式与alpha开关。
            float4 selection;
            /// 真实生产采样常量。
            PAGVideoUniforms video;
        };
        /// 只返回数值向量，直接调用生产数学函数。
        kernel void verifyVideo(const device Probe *probes [[buffer(0)]], device float4 *output [[buffer(1)]],
                                 uint index [[thread_position_in_grid]]) {
            Probe probe = probes[index];
            output[index] = probe.selection.x == 0 ? pagVideoColor(probe.values.xyz, probe.values.w, probe.selection.y != 0)
                                                     : pagVideoCoordinates(probe.values.xy, probe.video);
        }
        """
        let pipeline = try makePipeline(source)
        let input = probes.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        }
        let inputBuffer = try #require(input)
        let output = try #require(device.makeBuffer(length: expected.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue()), command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: probes.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed)
        let result = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: expected.count)
        for index in expected.indices {
            for channel in 0..<4 {
                #expect(result[index][channel].isFinite && abs(result[index][channel] - expected[index][channel]) < 0.00001,
                        "probe \(index) channel \(channel)")
            }
        }
    }

    /// 同步编译留在当前owner，避免SDK异步重载返回非Sendable管线。
    private func makePipeline(_ source: String) throws -> any MTLComputePipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        return try device.makeComputePipelineState(function: #require(library.makeFunction(name: "verifyVideo")))
    }
}
