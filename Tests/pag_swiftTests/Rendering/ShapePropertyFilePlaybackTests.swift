import Foundation
import Testing
@testable import pag_swift

/// 正式入口新增四文件的全源帧几何验收；不能用首/中/末准备替代中间动画帧检查。
struct ShapePropertyFilePlaybackTests {
    /// list/16第49帧在3倍非均匀拉伸曾出现扫描反序，默认测试必须保留此中间帧。
    @Test func previouslyFailingFramePreparesGeometry() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "list/16.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let prepared = try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: 49, rate: root.frameRate),
            targetSize: PAGSize(width: 750, height: 500), scale: 3, mode: .stretch)
        guard case .shape(let command) = prepared.plan.commands[87] else {
            Issue.record("真实失败命令必须仍为shape")
            return
        }
        let source = try #require(prepared.shapes[command.geometryID])
        let precision = try GeometryPrecision(transform: command.matrix)
        var budget = try GeometryBudget()
        _ = try RenderGeometrySource.shape(source).prepare(precision: precision, budget: &budget)
    }

    /// 三种显示尺寸/倍率遍历每个源帧；失败保留文件、帧和配置，不降低精度或删除失败图元。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_SHAPE_FRAME_AUDIT"] == "1",
                   "设置PAG_SHAPE_FRAME_AUDIT=1遍历新增形状属性文件全部源帧"), .timeLimit(.minutes(5)))
    func allSourceFramesPrepareGeometry() async throws {
        let displays: [(PAGSize, Double, PAGScaleMode)] = try [
            (PAGSize(width: 500, height: 220), 2, .aspectFit),
            (PAGSize(width: 200, height: 150), 1, .aspectFit),
            (PAGSize(width: 750, height: 500), 3, .stretch)
        ]
        var combinations = 0
        for (size, scale, mode) in displays {
            for name in ["list/14.pag", "list/16.pag", "list/18.pag", "list/9.pag"] {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let root = try #require(file.storage.compositions.last)
                print("SHAPE_FRAMES \(name) count=\(root.durationFrames) size=\(size) scale=\(scale) mode=\(mode)")
                var cache = try RenderGeometryCache()
                for frame in 0..<root.durationFrames {
                    do {
                        let prepared = try await FramePlanner.prepare(scene,
                            at: SceneValidator.time(frame: frame, rate: root.frameRate),
                            targetSize: size, scale: scale, mode: mode)
                        for (index, command) in prepared.plan.commands.enumerated() {
                            guard case .shape(let shape) = command else { continue }
                            do {
                                let source = try #require(prepared.shapes[shape.geometryID])
                                var budget = try GeometryBudget()
                                _ = try cache.mesh(for: .shape(source), transform: shape.matrix, budget: &budget)
                            } catch {
                                print("SHAPE_COMMAND_FAILURE \(name) frame=\(frame) command=\(index) error=\(error)")
                                throw error
                            }
                        }
                        combinations += 1
                    } catch {
                        print("SHAPE_FRAME_FAILURE \(name) frame=\(frame) size=\(size) scale=\(scale) mode=\(mode) error=\(error)")
                        throw error
                    }
                }
            }
        }
        print("SHAPE_FRAME_COMBINATIONS \(combinations)")
        #expect(combinations > 0)
    }
}
