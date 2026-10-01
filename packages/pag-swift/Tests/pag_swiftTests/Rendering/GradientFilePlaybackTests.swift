import Foundation
import Metal
import Testing
@testable import pag_swift

/// 真实渐变文件的正式读取、全源帧GPU输入和容量边界；不拼接完整PAG字节。
struct GradientFilePlaybackTests {
    /// 六份源文件仍含实际渐变节点，布局和色标由读取结果确认，不能用纯色替代后报成功。
    @Test(arguments: MetalShapeFixtureKind.gradients.completeFiles)
    func completeFilesRetainGradient(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let values = gradients(in: file)
        #expect(!values.isEmpty)
        let kind: SourceGradientKind = name.contains("radial") ? .radial : .linear
        for value in values {
            #expect(value.kind == kind && value.colors.initialValue.colorStops.count >= 2)
        }
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size, scale: 1, mode: .none)
        #expect(frame.plan.commands.contains { command in
            guard case .shape(let shape) = command, case .gradient = shape.material else { return false }
            return true
        })
        print("GRADIENT_FILE \(name) colors=\(values.map { $0.colors.initialValue.colorStops.count }) duration=\(file.composition.duration.microseconds)")
    }

    /// 复杂alpha样例可完整解码，但可见材料超出解析容量时必须在Metal准备失败，不降级或漏画。
    @Test func completeAlphaFileFailsAtVisibleMaterial() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "gradient/grad_alpha.pag"))
        #expect(!gradients(in: file).isEmpty)
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size, scale: 1, mode: .none)
        let owner = try GradientFileMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
        await #expect(throws: PAGError.unsupportedFeature("gradientTextureColorizer")) {
            try await owner.prepare(frame, width: Int(file.composition.size.width), height: Int(file.composition.size.height))
        }
    }

    /// 三种尺寸/倍率下遍历每个源帧，并准备真实GPU网格及渐变常量；成功必须归还局部附件。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_GRADIENT_FRAME_AUDIT"] == "1",
                   "设置PAG_GRADIENT_FRAME_AUDIT=1遍历真实渐变文件所有源帧"), .timeLimit(.minutes(5)))
    func allSourceFramesPrepareMetalInputs() async throws {
        let displays: [(PAGSize, Double, PAGScaleMode)] = try [
            (PAGSize(width: 500, height: 220), 2, .aspectFit),
            (PAGSize(width: 200, height: 150), 1, .aspectFit),
            (PAGSize(width: 750, height: 500), 3, .stretch)
        ]
        var total = 0
        for name in MetalShapeFixtureKind.gradients.completeFiles {
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let owner = try GradientFileMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
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
                        print("GRADIENT_FRAME_FAILURE \(name) frame=\(frame) size=\(size) scale=\(scale) mode=\(mode) error=\(error)")
                        throw error
                    }
                }
            }
            #expect(count == root.durationFrames * 3 && count > 0)
            total += count
            print("GRADIENT_FRAME_COMBINATIONS \(name) \(count)")
        }
        print("GRADIENT_FRAME_TOTAL \(total)")
    }

    /// 按已验证的源树收集Fill/Stroke材料，保留组内与直接位于层内的形状。
    private func gradients(in file: PAGFile) -> [SourceGradient] {
        var result: [SourceGradient] = []
        for composition in file.storage.compositions {
            for layer in composition.layers {
                guard case .shape(let elements) = layer.content else { continue }
                var pending = elements
                while let shape = pending.popLast() {
                    switch shape {
                    case .group(_, let children): pending += children
                    case .gradientFill(let fill): result.append(fill.gradient)
                    case .gradientStroke(let stroke): result.append(stroke.gradient)
                    default: break
                    }
                }
            }
        }
        return result
    }
}

/// 测试专用GPU资源owner；只准备输入，不取得离屏目标或把裸Metal对象传回调用域。
private actor GradientFileMetalOwner {
    /// 单一actor持有的几何及材料缓存；跨源帧复用与生产准备一致。
    private let resources: MetalResources

    /// 从调用域一次性接收设备，创建失败沿用生产Metal错误。
    init(device: sending any MTLDevice) throws { resources = try MetalResources(device: device) }

    /// 全量验证根pass直接显示合同；未提交的附件立即归还，失败由生产准备的defer回收。
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
