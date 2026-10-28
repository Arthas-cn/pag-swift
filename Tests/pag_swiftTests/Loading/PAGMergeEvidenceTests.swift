import Foundation
import Metal
import Testing
@testable import pag_swift

/// 真实MergePaths标签的来源、模式和字段长度调查；不把原始字节片段当作合法完整文件。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_MERGE_AUDIT"] == "1",
                "设置PAG_MERGE_AUDIT=1调查真实MergePaths字段"))
struct PAGMergeEvidenceTests {
    /// 沿已验证的容器/形状组边界调查所有资源，逐文件记录一个固定模式字节。
    @Test func realPayloadModesAndLengths() throws {
        let root = try PAGFixtures.rootURL().path + "/"
        var total = 0
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(data)
            guard !inspection.mergePayloads.isEmpty else { continue }
            let name = url.path.replacingOccurrences(of: root, with: "")
            for payload in inspection.mergePayloads {
                #expect(payload.range.count == 1)
                #expect(payload.mode <= 4)
                print("PAG_MERGE \(name) offset=\(payload.range.lowerBound) mode=\(payload.mode)")
                total += 1
            }
            for codes in inspection.mergeGroups {
                print("PAG_MERGE_GROUP \(name) codes=\(codes.map(String.init).joined(separator: ","))")
            }
        }
        #expect(total > 0)
        print("PAG_MERGE total=\(total)")
    }

    /// 只读探查含mode0/3的真实文件能否完整载入并形成首/中/末帧计划，记录下一道真实门禁。
    @Test func selectedFileOutcomes() async throws {
        let names = ["list/3.pag", "list/4.pag", "list/5.pag", "list/7.pag", "list/8.pag",
                     "moonlight.pag", "transitions.pag"]
        for name in names {
            let data = try PAGFixtures.data(named: name)
            do {
                let file = try await PAGLoader().load(data: data)
                do {
                    let scene = try await PreparedScene.prepare(file.composition)
                    let root = try #require(file.storage.compositions.last)
                    let frames = [Int64(0), root.durationFrames / 2, root.durationFrames - 1]
                    for frame in frames {
                        _ = try await FramePlanner.prepare(scene,
                            at: SceneValidator.time(frame: frame, rate: root.frameRate),
                            targetSize: file.composition.size, scale: 1, mode: .none)
                    }
                    print("PAG_MERGE_FILE \(name) frames=\(root.durationFrames) samples=ready")
                } catch {
                    print("PAG_MERGE_FILE \(name) decoded=true samples=\(error)")
                }
            } catch {
                print("PAG_MERGE_FILE \(name) decoded=\(error)")
            }
        }
    }

    /// 当前可完整载入的六份真实文件逐源帧规划，定位仅在动画中段触发的曲线或预算门禁。
    @Test(.timeLimit(.minutes(2))) func completeFileFrames() async throws {
        let names = ["list/3.pag", "list/4.pag", "list/5.pag", "list/8.pag",
                     "moonlight.pag", "transitions.pag"]
        var total = 0
        for name in names {
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            for frame in 0..<root.durationFrames {
                do {
                    _ = try await FramePlanner.prepare(scene,
                        at: SceneValidator.time(frame: frame, rate: root.frameRate),
                        targetSize: file.composition.size, scale: 1, mode: .none)
                    total += 1
                } catch {
                    print("PAG_MERGE_FRAME_FAILURE \(name) frame=\(frame) error=\(error)")
                    throw error
                }
            }
            print("PAG_MERGE_FRAME \(name) count=\(root.durationFrames)")
        }
        #expect(total == 718)
    }

    /// 六份真实文件的718个源帧逐一经过生产Metal输入准备，根pass仍须直接指向drawable且附件归还。
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
          .timeLimit(.minutes(3)))
    func completeFileFramesPrepareMetal() async throws {
        let names = ["list/3.pag", "list/4.pag", "list/5.pag", "list/8.pag",
                     "moonlight.pag", "transitions.pag"]
        let size = try PAGSize(width: 200, height: 200)
        let owner = try MergeFileMetalOwner(device: #require(MTLCreateSystemDefaultDevice()))
        var total = 0
        for name in names {
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            for frame in 0..<root.durationFrames {
                do {
                    let prepared = try await FramePlanner.prepare(scene,
                        at: SceneValidator.time(frame: frame, rate: root.frameRate),
                        targetSize: size, scale: 1, mode: .aspectFit)
                    do { try await owner.prepare(prepared) }
                    catch {
                        let pictures = prepared.plan.commands.filter {
                            if case .beginPicture = $0 { true } else { false }
                        }.count
                        let sampled = prepared.plan.commands.compactMap { command -> Int64? in
                            if case .shape(let paint) = command { paint.geometryID.sampleFrame } else { nil }
                        }
                        print("PAG_MERGE_PICTURE_DIAGNOSTIC \(name) frame=\(frame) markers=\(pictures) sampled=\(sampled)")
                        throw error
                    }
                    total += 1
                } catch {
                    print("PAG_MERGE_METAL_FAILURE \(name) frame=\(frame) error=\(error)")
                    throw error
                }
            }
            print("PAG_MERGE_METAL \(name) count=\(root.durationFrames)")
        }
        #expect(total == 718)
    }
}

/// 真实文件源帧测试的单一Metal资源域；不创建额外播放器或离屏显示目标。
private actor MergeFileMetalOwner {
    /// 跨文件与源帧复用正式几何和材料缓存。
    private let resources: MetalResources

    /// 接收一次性测试设备，初始化失败按生产错误传播。
    init(device: sending any MTLDevice) throws { resources = try MetalResources(device: device) }

    /// 仅准备当前帧GPU输入，并在成功/失败后检查局部附件归还。
    func prepare(_ frame: PreparedFrame) throws {
        do {
            let batch = try MetalFramePreparation.prepare(frame, width: 200, height: 200,
                                                          resources: resources)
            batch.releaseTransients()
            #expect(batch.passes.last?.attachment == nil && resources.groups.activeBytes == 0)
        } catch {
            #expect(resources.groups.activeBytes == 0)
            throw error
        }
    }
}
