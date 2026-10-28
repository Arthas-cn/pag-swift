import Testing
@testable import pag_swift

/// 同帧父链求值与单调用缓存；包括非可见控制父层和深链，不把父链当合成包含关系。
struct LayerTransformSamplerTests {
    /// 父层即使 inactive、透明且不在自身可见区间，仍按孩子的所属合成帧贡献矩阵。
    @Test func parentTransformUsesSameCompositionFrameOnly() throws {
        let animated = SourceTransformProperties(
            anchor: SourceProperty(constant: .zero),
            position: .separated(x: try linear(0, 100), y: SourceProperty(constant: 0)),
            scale: SourceProperty(constant: .one), rotation: SourceProperty(constant: 0), opacity: SourceProperty(constant: 0))
        let layers = [
            SceneFixtures.layer(20, parent: 10, start: 5, duration: 10, transform: translated(7, opacity: 128)),
            SceneFixtures.layer(30, transform: translated(3)),
            SceneFixtures.layer(10, parent: 30, start: 100, duration: 1, active: false, transform: animated)
        ]
        let source = try SceneFixtures.composition(1, layers: layers)
        let file = try SceneFixtures.build([source])
        var sampler = LayerTransformSampler(source: source, topology: file.storage.topologies[0], frame: 7)
        let child = try sampler.transform(for: 0)
        #expect(abs(child.matrix.tx - 80) < 1e-6 && child.matrix.ty == 0)
        #expect(child.opacity == Double(128) / 255)
        #expect(try sampler.transform(for: 2).opacity == 0)
        #expect(try sampler.transform(for: 0) == child)
    }

    /// 新一帧必须建立自己的采样器；共享父源属性不会让上一帧缓存或另一任务覆盖当前结果。
    @Test func independentSamplingHasNoSharedCursor() async throws {
        let animated = SourceTransformProperties(
            anchor: SourceProperty(constant: .zero),
            position: .separated(x: try linear(0, 100), y: SourceProperty(constant: 0)),
            scale: SourceProperty(constant: .one), rotation: SourceProperty(constant: 0), opacity: SourceProperty(constant: 255))
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, transform: animated)])
        let file = try SceneFixtures.build([source])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for frame: Int64 in [7, 2, 10, 0, 5] {
                group.addTask {
                    var sampler = LayerTransformSampler(source: source, topology: file.storage.topologies[0], frame: frame)
                    let value = try sampler.transform(for: 0)
                    #expect(abs(value.matrix.tx - Double(frame) * 10) < 1e-5)
                }
            }
            try await group.waitForAll()
        }
    }

    /// 两千级控制父链用显式路径展开；末层累计平移正确，重复请求复用同次结果。
    @Test func deepChainIsIterative() throws {
        let count = 2000
        let layers = (0..<count).map { index in
            SceneFixtures.layer(UInt32(index + 1), parent: index == 0 ? nil : UInt32(index), transform: translated(1))
        }
        let source = try SceneFixtures.composition(1, layers: layers)
        let file = try SceneFixtures.build([source])
        var sampler = LayerTransformSampler(source: source, topology: file.storage.topologies[0], frame: 0)
        #expect(try sampler.transform(for: count - 1).matrix.tx == Double(count))
        #expect(try sampler.transform(for: 999).matrix.tx == 1000)
    }

    /// 已取消的求值即使可以命中本次缓存，也不继续向调用方发布结果。
    @Test func cancellationWinsOverCachedResult() async throws {
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1)])
        let file = try SceneFixtures.build([source])
        let task = Task {
            var sampler = LayerTransformSampler(source: source, topology: file.storage.topologies[0], frame: 0)
            _ = try sampler.transform(for: 0)
            withUnsafeCurrentTask { $0?.cancel() }
            return try sampler.transform(for: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 构造语义图使用的 [0,10] 线性标量轨道，不生成 PAG 字节。
    private func linear(_ start: Double, _ end: Double) throws -> SourceProperty<Double> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10, startValue: start,
                                                     endValue: end, easing: .linear, spatialCurve: nil)])
    }

    /// 创建只有水平位移和指定自身 opacity 的常量变换，供父链数值断言。
    private func translated(_ x: Double, opacity: UInt8 = 255) -> SourceTransformProperties {
        SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: ScenePoint(x: x, y: 0), scale: .one,
                                                            rotation: 0, opacity: opacity))
    }
}
