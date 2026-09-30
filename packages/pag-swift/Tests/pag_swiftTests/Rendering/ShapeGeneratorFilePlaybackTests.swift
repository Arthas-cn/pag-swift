import Foundation
import Testing
@testable import pag_swift

/// 新开放生成器的真实完整文件验收；字段成功与整文件显示分别验证。
struct ShapeGeneratorFilePlaybackTests {
    /// TextDirection完整载入后仍含真实Star节点，不能通过删掉不认识的内容得到成功。
    @Test func completeFileRetainsStar() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextDirection.pag"))
        var count = 0
        for composition in file.storage.compositions {
            for layer in composition.layers {
                guard case .shape(let elements) = layer.content else { continue }
                count += starCount(in: elements)
            }
        }
        #expect(count == 1)
        _ = try await PreparedScene.prepare(file.composition)
    }

    /// 新完整文件在三种尺寸/倍率逐源帧准备，捕获首/中/末抽样无法发现的中间几何错误。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_GENERATOR_FRAME_AUDIT"] == "1",
                   "设置PAG_GENERATOR_FRAME_AUDIT=1遍历生成器完整文件全部源帧"), .timeLimit(.minutes(5)))
    func allSourceFramesPrepareGeometry() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextDirection.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let displays: [(PAGSize, Double, PAGScaleMode)] = try [
            (PAGSize(width: 500, height: 220), 2, .aspectFit),
            (PAGSize(width: 200, height: 150), 1, .aspectFit),
            (PAGSize(width: 750, height: 500), 3, .stretch)
        ]
        var combinations = 0
        for (size, scale, mode) in displays {
            var cache = try RenderGeometryCache()
            for frame in 0..<root.durationFrames {
                do {
                    let prepared = try await FramePlanner.prepare(scene,
                        at: SceneValidator.time(frame: frame, rate: root.frameRate),
                        targetSize: size, scale: scale, mode: mode)
                    for command in prepared.plan.commands {
                        guard case .shape(let shape) = command else { continue }
                        let source = try #require(prepared.shapes[shape.geometryID])
                        var budget = try GeometryBudget()
                        _ = try cache.mesh(for: .shape(source), transform: shape.matrix, budget: &budget)
                    }
                    combinations += 1
                } catch {
                    print("GENERATOR_FRAME_FAILURE TextDirection.pag frame=\(frame) size=\(size) scale=\(scale) mode=\(mode) error=\(error)")
                    throw error
                }
            }
        }
        print("GENERATOR_FRAME_COMBINATIONS \(combinations)")
        #expect(combinations == root.durationFrames * 3 && combinations > 0)
    }

    /// 只统计源树中的真实Star；递归遵守正式解码器已经验证的组深度。
    private func starCount(in elements: [SourceShape]) -> Int {
        elements.reduce(0) { count, element in
            switch element {
            case .polyStar(let value): count + (value.kind == .star ? 1 : 0)
            case .group(_, let children): count + starCount(in: children)
            default: count
            }
        }
    }
}
