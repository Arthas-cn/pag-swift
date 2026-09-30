import Metal
import Testing
@testable import pag_swift

/// 对共享生产MSL读取有限数值buffer；不创建帧纹理或给播放器增加像素读回能力。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"), .timeLimit(.minutes(1)))
struct MetalGradientMathTests {
    /// 透明红到不透明蓝必须先插值未预乘色，再得到四通道(.25,0,.25,.5)。
    @Test func singleColorProgramInterpolatesBeforePremultiplication() async throws {
        let colors = GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)])
        let input = try uniforms(colors)
        let probes = [SIMD4<Float>(-1, 0, 1, 0), SIMD4(0.5 - 0.00001, 0, 1, 0), SIMD4(2, 0, 1, 0)]
        try await GradientMathOwner(device: #require(MTLCreateSystemDefaultDevice())).verify(input, probes: probes,
            expected: [.zero, SIMD4(0.25, 0, 0.25, 0.5), SIMD4(0, 0, 1, 1)])
    }

    /// 固定数组的八段全部可访问，各中值使用独立字节平均；边界等号严格进入右段。
    @Test func eightIntervalsAndHardstopEqualityUsePackedLayout() async throws {
        let rgb: [(Float, SceneColor)] = (0...8).map { (index: Int) in
            let red = UInt8(index * index * 3)
            let green = UInt8(255 - index * 20)
            let blue = UInt8(index % 2 * 255)
            return (Float(index) / 8, SceneColor(red: red, green: green, blue: blue))
        }
        let input = try uniforms(GradientColorFixtures.colors(rgb: rgb))
        #expect(input.header.y == 1 && input.header.z == 8)
        let probes = (0..<8).map { SIMD4<Float>((Float($0) + 0.5) / 8, 0, 0, 0) }
        let expected: [SIMD4<Float>] = (0..<8).map { (index: Int) in
            let red = Float(index * index * 3 + (index + 1) * (index + 1) * 3) / 510
            let green = Float(245 - index * 20) / 255
            return SIMD4(red, green, 0.5, 1)
        }
        let owner = GradientMathOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verify(input, probes: probes, expected: expected)
        // 直接构造有界语义程序，只验证MSL区间契约，不冒充解码出的PAG色标。
        let red = SIMD4<Float>(1, 0, 0, 1), green = SIMD4<Float>(0, 1, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1)
        let hardstop: GradientColorizerProgram = .intervals([
            .init(upperBound: 0.25, scale: .zero, bias: red), .init(upperBound: 0.5, scale: .zero, bias: green),
            .init(upperBound: 1, scale: .zero, bias: blue)])
        let abrupt = try uniforms(GradientColorFixtures.colors(), program: hardstop)
        let boundary: [Float] = [0, Float(0.25).nextDown, 0.25, Float(0.5).nextDown, 0.5, 1]
        try await owner.verify(abrupt, probes: boundary.map { SIMD4($0, 0, 0, 0) },
                               expected: [red, red, green, green, blue, blue])
    }

    /// 合同中的shear、非均匀缩放及Double原点补偿，在GPU只执行一次最终映射。
    @Test(arguments: [SourceGradientKind.linear, .radial])
    func mappedCoordinatesUseIndependentShearGolden(_ kind: SourceGradientKind) async throws {
        let input = try uniforms(GradientColorFixtures.colors(), kind: kind,
            matrix: SceneAffine(a: 2, b: 0, c: 1, d: 4, tx: 8, ty: 16),
            end: ScenePoint(x: 4, y: 0), origin: ScenePoint(x: 8, y: 16))
        let t: Float = kind == .linear ? 0.375 + 0.00001 : Float(13).squareRoot() / 8
        try await GradientMathOwner(device: #require(MTLCreateSystemDefaultDevice())).verify(input,
            probes: [SIMD4(4, 4, 1, 0)], expected: [SIMD4(1 - t, 0, t, 1)])
    }

    /// 使用生产颜色编译与打包；可显式提供语义程序隔离验证GPU数组和严格阈值。
    private func uniforms(_ colors: SourceGradientColors, kind: SourceGradientKind = .linear,
                          matrix: SceneAffine = .identity, end: ScenePoint = ScenePoint(x: 1, y: 0), origin: ScenePoint = .zero,
                          program: GradientColorizerProgram? = nil) throws -> MetalGradientUniforms {
        let compiled = try GradientColorFixtures.compile(colors)
        let colorizer = program.map {
            PreparedGradientColorizer(source: colors, first: compiled.first, last: compiled.last,
                                      result: .analytic($0), estimatedBytes: compiled.estimatedBytes)
        } ?? compiled
        let gradient = PreparedGradient(kind: kind, start: .zero, end: end, matrix: matrix,
                                        colorizer: colorizer, estimatedBytes: colorizer.estimatedBytes + 256)
        var budget = try MetalFrameBudget()
        guard case .analytic(let input) = try MetalGradientInput.make(gradient, origin: origin, budget: &budget) else {
            throw PAGError.invalidArgument("expectedAnalyticGradient")
        }
        return input
    }
}

/// 专属数值测试actor，系统对象不跨隔离，只回传测试断言结果。
private actor GradientMathOwner {
    /// 一次性接收的设备，不与调用域保留可变别名。
    let device: any MTLDevice

    /// 转交设备所有权，后续Metal编译和buffer访问在此域执行。
    init(device: sending any MTLDevice) { self.device = device }

    /// 直接运行生产数学，以常量区绑定真实464字节Swift值；只读取少量返回向量。
    func verify(_ input: MetalGradientUniforms, probes: [SIMD4<Float>], expected: [SIMD4<Float>]) async throws {
        let pipeline = try makePipeline()
        let values = try #require(probes.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        })
        let output = try #require(device.makeBuffer(length: expected.count * 16, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue()), command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        var uniforms = input
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<MetalGradientUniforms>.stride, index: 0)
        encoder.setBuffer(values, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: probes.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(32, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed)
        let result = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: expected.count)
        for index in expected.indices {
            for channel in 0..<4 {
                #expect(result[index][channel].isFinite && abs(result[index][channel] - expected[index][channel]) < 0.000002,
                        "probe \(index), channel \(channel)")
            }
        }
    }

    /// 同步编译保持裸对象留在此actor；计算入口只决定调用颜色分段或完整映射。
    private func makePipeline() throws -> any MTLComputePipelineState {
        let source = "#include <metal_stdlib>\nusing namespace metal;\n" + MetalGradientMath.source + """
        /// probes.z为0时x直接是t，为1时xy是网格相对坐标；输出只用于数值测试。
        kernel void verifyGradient(constant PAGGradientUniforms &gradient [[buffer(0)]],
                                    const device float4 *probes [[buffer(1)]], device float4 *output [[buffer(2)]],
                                    uint index [[thread_position_in_grid]]) {
            float4 probe = probes[index];
            output[index] = probe.z == 0 ? pagGradientColor(probe.x, gradient) : pagGradientSample(probe.xy, gradient);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        return try device.makeComputePipelineState(function: #require(library.makeFunction(name: "verifyGradient")))
    }
}
