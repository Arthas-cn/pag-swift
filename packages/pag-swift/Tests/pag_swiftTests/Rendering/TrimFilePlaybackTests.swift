import Foundation
import Metal
import Testing
@testable import pag_swift

/// 真实完整Trim文件的正式源树及全源帧GPU输入门禁；不拼接或删改PAG内容。
struct TrimFilePlaybackTests {
    /// 四份文件保留实际mode0动画，根层与组内均有覆盖；动态准备不得退化为静态首帧。
    @Test(arguments: MetalShapeFixtureKind.trimPaths.completeFiles)
    func completeFilesRetainAnimatedTrim(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let values = trims(in: file)
        #expect(!values.isEmpty && values.contains(where: \.isAnimated))
        #expect(values.allSatisfy { $0.mode == .simultaneously })
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.dynamicShapes != nil)
        let root = try #require(file.storage.compositions.last)
        print("TRIM_FILE \(name) count=\(values.count) frames=\(root.durationFrames) duration=\(file.composition.duration.microseconds)")
    }

    /// 越过Trim后仍须拒绝后续蒙版或matte，不能以节点能读代替整文件可播放。
    @Test(arguments: [("list/2.pag", "layerTag:14"), ("like.pag", "trackMatte")])
    func laterUnsupportedContentStillFails(_ name: String, _ reason: String) async throws {
        await #expect(throws: PAGError.unsupportedFeature(reason)) {
            try await PAGLoader().load(data: PAGFixtures.data(named: name))
        }
    }

    /// 三种布局及倍率遍历所有源帧，真实Metal准备必须成功并归还未提交的局部组附件。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_TRIM_FRAME_AUDIT"] == "1",
                   "设置PAG_TRIM_FRAME_AUDIT=1遍历真实Trim文件所有源帧"), .timeLimit(.minutes(5)))
    func allSourceFramesPrepareMetalInputs() async throws {
        let displays: [(PAGSize, Double, PAGScaleMode)] = try [
            (PAGSize(width: 500, height: 220), 2, .aspectFit),
            (PAGSize(width: 200, height: 150), 1, .aspectFit),
            (PAGSize(width: 750, height: 500), 3, .stretch)
        ]
        var total = 0
        for name in MetalShapeFixtureKind.trimPaths.completeFiles {
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let owner = try TrimFileMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
            var count = 0
            for (size, scale, mode) in displays {
                for frame in 0..<root.durationFrames {
                    do {
                        let prepared = try await FramePlanner.prepare(scene,
                            at: SceneValidator.time(frame: frame, rate: root.frameRate),
                            targetSize: size, scale: scale, mode: mode)
                        try await owner.prepare(prepared, width: Int(size.width * scale), height: Int(size.height * scale))
                        count += 1
                    } catch {
                        print("TRIM_FRAME_FAILURE \(name) frame=\(frame) size=\(size) scale=\(scale) mode=\(mode) error=\(error)")
                        throw error
                    }
                }
            }
            #expect(count == root.durationFrames * 3 && count > 0)
            total += count
            print("TRIM_FRAME_COMBINATIONS \(name) \(count)")
        }
        print("TRIM_FRAME_TOTAL \(total)")
    }

    /// 收集源层与嵌套组中的实际Trim，公开文件仍需通过全部其他节点的读取门禁。
    private func trims(in file: PAGFile) -> [SourceTrimPaths] {
        var result: [SourceTrimPaths] = []
        for composition in file.storage.compositions {
            for layer in composition.layers {
                guard case .shape(let elements) = layer.content else { continue }
                var pending = elements
                while let shape = pending.popLast() {
                    switch shape {
                    case .group(_, let children): pending += children
                    case .trimPaths(let trim): result.append(trim)
                    default: break
                    }
                }
            }
        }
        return result
    }
}

/// 测试专用输入owner，独占Metal资源；不创建离屏显示目标，不输出像素或裸GPU对象。
private actor TrimFileMetalOwner {
    /// 跨源帧保活的生产几何与材料缓存。
    private let resources: MetalResources

    /// 一次性接收设备，创建失败沿用生产错误。
    init(device: sending any MTLDevice) throws { resources = try MetalResources(device: device) }

    /// 成功和失败均检查局部附件已回收，根pass必须保留直接drawable合同。
    func prepare(_ frame: PreparedFrame, width: Int, height: Int) throws {
        do {
            let batch = try MetalFramePreparation.prepare(frame, width: width, height: height, resources: resources)
            batch.releaseTransients()
            #expect(batch.passes.last?.attachment == nil && resources.groups.activeBytes == 0)
        } catch {
            #expect(resources.groups.activeBytes == 0)
            throw error
        }
    }
}
