import Foundation
import Testing
@testable import pag_swift

/// 真实完整场景解码与破坏性变体；不能用仅通过容器检查的结果冒充成功。
struct PAGSceneDecoderTests {
    /// 真实资源只有完整闭包才能成功，其余必须明确 unsupported，不能输出损坏或部分场景。
    @Test func realFixtureSupportIsExplicit() async throws {
        var decodedNames: [String] = []
        var unsupportedCount = 0
        for url in try PAGFixtures.allPAGURLs() {
            do {
                let file = try await PAGSceneDecoder.decode(Data(contentsOf: url))
                #expect(file.composition.duration.microseconds > 0)
                decodedNames.append(url.lastPathComponent)
            } catch let error as PAGError {
                guard case .unsupportedFeature = error else {
                    Issue.record("真实资源 \(url.lastPathComponent) 意外失败：\(error)")
                    continue
                }
                unsupportedCount += 1
            }
        }
        #expect(decodedNames.contains("red.pag"))
        #expect(unsupportedCount > 0)
    }

    /// red 的完整只读树、时间、尺寸与默认形状填充应符合独立上游证据。
    @Test func decodesCompleteRedScene() async throws {
        let file = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "red.pag"))
        let composition = file.composition
        #expect(composition.size == (try PAGSize(width: 720, height: 1280)))
        #expect(composition.duration == PAGTime(microseconds: 15_000_000))
        #expect(composition.frameRate == 30)
        #expect(composition.layers.count == 1)
        let layer = try #require(composition.layers.first)
        #expect(layer.name == "Shape Layer 1")
        #expect(layer.kind == .shape)
        #expect(layer.isVisible)
        #expect(layer.startTime == .zero)
        #expect(layer.duration == composition.duration)
        #expect(layer.editableIndex == nil)
        #expect(layer.children.isEmpty)
        #expect(composition.layer(withID: layer.id)?.id == layer.id)
        #expect(composition.layers(named: layer.name).map(\.id) == [layer.id])
        #expect(composition.layers(named: "absent").isEmpty)
        #expect(file.editableTextCount == 0 && file.editableImageCount == 0)
        #expect(file.editableTextIndices.isEmpty && file.editableImageIndices.isEmpty)
        let source = try #require(file.storage.compositions.last?.layers.first)
        #expect(try source.transform.value(at: 0).position == ScenePoint(x: 360, y: 640))
        guard case let .shape(shapes) = source.content,
              case let .group(transform, elements) = try #require(shapes.first) else {
            Issue.record("red 必须保留 shape group，而非简化成 solid")
            return
        }
        #expect(shapes.count == 1 && elements.count == 2)
        let value = try transform.value(at: 0)
        #expect(value.base.scale.x == 0.4798107445240021)
        #expect(value.base.scale.y == 4.25517463684082)
        guard case let .rectangle(rectangle) = elements[0],
              case let .fill(fill) = elements[1] else {
            Issue.record("组内必须依次保留矩形和填充")
            return
        }
        #expect(transform.isAnimated == false && rectangle.isAnimated == false && fill.isAnimated == false)
        #expect(rectangle.reversed == false && rectangle.roundness.initialValue == 0)
        #expect(rectangle.size.initialValue == ScenePoint(x: 1500, y: 300))
        #expect(rectangle.position.initialValue == .zero)
        #expect(fill.color.initialValue == SceneColor(red: 255, green: 0, blue: 0))
        #expect(fill.opacity.initialValue == 255)
    }

    /// 同内容的独立解码身份稳定，任意内容改写生成新身份且旧 ID 不能查入新文档。
    @Test func identitiesFollowFullContent() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        let first = try await PAGSceneDecoder.decode(data)
        let second = try await PAGSceneDecoder.decode(data)
        let id = try #require(first.composition.layers.first?.id)
        #expect(second.composition.layer(withID: id)?.id == id)
        let hex = first.storage.identity.digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "ec36c9b9ebcf2d7099f1592dce120eab31646f707c66bd67ada8902b6fe8b976")
        // 修改真实字符串一个字节，不改布局；内容身份必须随之失效。
        data[106] = 84
        let changed = try await PAGSceneDecoder.decode(data)
        #expect(changed.composition.layer(withID: id) == nil)
        #expect(changed.composition.layers.first?.name == "Thape Layer 1")
    }

    /// Data 子序列可能保留非零起点；相同 PAG 内容必须得到同一文档身份。
    @Test func dataSliceKeepsContentIdentity() async throws {
        let original = try PAGFixtures.data(named: "red.pag")
        var prefixed = Data([0xff])
        prefixed.append(original)
        let sliced = prefixed.dropFirst()
        #expect(sliced.startIndex == 1)
        let file = try await PAGSceneDecoder.decode(sliced)
        let plain = try await PAGSceneDecoder.decode(original)
        #expect(file.composition.layers.first?.id == plain.composition.layers.first?.id)
    }

    /// BitFlag 为零必须保留不可见状态，不能误用配置中的默认 true。
    @Test func inactiveLayerIsPreserved() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data[102] = 0
        let file = try await PAGSceneDecoder.decode(data)
        #expect(file.composition.layers.count == 1)
        #expect(file.composition.layers.first?.isVisible == false)
    }

    /// 顶层或嵌套未知标签都必须拒绝，不得返回只有已知部分的 PAGFile。
    @Test(arguments: [9, 143])
    func unknownSemanticTagFails(_ offset: Int) async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        let old = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        let changed = UInt16(999 << 6) | (old & 63)
        data[offset] = UInt8(truncatingIfNeeded: changed)
        data[offset + 1] = UInt8(changed >> 8)
        let reason = offset == 9 ? "fileTag:999" : "shapeTag:999"
        await #expect(throws: PAGError.unsupportedFeature(reason)) { try await PAGSceneDecoder.decode(data) }
    }

    /// 只把静态位置改成动画标志却不补关键帧载荷，应按损坏输入失败，不能返回首帧假动画。
    @Test func invalidAnimatedAttributeFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data[122] = 6
        await #expect(throws: SceneValidator.invalid("emptyKeyframes")) { try await PAGSceneDecoder.decode(data) }
    }

    /// NaN 属性应在进场景前失败，避免后续矩阵或 GPU 使用非有限值。
    @Test func nonfiniteTransformFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data.replaceSubrange(123..<127, with: [0, 0, 0xc0, 0x7f])
        await #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: 123)) {
            try await PAGSceneDecoder.decode(data)
        }
    }

    /// 本库拒绝零图层时长，不执行上游修复为一帧的宽容行为。
    @Test func zeroLayerDurationFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data.replaceSubrange(104..<106, with: [0x80, 0])
        await #expect(throws: PAGError.invalidFile(reason: "nonpositiveLayerDuration", offset: nil)) {
            try await PAGSceneDecoder.decode(data)
        }
    }

    /// 删除真实变换块并修正外层长度后仍必须拒绝缺失的必需变换。
    @Test func missingTransformFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        // 三个长度字段的位置均来自 red 独立字节证据；这是损坏输入，不是新造 PAG。
        data[4] = 145
        data[68] = 80
        data[92] = 54
        data.removeSubrange(120..<131)
        await #expect(throws: PAGError.invalidFile(reason: "missingLayerAttributesOrTransform", offset: nil)) {
            try await PAGSceneDecoder.decode(data)
        }
    }

    /// 后续块伪装成第二份 Transform2D 时，在读取冲突载荷前失败。
    @Test func duplicateTransformFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        let word = UInt16(13 << 6 | 26)
        data[131] = UInt8(truncatingIfNeeded: word)
        data[132] = UInt8(word >> 8)
        await #expect(throws: PAGError.invalidFile(reason: "duplicateTransform", offset: nil)) {
            try await PAGSceneDecoder.decode(data)
        }
    }

    /// 已通过容器预算的小文件仍可能超过源场景/索引预算，应在实例分配前失败。
    @Test func sceneAllocationIsBudgeted() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let limits = try PAGLoadLimits(maximumDecodedBytes: 2000)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try await PAGSceneDecoder.decode(data, limits: limits)
        }
    }

    /// 预先取消的完整解码任务不能发布任何文档，且保持标准取消错误。
    @Test func cancelledDecodeDoesNotPublish() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: PAGFile.self) { group in
                group.cancelAll()
                group.addTask { try await PAGSceneDecoder.decode(data) }
                for try await _ in group {}
            }
        }
    }
}
