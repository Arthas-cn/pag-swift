import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import pag_swift

/// tag94的真实缩放表与损坏边界；图层映射另由语义场景测试覆盖。
struct PAGImageScaleTests {
    /// 八份真实文件在首/中/末可同时采样视频与替换图片，恢复不沿用替换裁剪或输入。
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "需要H.264硬件解码"),
          arguments: ["2", "4", "7", "10", "16", "19", "20", "22"])
    func plansFullFilesAndReplacements(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        #expect(file.editableImageIndices == [0, 1])
        #expect(file.storage.catalog.imageScaleModes == [0: .aspectFit, 1: .aspectFit])
        let input = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        var edited = file.composition
        for slot in file.editableImageIndices { try edited.replaceImage(input, at: slot) }
        let original = try await PreparedScene.prepare(file.composition)
        let replacement = try await PreparedScene.prepare(edited)
        for slot in file.editableImageIndices { try edited.replaceImage(nil, at: slot) }
        let restored = try await PreparedScene.prepare(edited)
        let root = file.storage.compositions[file.storage.rootIndex]
        var replacementCount = 0
        for index in [0, root.durationFrames / 2, root.durationFrames - 1] {
            let first = try await VideoPlanningFixtures.plan(original, frame: index)
            let changed = try await VideoPlanningFixtures.plan(replacement, frame: index)
            let last = try await VideoPlanningFixtures.plan(restored, frame: index)
            #expect(!first.videos.isEmpty && Set(first.videos.keys) == Set(changed.videos.keys))
            #expect(Set(first.images.keys) == Set(last.images.keys))
            #expect(first.plan.commands.count == last.plan.commands.count)
            for command in changed.plan.commands {
                // bitmap预合成同样生成FrameImage，但其宿主层不是可编辑图片，不能要求它被替换。
                guard case .image(let image) = command, let id = image.layerID,
                      file.composition.layer(withID: id)?.kind == .image else { continue }
                replacementCount += 1
                #expect(image.clip != nil && changed.images[image.resourceID]?.storage === input.storage)
            }
        }
        #expect(replacementCount > 0)
    }

    /// 读懂文件缩放表不能绕过其他未实现语义；15号仍明确拒绝trackMatte。
    @Test func stillRejectsUnsupportedLayerSemantics() async throws {
        await #expect(throws: PAGError.unsupportedFeature("trackMatte")) {
            try await PAGLoader().load(data: PAGFixtures.data(named: "15"))
        }
    }

    /// 仓库九份真实缩放表完整读到边界，八份含两项，15号样例含十六项LetterBox。
    @Test func readsAllRealImageScaleModes() async throws {
        var names: Set<String> = []
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            let inspection = try await PAGContainerInspector.inspect(data)
            for tag in inspection.tags where tag.code == 94 {
                names.insert(url.lastPathComponent)
                let modes = try decode(data.subdata(in: tag.payloadRange))
                #expect(modes.count == (url.lastPathComponent == "15" ? 16 : 2))
                #expect(modes.allSatisfy { $0 == .aspectFit })
            }
        }
        #expect(names == Set(["2", "4", "7", "10", "15", "16", "19", "20", "22"]))
    }

    /// 源码中的四个枚举值以独立字段片段验证；不存在和显式空表均保留各自状态。
    @Test func preservesModesAndEmptyPresence() throws {
        // ImageScaleModes.cpp的count和每项都为encodedUInt32；这里只构造字段片段，不伪造PAG文件。
        #expect(try decode(Data([4, 0, 1, 2, 3])) == [.none, .stretch, .aspectFit, .aspectFill])
        #expect(try decode(Data([0])) == [])
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        #expect(decoder.resources.imageScaleModes == nil)
        var reader = PAGByteReader(data: Data([0]))
        try decoder.readImageScaleModes(reader: &reader)
        #expect(decoder.resources.imageScaleModes == [])
        reader = PAGByteReader(data: Data([0]))
        #expect(throws: SceneValidator.invalid("duplicateImageScaleModes")) {
            try decoder.readImageScaleModes(reader: &reader)
        }
    }

    /// 截断、未知UInt32模式、夸大计数、尾部垃圾和重复标签均不能发布部分表。
    @Test func rejectsDamagedAndDuplicateTables() throws {
        let payload = try PAGFixtures.data(named: "2").subdata(in: 1689..<1692)
        for count in 0..<payload.count {
            #expect(throws: PAGError.self) { try decode(Data(payload.prefix(count))) }
        }
        var unknown = payload
        unknown[2] = 4
        #expect(throws: PAGError.unsupportedFeature("imageScaleMode:4")) { try decode(unknown) }
        // 256不能截成UInt8后误认作None；沿用既有encodedUInt32原语的合法字段编码。
        #expect(throws: PAGError.unsupportedFeature("imageScaleMode:256")) { try decode(Data([1, 0x80, 2])) }
        var oversized = payload
        oversized[0] = 127
        #expect(throws: PAGError.self) { try decode(oversized) }
        #expect(throws: PAGError.self) { try decode(payload + Data([0])) }
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        var reader = PAGByteReader(data: unknown)
        #expect(throws: PAGError.self) { try decoder.readImageScaleModes(reader: &reader) }
        #expect(decoder.resources.imageScaleModes == nil)
        reader = PAGByteReader(data: payload)
        try decoder.readImageScaleModes(reader: &reader)
        reader = PAGByteReader(data: payload)
        #expect(throws: SceneValidator.invalid("duplicateImageScaleModes")) {
            try decoder.readImageScaleModes(reader: &reader)
        }
        #expect(decoder.resources.imageScaleModes == [.aspectFit, .aspectFit])
    }

    /// 预算和取消在发布之前生效；没有tag94的真实文件继续使用默认替换模式。
    @Test func enforcesBudgetCancellationAndAbsence() async throws {
        let payload = try PAGFixtures.data(named: "2").subdata(in: 1689..<1692)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try decode(payload, budget: 1) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try decode(payload) }
        }
        await task.value
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "replacement.pag"))
        #expect(file.storage.resources.imageScaleModes == nil)
        #expect(file.storage.catalog.imageScaleModes.isEmpty)
    }

    /// 仅调用有界资源读取入口，成功必须发布完整表，不绕过所属文件的其他门禁。
    private func decode(_ data: Data, budget: Int = 1024) throws -> [PAGScaleMode] {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: budget))
        var reader = PAGByteReader(data: data)
        try decoder.readImageScaleModes(reader: &reader)
        return try #require(decoder.resources.imageScaleModes)
    }
}
