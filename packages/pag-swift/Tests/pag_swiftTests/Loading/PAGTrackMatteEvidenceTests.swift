import Foundation
import Testing
@testable import pag_swift

/// 沿已验证的真实容器/图层边界调查Track Matte模式与相邻源层，不把字段调查当成播放成功。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_TRACK_MATTE_AUDIT"] == "1",
                "设置PAG_TRACK_MATTE_AUDIT=1调查真实Track Matte字段"))
struct PAGTrackMatteEvidenceTests {
    /// 全部资源的非零模式必须落在上游四值枚举中，并记录所在合成的编码层序号。
    @Test func realModesAndLayerPositions() throws {
        let root = try PAGFixtures.rootURL().path + "/"
        var counts = [UInt8: Int]()
        var sourceKinds = [UInt8: Int]()
        var firstLayerCount = 0
        for url in try PAGFixtures.allPAGURLs() {
            let name = url.path.replacingOccurrences(of: root, with: "")
            var inspection = ShapeAnimationInspection()
            do { try inspection.inspect(Data(contentsOf: url)) }
            catch {
                // 失败时带上文件名，避免仅靠子流绝对偏移误把有效文件判为损坏。
                print("PAG_TRACK_MATTE_SCAN_FAILURE \(name) error=\(error)")
                throw error
            }
            for value in inspection.trackMattePayloads where value.mode != 0 {
                #expect((1...4).contains(value.mode))
                if value.layerIndex == 0 { firstLayerCount += 1 }
                if let kind = value.sourceKind { sourceKinds[kind, default: 0] += 1 }
                counts[value.mode, default: 0] += 1
                print("PAG_TRACK_MATTE \(name) comp=\(value.compositionID) layer=\(value.layerID) kind=\(value.layerKind) index=\(value.layerIndex) source=\(String(describing: value.sourceLayerID)) sourceKind=\(String(describing: value.sourceKind)) tag=\(value.code) offset=\(value.offset) mode=\(value.mode)")
            }
        }
        #expect(counts == [1: 36, 2: 4, 3: 1])
        #expect(firstLayerCount == 1)
        #expect(sourceKinds.values.reduce(0, +) == 40)
        print("PAG_TRACK_MATTE_COUNTS \(counts) firstLayer=\(firstLayerCount) sourceKinds=\(sourceKinds)")
    }

    /// 真正的属性子流应识别Alpha、AlphaInverted和Luma；真实字段改成4仍合法，改成5必须拒绝。
    @Test func parserKeepsRealModeAndRejectsUnknownValue() throws {
        let names = ["repeater.pag", "data-TimeStretch.pag", "PAG_LOGO.pag"]
        let modes: [UInt8] = [1, 2, 3]
        for (name, mode) in zip(names, modes) {
            let data = try PAGFixtures.data(named: name)
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(data)
            let field = try #require(inspection.trackMattePayloads.first(where: { $0.mode == mode }))
            let value = try parsedAttribute(data: data, field: field)
            #expect(value.trackMatte.rawValue == mode)
        }
        let data = try PAGFixtures.data(named: "repeater.pag")
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(data)
        let field = try #require(inspection.trackMattePayloads.first(where: { $0.mode == 1 }))
        let modeOffset = try #require(field.modeOffset)
        var bytes = Array(data)
        bytes[modeOffset] = 4
        #expect(try parsedAttribute(data: Data(bytes), field: field).trackMatte == .lumaInverted)
        bytes[modeOffset] = 5
        #expect(throws: PAGError.invalidFile(reason: "unknownTrackMatteType", offset: modeOffset)) {
            try parsedAttribute(data: Data(bytes), field: field)
        }
    }

    /// 真实list/7的邻层引用须在完整载入后形成源/拥有者分段，不能只跨过字段门禁。
    @Test func realReferencedFilePlansSourceAndOwner() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "list/7.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        var referencedFrames = 0
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: file.composition.size, scale: 1, mode: .none)
            if frame.plan.commands.contains(where: { if case .beginTrackMatte = $0 { true } else { false } }) {
                referencedFrames += 1
            }
        }
        #expect(referencedFrames > 0)
    }

    /// 首层无引用字段不安装遮罩，真实Repeater文件应能载入并规划首中末帧。
    @Test func firstLayerWithoutReferencePlansRepeaterFile() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "repeater.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        for frame in [Int64(0), root.durationFrames / 2, root.durationFrames - 1] {
            let prepared = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: frame, rate: root.frameRate),
                targetSize: file.composition.size, scale: 1, mode: .none)
            let paints = prepared.plan.commands.filter { if case .shape = $0 { true } else { false } }.count
            print("PAG_REPEATER_FRAME size=\(file.composition.size) duration=\(root.durationFrames) frame=\(frame) paints=\(paints)")
            #expect(paints > 0)
        }
    }

    /// 在真实属性载荷的遮罩值字节前截断，应报准确偏移而不能把缺失值当None。
    @Test func truncatedRealModeByteFails() throws {
        let data = try PAGFixtures.data(named: "repeater.pag")
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(data)
        let field = try #require(inspection.trackMattePayloads.first(where: { $0.mode == 1 }))
        let modeOffset = try #require(field.modeOffset)
        let prefix = Data(data[field.offset..<modeOffset])
        var reader = PAGByteReader(data: prefix)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
        #expect(throws: PAGError.truncatedData(offset: prefix.count)) {
            try decoder.readLayerAttributes(code: field.code, reader: &reader)
        }
    }

    /// 从真实完整文件的已验证tag范围切出属性，不拼接自称合法的PAG文件。
    private func parsedAttribute(data: Data,
                                 field: (compositionID: UInt32, layerID: UInt32, layerIndex: Int, layerKind: UInt8,
                                         sourceLayerID: UInt32?, sourceKind: UInt8?,
                                         code: UInt16, offset: Int, length: Int, modeOffset: Int?, mode: UInt8)) throws -> LayerAttributes {
        var reader = PAGByteReader(data: data)
        try reader.skip(byteCount: field.offset)
        var payload = try reader.readSubreader(byteCount: field.length)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
        let result = try decoder.readLayerAttributes(code: field.code, reader: &payload)
        try StaticAttributes.requireEnd(of: payload)
        return result
    }
}
