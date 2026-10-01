import Metal
import Testing
@testable import pag_swift

/// 真实圆环在不同播放历史后定位同帧，源几何与GPU输入必须一致；隔离缓存与宿主呈现问题。
struct TrimFileHistoryTests {
    /// 模拟首帧、1秒定位、继续播放、反向seek及重复2秒请求，和冷准备的全部网格逐点比较。
    @Test func circleGeometryDoesNotDependOnPlaybackHistory() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "wstask_circle.pag"))
        let cold = try await PreparedScene.prepare(file.composition)
        let expected = try await frame(cold, at: 48)
        let reference = try TrimHistoryMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
        let expectedMeshes = try await reference.meshes(expected)
        for history: [Int64] in [[0, 1, 24, 25, 26, 48, 48], [0, 10, 24, 25, 0, 47, 48], [100, 20, 48]] {
            let scene = try await PreparedScene.prepare(file.composition)
            let owner = try TrimHistoryMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
            for number in history {
                let actual = try await frame(scene, at: number)
                let meshes = try await owner.meshes(actual)
                guard number == 48 else { continue }
                #expect(actual.plan.time.representedTime == PAGTime(microseconds: 2_000_000))
                #expect(actual.shapes.keys == expected.shapes.keys)
                for (key, geometry) in actual.shapes {
                    let original = try #require(expected.shapes[key])
                    #expect(geometry.stroke == original.stroke && geometry.contours.count == original.contours.count)
                    for (a, b) in zip(geometry.contours, original.contours) {
                        var budget = try GeometryBudget()
                        let first = try TrimPathConversion.make(a, budget: &budget)
                        let second = try TrimPathConversion.make(b, budget: &budget)
                        #expect(first.verbs == second.verbs && first.points == second.points)
                    }
                }
                try #require(meshes.count == expectedMeshes.count)
                for (a, b) in zip(meshes, expectedMeshes) {
                    #expect(a.origin == b.origin && a.vertices == b.vertices)
                }
            }
        }
    }

    /// 固定300×100点、3倍显示，使用真实文件的源帧率，不在测试重写时间采样。
    private func frame(_ scene: PreparedScene, at number: Int64) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene,
            at: SceneValidator.time(frame: number, rate: scene.composition.frameRate),
            targetSize: PAGSize(width: 300, height: 100), scale: 3, mode: .aspectFit)
    }
}

/// 每个播放历史独占一份真实Metal缓存，只把不可变CPU网格证据送回测试域。
private actor TrimHistoryMetalOwner {
    /// CPU与GPU输入保持生产的双层LRU，不在帧间清空来掩盖复用错误。
    private let resources: MetalResources

    /// 接收设备所有权并按生产默认额度建缓存。
    init(device: sending any MTLDevice) throws { resources = try MetalResources(device: device) }

    /// 准备实际GPU输入并取其被保活来源，返回前释放所有未提交附件。
    func meshes(_ frame: PreparedFrame) throws -> [RenderMesh] {
        let batch = try MetalFramePreparation.prepare(frame, width: 900, height: 300, resources: resources)
        defer { batch.releaseTransients() }
        return batch.passes.flatMap(\.draws).map { $0.mesh.source }
    }
}
