import Foundation
import Testing
@testable import pag_swift

/// 中间帧失败回归与显式全帧门禁；首中末分类不能代替动画中间帧的几何验收。
struct StrokeFilePlaybackTests {
    /// 两个曾在实际播放/逐帧探针失败的中间帧进入默认测试，必须完整生成几何而非被忽略。
    @Test func previouslyFailingFramesPrepareGeometry() async throws {
        for (name, frame) in [("list/19.pag", Int64(1)), ("list/15.pag", Int64(14))] {
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            var cache = try RenderGeometryCache()
            try await prepare(scene, frame: frame, rate: root.frameRate, size: PAGSize(width: 500, height: 220),
                              scale: 2, mode: .aspectFit, cache: &cache)
        }
    }

    /// 六文件全部源帧在三种显示尺寸/倍率准备；显式启用昂贵门禁，失败记录可复现的输入。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_STROKE_FRAME_AUDIT"] == "1",
                   "设置PAG_STROKE_FRAME_AUDIT=1遍历描边文件全部源帧"), .timeLimit(.minutes(5)))
    func allSourceFramesPrepareGeometry() async throws {
        let displays: [(PAGSize, Double, PAGScaleMode)] = try [
            (PAGSize(width: 500, height: 220), 2, .aspectFit),
            (PAGSize(width: 200, height: 150), 1, .aspectFit),
            (PAGSize(width: 750, height: 500), 3, .stretch)
        ]
        for (size, scale, mode) in displays {
            for name in ["list/19.pag", "0.pag", "list/0.pag", "list/12.pag", "list/13.pag", "list/15.pag"] {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let root = try #require(file.storage.compositions.last)
                print("STROKE_FRAMES \(name) count=\(root.durationFrames) size=\(size) scale=\(scale) mode=\(mode)")
                var cache = try RenderGeometryCache()
                for frame in 0..<root.durationFrames {
                    do {
                        try await prepare(scene, frame: frame, rate: root.frameRate, size: size,
                                          scale: scale, mode: mode, cache: &cache)
                    } catch {
                        print("STROKE_FRAME_FAILURE \(name) frame=\(frame) error=\(error)")
                        throw error
                    }
                }
            }
        }
    }

    /// 走真实FramePlanner和几何缓存生成所有shape；错误向上传播，不写诊断文件或删除坏图元。
    private func prepare(_ scene: PreparedScene, frame: Int64, rate: Double, size: PAGSize, scale: Double,
                         mode: PAGScaleMode, cache: inout RenderGeometryCache) async throws {
        let prepared = try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: frame, rate: rate),
                                                     targetSize: size, scale: scale, mode: mode)
        for command in prepared.plan.commands {
            guard case .shape(let shape) = command else { continue }
            let source = try #require(prepared.shapes[shape.geometryID])
            var budget = try GeometryBudget()
            _ = try cache.mesh(for: .shape(source), transform: shape.matrix, budget: &budget)
        }
    }
}
