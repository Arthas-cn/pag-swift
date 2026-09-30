import Foundation
import Metal
import Testing
@testable import pag_swift

/// 显式运行全资源分类；默认不重复耗时的视频与Metal准备，也不把计划成功当成可见验收。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_RESOURCE_AUDIT"] == "1",
                "设置PAG_RESOURCE_AUDIT=1重新分类真实资源"), .timeLimit(.minutes(5)))
struct PAGResourcePlaybackAuditTests {
    /// 逐份报告公开载入及首/中/末共同Metal准备；未知能力可明确失败，其他错误必须记录为问题。
    @Test func classifiesEveryCompleteFile() async throws {
        let root = try PAGFixtures.rootURL()
        let owner = ResourceAuditMetalOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        var supported = 0, unsupported = 0
        for url in try PAGFixtures.allPAGURLs() {
            let name = String(url.path.dropFirst(root.path.count + 1))
            let data = try Data(contentsOf: url)
            let inspection = try await PAGContainerInspector.inspect(data)
            let ids = try inspection.tags.filter { [2, 45, 50].contains($0.code) }.map { tag in
                var reader = PAGByteReader(data: data.subdata(in: tag.payloadRange))
                return try reader.readEncodedUInt32()
            }
            var phase = "decode"
            do {
                let file = try await PAGLoader().load(data: data)
                phase = "prepare"
                let scene = try await PreparedScene.prepare(file.composition)
                for microseconds in [Int64(0), file.composition.duration.microseconds / 2, file.composition.duration.microseconds - 1] {
                    phase = "plan"
                    let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: microseconds),
                        targetSize: scene.composition.size, scale: 1, mode: .none)
                    phase = "metal"
                    try await owner.prepare(frame, size: scene.composition.size)
                }
                supported += 1
                report(name: name, status: "passed", phase: "metal", reason: "", ids: ids)
            } catch let error as PAGError {
                report(name: name, status: "failed", phase: phase, reason: String(describing: error), ids: ids)
                if case .unsupportedFeature = error { unsupported += 1 }
                else { Issue.record("\(name)在\(phase)意外失败：\(error)") }
            }
        }
        print("PAG_AUDIT_COUNTS passed=\(supported) unsupported=\(unsupported)")
        #expect(supported > 0 && unsupported > 0)
    }

    /// JSON单行便于稳定重建支持矩阵；字段明确区分解码与绘制准备的失败阶段。
    private func report(name: String, status: String, phase: String, reason: String, ids: [UInt32]) {
        let value: [String: Any] = ["name": name, "status": status, "phase": phase, "reason": reason, "compositionIDs": ids]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print("PAG_AUDIT \(line)") }
    }
}

/// 分类只访问真实GPU输入，裸Metal资源不会返回测试调用域；这不是离屏出图器。
private actor ResourceAuditMetalOwner {
    /// 独占设备，不跨域共享裸对象。
    private let device: any MTLDevice

    /// 一次性转交系统设备。
    init(device: sending any MTLDevice) { self.device = device }

    /// 每帧用冷缓存检验默认资源门禁，成功后立即归还未提交的局部附件。
    func prepare(_ frame: PreparedFrame, size: PAGSize) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: Int(size.width), height: Int(size.height), resources: resources)
        batch.releaseTransients()
        #expect(batch.passes.last?.attachment == nil && resources.groups.activeBytes == 0)
    }
}
