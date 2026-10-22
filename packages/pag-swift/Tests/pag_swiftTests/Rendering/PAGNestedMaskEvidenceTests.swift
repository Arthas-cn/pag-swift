import Foundation
import Metal
import Testing
@testable import pag_swift

/// 两份真实资源仍停在Metal嵌套路径门禁时的正式计划拓扑调查。
struct PAGNestedMaskEvidenceTests {
    /// 记录首中末帧蒙版入栈/出栈与来源，确认失败是多路径、羽化还是祖先作用域。
    @Test(arguments: ["travel.pag", "shanzi_video.pag"])
    func realMaskTopologies(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let indices = Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted()
        var observed = 0
        for frameIndex in indices {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: frameIndex, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            var depth = 0
            var maximum = 0
            var lines: [String] = []
            for (index, command) in frame.plan.commands.enumerated() {
                switch command {
                case .beginMask(let mask):
                    depth += 1
                    maximum = max(maximum, depth)
                    let kind: String
                    switch mask.source {
                    case .path(let path): kind = "path verbs=\(path.verbs.count) points=\(path.points.count)"
                    case .expression(let expression):
                        kind = "expression terms=\(expression.terms.count) points=\(expression.terms.reduce(0) { $0 + $1.path.points.count })"
                    case .feather: kind = "feather"
                    }
                    lines.append("\(index) begin depth=\(depth) layer=\(mask.layerID.path) kind=\(kind) inverse=\(mask.isInverted)")
                case .endMask:
                    lines.append("\(index) end depth=\(depth)")
                    depth -= 1
                default: break
                }
            }
            #expect(depth == 0)
            observed = max(observed, maximum)
            if ProcessInfo.processInfo.environment["PAG_NESTED_MASK_AUDIT"] == "1" {
                print("PAG_NESTED_MASK file=\(name) frame=\(frameIndex) maximum=\(maximum) count=\(lines.count)")
                for line in lines { print("PAG_NESTED_MASK \(line)") }
                if (name == "travel.pag" && frameIndex == root.durationFrames / 2) ||
                   (name == "shanzi_video.pag" && frameIndex == 0) {
                    for (index, command) in frame.plan.commands.enumerated() {
                        print("PAG_NESTED_MASK_PLAN \(index) \(Self.commandName(command))")
                    }
                }
                if let device = MTLCreateSystemDefaultDevice() {
                    let resources = try MetalResources(device: device)
                    do {
                        let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                            resources: resources, disablePictureCache: true)
                        print("PAG_NESTED_MASK metal=passed draws=\(batch.drawCount)")
                        batch.releaseTransients()
                    } catch { print("PAG_NESTED_MASK metal=\(error)") }
                }
            }
        }
        #expect(observed > 0)
    }

    /// 只记录效果边界和图元种类，不把庞大的路径点数组写入调查日志。
    private static func commandName(_ command: FrameCommand) -> String {
        switch command {
        case .beginGroup(let group): "beginGroup opacity=\(group.opacity) application=\(group.application)"
        case .endGroup: "endGroup"
        case .beginMask: "beginMask"
        case .endMask: "endMask"
        case .beginTrackMatte: "beginTrackMatte"
        case .endTrackMatteSource: "endTrackMatteSource"
        case .endTrackMatte: "endTrackMatte"
        case .beginDropShadow: "beginDropShadow"
        case .endDropShadow: "endDropShadow"
        case .beginOpacityGroup: "beginOpacityGroup"
        case .endOpacityGroup: "endOpacityGroup"
        case .beginPicture: "beginPicture"
        case .endPicture: "endPicture"
        case .beginVectorPicture: "beginVectorPicture"
        case .endVectorPicture: "endVectorPicture"
        case .solid: "solid"
        case .image: "image"
        case .video: "video"
        case .shape: "shape"
        case .text: "text"
        case .textBulge: "textBulge"
        }
    }
}
