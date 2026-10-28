import Foundation
import Testing
@testable import pag_swift

/// 真实动画 PAG 的完整载入与独立数值预期，不以“能读取轨道”代替求值验证。
struct PAGAnimatedTransformTests {
    /// replacement 的两个缩放/旋转 Bezier 段保留原始端点，逐时刻值符合独立曲线计算。
    @Test func replacementAnimationDecodesAndEvaluates() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "replacement.pag"))
        #expect(file.editableImageCount == 1)
        let source = try #require(file.storage.compositions.last?.layers.first)
        let transform = source.transform
        #expect(transform.scale.keyframes.map(\.startFrame) == [0, 30])
        #expect(transform.scale.keyframes.map(\.endFrame) == [30, 59])
        #expect(transform.rotation.keyframes.count == 2 && !transform.opacity.isAnimated)
        let start = try transform.value(at: 0)
        #expect(start.anchor == ScenePoint(x: 256, y: 256) && start.position == ScenePoint(x: 400, y: 400))
        #expect(start.scale == ScenePoint(x: 0.25, y: 0.25) && start.rotation == 0 && start.opacity == 255)
        let peak = try transform.value(at: 30)
        #expect(peak.scale == .one && peak.rotation == 360)
        let end = try transform.value(at: 59)
        #expect(end.scale == ScenePoint(x: 0.25, y: 0.25) && end.rotation == 720)
        #expect(try transform.value(at: 100) == end)
        // 预期由三次 Bezier 公式独立求逆获得；上游折线精度 0.005 允许有限近似误差。
        let first = try transform.value(at: 15)
        #expect(abs(first.scale.x - 0.8882334561) < 0.003)
        #expect(first.scale.x == first.scale.y)
        #expect(abs(first.rotation - 294.5987072) < 1)
        let second = try transform.value(at: 45)
        #expect(abs(second.scale.x - 0.8879098457) < 0.003)
        #expect(abs(second.rotation - 420.1993673) < 1)
    }

    /// srgb 完整文件中的空间切线、时间曲线和位打包 opacity 可共同求值。
    @Test func realSpatialTrackUsesCurvedArcLength() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "srgb.pag"))
        #expect(file.editableImageCount == 11 && file.composition.layers.count == 19)
        let source = try #require(file.storage.compositions.last?.layers.first { $0.id == 610 })
        guard case .combined(let position) = source.transform.position else {
            Issue.record("源空间位置必须保持 combined 轨道")
            return
        }
        #expect(position.keyframes.count == 5 && position.keyframes.allSatisfy { $0.spatialCurve != nil })
        #expect(try source.transform.value(at: 22).position == ScenePoint(x: 318, y: 1001))
        #expect(try source.transform.value(at: 37).position == ScenePoint(x: 328, y: 1001))
        #expect(try source.transform.value(at: 50).position == ScenePoint(x: 318, y: 1001))
        // 独立三次曲线公式用 20,000 段累计长度反查；容差覆盖上游 0.05 空间细分精度。
        let value = try source.transform.value(at: 43).position
        #expect(abs(value.x - 323.5420100) < 0.06 && abs(value.y - 1001.5686964) < 0.06)
        let later = try source.transform.value(at: 110).position
        #expect(abs(later.x - 317.3689783) < 0.06 && abs(later.y - 996.0630227) < 0.06)
        #expect(try source.transform.value(at: 22).opacity == 0)
        #expect(try source.transform.value(at: 72).opacity == 255)
        #expect(abs(Int(try source.transform.value(at: 47).opacity) - 221) <= 1)
    }

    /// 直接读取真实变换子块也必须精确消费到边界，不能错把下一属性的位当缓动数据。
    @Test func realTransformBlockConsumesExactlyItsPayload() throws {
        let data = try PAGFixtures.data(named: "replacement.pag")
        var reader = PAGByteReader(data: Data(data[11980..<12073]))
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
        let transform = try decoder.readTransform(reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        #expect(try transform.value(at: 30).rotation == 360)
        #expect(decoder.budget.used > 1024)
    }

    /// 在动画文件上替换图片只改变素材快照，轨道仍共享并保留原始关键帧行为。
    @Test func editingDoesNotFreezeAnimation() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "replacement.pag"))
        var composition = file.composition
        let replacement = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        try composition.replaceImage(replacement, at: 0)
        let source = try #require(composition.storage.compositions.last?.layers.first)
        #expect(try source.transform.value(at: 0).rotation == 0)
        #expect(try source.transform.value(at: 59).rotation == 720)
        let layer = try #require(composition.layers.first)
        #expect(composition.image(for: layer.id)?.storage === replacement.storage)
        #expect(file.composition.image(for: layer.id)?.storage !== replacement.storage)
    }
}
