import Metal
import Testing
@testable import pag_swift

/// 直接在GPU计算少量覆盖标量，与Double裁剪参照比较；不创建或读取画面纹理。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalCoverageMathTests {
    /// 斜边、细三角形、反射绕序、重复裁剪和像素边重合均符合独立面积参照。
    @Test func gpuCoverageMatchesIndependentPolygonClipping() async throws {
        let owner = CoverageMathTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        var probes: [CoverageProbe] = [], edges: [SIMD4<Float>] = [], expected: [Float] = []
        let triangles: [[ScenePoint]] = [
            [ScenePoint(x: 0, y: 0), ScenePoint(x: 1, y: 0), ScenePoint(x: 0, y: 1)],
            [ScenePoint(x: -10, y: -10), ScenePoint(x: 20, y: -10), ScenePoint(x: 0, y: 20)],
            [ScenePoint(x: 0.1, y: 0.1), ScenePoint(x: 0.9, y: 0.12), ScenePoint(x: 0.4, y: 0.15)],
            [ScenePoint(x: 1, y: 0), ScenePoint(x: 2, y: 0), ScenePoint(x: 1, y: 1)],
            [ScenePoint(x: -2, y: 0.4), ScenePoint(x: 3, y: 0.4), ScenePoint(x: 0.5, y: 0.8)]
        ]
        let size = try PAGSize(width: 1, height: 1)
        let clips: [[FrameClip]] = [[], [FrameClip(size: size, matrix: .identity)],
            [FrameClip(size: size, matrix: try .translation(x: 0.5, y: 0.25))],
            [FrameClip(size: size, matrix: .identity), FrameClip(size: size, matrix: .identity)],
            [FrameClip(size: size, matrix: try SceneAffine.rotation(degrees: 37).following(.translation(x: 0.6, y: -0.1)))],
            [FrameClip(size: size, matrix: try SceneAffine.scale(x: -1, y: 1).following(.translation(x: 1, y: 0))),
             FrameClip(size: size, matrix: try .translation(x: 0.2, y: 0.3))],
            [FrameClip(size: try PAGSize(width: 1e-9, height: 1e-9), matrix: try .translation(x: 0.5, y: 0.5))]
        ]
        for clipSet in clips {
            var budget = try GeometryBudget()
            var polygon = RenderClipPolygon(bounds: try RenderBounds(left: -50, top: -50, right: 50, bottom: 50))
            for clip in clipSet { try polygon.intersect(clip, budget: &budget) }
            let packed = try polygon.packedEdges(budget: &budget), start = edges.count
            edges += packed
            for triangle in triangles {
                for reverse in [false, true] {
                    let points = reverse ? Array(triangle.reversed()) : triangle
                    for y in stride(from: -0.5, through: 1.5, by: 0.25) {
                        for x in stride(from: -0.5, through: 1.5, by: 0.25) {
                            let origin = ScenePoint(x: x, y: y)
                            probes.append(CoverageProbe(points: SIMD4(Float(points[0].x), Float(points[0].y), Float(points[1].x), Float(points[1].y)),
                                                         tail: SIMD4(Float(points[2].x), Float(points[2].y), Float(x), Float(y)),
                                                         range: SIMD4(UInt32(start), UInt32(packed.count), 0, 0)))
                            expected.append(Float(try referenceArea(points, origin: origin, clips: clipSet)))
                        }
                    }
                }
            }
        }
        try await owner.verify(probes, edges: edges, expected: expected)
    }

    /// 真实字形的BVH查询与面积合并一致，孔洞与内部三角形接缝不产生重复覆盖。
    @Test func realGlyphBVHCoversPixelsWithoutInternalSeams() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let text = try #require(scene.texts.values.first)
        let owner = CoverageMathTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        var cache = try RenderGeometryCache()
        for glyph in text.glyphs.prefix(2) {
            for outline in [glyph.fill, glyph.stroke].compactMap({ $0 }) {
                var budget = try GeometryBudget()
                let mesh = try cache.mesh(for: .glyph(outline), transform: .identity, budget: &budget)
                let transforms = [SceneAffine.identity, try SceneAffine(a: -1, b: 0.5, c: 0.25, d: 1, tx: 17.25, ty: -9.5)]
                for transform in transforms {
                    let world = try mesh.vertices.map { point in
                        try transform.applying(to: ScenePoint(x: Double(Float(point.x)), y: Double(Float(point.y))))
                    }
                    let xs = world.map(\.x), ys = world.map(\.y)
                    let minX = try #require(xs.min()), maxX = try #require(xs.max())
                    let minY = try #require(ys.min()), maxY = try #require(ys.max())
                    var queries: [SIMD2<Float>] = [], expected: [Float] = []
                    for sample in 0..<256 {
                        let x = Float(minX - 1 + (maxX - minX + 2) * (Double(sample) * 0.61803398875).truncatingRemainder(dividingBy: 1))
                        let y = Float(minY - 1 + (maxY - minY + 2) * (Double(sample) * 0.41421356237 + 0.17).truncatingRemainder(dividingBy: 1))
                        queries.append(SIMD2(x, y))
                        let origin = ScenePoint(x: Double(x), y: Double(y))
                        var area = 0.0
                        for index in stride(from: 0, to: mesh.vertices.count, by: 3) {
                            // 参照实际上传Float三角形，区别于更早的曲线近似误差测试。
                            let points = Array(world[index..<(index + 3)])
                            area += try referenceArea(points, origin: origin, clips: [])
                        }
                        expected.append(Float(min(1, area)))
                    }
                    try await owner.verifyMesh(mesh, transform: transform, queries: queries, expected: expected)
                }
            }
        }
    }

    /// 独立Double参照：把三角形逐边裁成真实多边形，再用鞋带面积；不使用GPU的边段积分算法。
    private func referenceArea(_ triangle: [ScenePoint], origin: ScenePoint, clips: [FrameClip]) throws -> Double {
        var vertices = triangle
        var boundaries = [[origin, ScenePoint(x: origin.x + 1, y: origin.y),
                           ScenePoint(x: origin.x + 1, y: origin.y + 1), ScenePoint(x: origin.x, y: origin.y + 1)]]
        for clip in clips {
            var corners = try [ScenePoint.zero, ScenePoint(x: clip.size.width, y: 0),
                               ScenePoint(x: clip.size.width, y: clip.size.height), ScenePoint(x: 0, y: clip.size.height)]
                .map { try clip.matrix.applying(to: $0) }
            if clip.matrix.a * clip.matrix.d - clip.matrix.b * clip.matrix.c < 0 { corners.reverse() }
            boundaries.append(corners)
        }
        for boundary in boundaries {
            for index in boundary.indices {
                guard !vertices.isEmpty else { return 0 }
                let a = boundary[index], b = boundary[(index + 1) % boundary.count]
                var output: [ScenePoint] = [], previous = vertices[vertices.count - 1]
                var previousDistance = cross(a, b, previous)
                for current in vertices {
                    let distance = cross(a, b, current)
                    if (previousDistance < 0) != (distance < 0) {
                        let t = previousDistance / (previousDistance - distance)
                        output.append(ScenePoint(x: previous.x + t * (current.x - previous.x), y: previous.y + t * (current.y - previous.y)))
                    }
                    if distance >= 0 { output.append(current) }
                    previous = current
                    previousDistance = distance
                }
                vertices = output
            }
        }
        guard vertices.count > 2 else { return 0 }
        var sum = 0.0
        for index in vertices.indices {
            let a = vertices[index], b = vertices[(index + 1) % vertices.count]
            sum += (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
        }
        return abs(sum) * 0.5
    }

    /// 参照半平面判定使用Double原始边差，不复用生产打包系数。
    private func cross(_ a: ScenePoint, _ b: ScenePoint, _ point: ScenePoint) -> Double {
        (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
    }
}

/// 与测试compute kernel共享的48字节纯值输入，不携带资源引用。
private struct CoverageProbe: Sendable {
    /// 三角形前两个世界坐标顶点。
    let points: SIMD4<Float>
    /// 第三个顶点以及当前单位像素的左上角。
    let tail: SIMD4<Float>
    /// 裁剪边数组的起点、数量与两个零填充。
    let range: SIMD4<UInt32>
}

/// 数值测试的GPU独占域，完成回调只恢复空值continuation。
private actor CoverageMathTestOwner {
    /// sending转交的真实设备，只在本actor使用。
    private let device: any MTLDevice
    /// 网格内核在同一测试owner中仅编译一次，nil表示尚未验证真实字形。
    private var meshPipeline: (any MTLComputePipelineState)?

    /// 接收设备所有权，不向测试调用者返回裸资源。
    init(device: sending any MTLDevice) { self.device = device }

    /// 运行共享生产数学函数并读取标量结果；不进行窗口截图、颜色纹理或播放像素读回。
    func verify(_ probes: [CoverageProbe], edges: [SIMD4<Float>], expected: [Float]) async throws {
        let source = "#include <metal_stdlib>\nusing namespace metal;\n" + MetalCoverageMath.source + """
        /// 与Swift侧CoverageProbe布局一致的数值输入。
        struct Probe {
            /// 三角形前两个世界坐标顶点。
            float4 points;
            /// 第三个顶点和当前像素左上角。
            float4 tail;
            /// 裁剪边数组的起点、数量和零填充。
            uint4 range;
        };
        /// 只输出覆盖标量，验证同一份未来片元数学内核。
        kernel void verifyCoverage(const device Probe *probes [[buffer(0)]],
                                   const device float4 *clips [[buffer(1)]],
                                   device float *output [[buffer(2)]], uint index [[thread_position_in_grid]]) {
            Probe p = probes[index];
            output[index] = pagClippedTriangleArea(p.points.xy, p.points.zw, p.tail.xy, p.tail.zw,
                                                   clips + p.range.x, p.range.y);
        }
        """
        let pipeline = try makePipeline(source)
        let input = try buffer(probes), clipBuffer = try buffer(edges)
        let output = try #require(device.makeBuffer(length: expected.count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue()), command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(clipBuffer, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: probes.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed)
        let results = output.contents().bindMemory(to: Float.self, capacity: expected.count)
        var maximumError: Float = 0
        for index in expected.indices {
            let error = abs(results[index] - expected[index])
            #expect(results[index].isFinite && error < 0.0001, "probe \(index): GPU=\(results[index]), reference=\(expected[index])")
            maximumError = max(maximumError, error)
        }
        #expect(maximumError < 0.0001)
    }

    /// 真实网格与前序索引作为只读输入，GPU返回有限个覆盖标量，不产出帧图像。
    func verifyMesh(_ mesh: RenderMesh, transform: SceneAffine, queries: [SIMD2<Float>], expected: [Float]) async throws {
        let source = "#include <metal_stdlib>\nusing namespace metal;\n" + MetalCoverageMath.source + """
        /// 使用与片元一致的BVH函数，以给定仿射变换独立检查查找与同填充面积求和。
        kernel void verifyCoverage(const device PAGCoverageVertex *vertices [[buffer(0)]],
                                   const device PAGCoverageNode *nodes [[buffer(1)]],
                                   const device uint *triangles [[buffer(2)]],
                                   const device float2 *queries [[buffer(3)]],
                                   device float *output [[buffer(4)]], constant uint &count [[buffer(5)]],
                                   constant float4 *matrix [[buffer(6)]], uint index [[thread_position_in_grid]]) {
            output[index] = pagMeshArea(queries[index], matrix[0], matrix[1], matrix[2],
                                        vertices, nodes, triangles, count, (const device float4 *)vertices, 0);
        }
        """
        if meshPipeline == nil { meshPipeline = try makePipeline(source) }
        let pipeline = try #require(meshPipeline)
        var budget = try GeometryBudget()
        let index = try RenderCoverageIndex.prepare(mesh, budget: &budget)
        let vertices = mesh.vertices.map { MetalVertex(position: SIMD2(Float($0.x), Float($0.y)), textureCoordinate: .zero) }
        let vertexBuffer = try buffer(vertices), nodes = try buffer(index.nodes), triangles = try buffer(index.triangles)
        let inputs = try buffer(queries)
        let determinant = transform.a * transform.d - transform.b * transform.c
        let matrix = try buffer([
            MetalDrawUniforms.finite(transform.a, transform.c, transform.tx, 0),
            MetalDrawUniforms.finite(transform.b, transform.d, transform.ty, 0),
            MetalDrawUniforms.finite(transform.d / determinant, -transform.c / determinant, -transform.b / determinant, transform.a / determinant)
        ])
        let output = try #require(device.makeBuffer(length: expected.count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue()), command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (slot, resource) in [vertexBuffer, nodes, triangles, inputs, output].enumerated() {
            encoder.setBuffer(resource, offset: 0, index: slot)
        }
        var count = UInt32(index.nodes.count)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 5)
        encoder.setBuffer(matrix, offset: 0, index: 6)
        encoder.dispatchThreads(MTLSize(width: queries.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed)
        let results = output.contents().bindMemory(to: Float.self, capacity: expected.count)
        for i in expected.indices {
            #expect(results[i].isFinite && abs(results[i] - expected[i]) < 0.0001,
                    "glyph sample \(i): GPU=\(results[i]), reference=\(expected[i])")
        }
    }

    /// 同步编译留在测试owner隔离域，避免SDK异步重载把非Sendable管线从其他执行域传回。
    private func makePipeline(_ source: String) throws -> any MTLComputePipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "verifyCoverage"))
        return try device.makeComputePipelineState(function: function)
    }

    /// 测试的CPU输入和GPU标量输出使用shared buffer，不影响库的纹理存储策略。
    private func buffer<Value>(_ values: [Value]) throws -> any MTLBuffer {
        let buffer = values.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        }
        return try #require(buffer)
    }
}
