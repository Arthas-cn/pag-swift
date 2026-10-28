import Foundation
import Testing
@testable import pag_swift

/// 真实Stroke字段和损坏输入；内部字段成功不表示整文件的后续语义已经支持。
struct PAGStrokeTests {
    /// 合法容器边界取得的756份载荷必须全部读完，动画组跳过数量与独立调查一致。
    @Test func allRealStrokeFieldsMatchIndependentSurvey() throws {
        var fields = 0, files = 0, skipped = 0, animations = 0, dashes = 0, butt = 0, miter = 0
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            let found = try ShapeTagFixtures.ranges(in: data, tag: 21)
            skipped += found.skippedGroups
            if !found.payloads.isEmpty { files += 1 }
            for range in found.payloads {
                let stroke = try StrokeFixtures.decode(data.subdata(in: range))
                fields += 1
                if stroke.width.isAnimated { animations += 1 }
                if stroke.dashes != nil { dashes += 1 }
                if stroke.cap == .butt { butt += 1 }
                if stroke.join == .miter { miter += 1 }
                #expect(stroke.compositeOrder == .belowPrevious)
                #expect(!stroke.color.isAnimated && !stroke.miterLimit.isAnimated && !stroke.opacity.isAnimated)
                #expect(stroke.isAnimated == stroke.width.isAnimated)
            }
        }
        #expect(fields == 756 && files == 32 && skipped == 54)
        #expect(animations == 13 && dashes == 6 && butt == 175 && miter == 211)
    }

    /// 静态真实字段核对默认width、显式miter、RGB和cap/join，不能把缺省描边色误用Fill的Red。
    @Test func readsStaticValuesAndDefaults() throws {
        let first = try StrokeFixtures.source(named: "0.pag", range: 204..<213)
        #expect(first.cap == .butt && first.join == .miter && first.miterLimit.initialValue == 10)
        #expect(first.color.initialValue == SceneColor(red: 34, green: 31, blue: 31))
        #expect(first.width.initialValue == 2 && first.opacity.initialValue == 255 && first.dashes == nil)
        let second = try StrokeFixtures.source(named: "0.pag", range: 746..<760)
        #expect(second.cap == .round && Float(second.width.initialValue).bitPattern == 0x41033333)
        let logo = try StrokeFixtures.source(named: "PAG_LOGO.pag", range: 977..<988)
        #expect(logo.cap == .round && logo.join == .round && logo.miterLimit.initialValue == 4)
        #expect(logo.width.initialValue == 43 && logo.color.initialValue == .defaultFill)
    }

    /// PAG_LOGO线宽轨道按独立Float位模式验证全部端值，并保留末段超过1的Bezier导致的负宽。
    @Test func readsRealAnimatedWidthAndOvershoot() throws {
        let stroke = try StrokeFixtures.source(named: "PAG_LOGO.pag", range: 10252..<10312)
        let frames = stroke.width.keyframes
        #expect(frames.map(\.startFrame) == [250, 274, 281, 286])
        #expect(frames.map(\.endFrame) == [274, 281, 286, 298])
        #expect(frames.map { Float($0.startValue).bitPattern } == [0x43f60000, 0x42bcd6b6, 0x41b00000, 0x40a00000])
        #expect(frames.last?.endValue == 0 && stroke.isAnimated)
        for frame in frames {
            guard case .bezier(_, nil) = frame.easing else { Issue.record("真实width必须保留单Bezier缓动"); return }
        }
        #expect(try PropertyEvaluation.scalar(stroke.width, at: 292) < 0)
        #expect(try StrokeEvaluation.evaluate(stroke, at: 292) == nil)
        #expect(try StrokeEvaluation.evaluate(stroke, at: 250)?.style.width == 492)
    }

    /// 真实圆点虚线的首项0与缺省第二项10必须保留，Custom的存在位不能多消费一个动画位。
    @Test func readsRealZeroOnDashes() throws {
        for range in [205..<221, 350..<366, 4452..<4468] {
            let stroke = try StrokeFixtures.source(named: "test.pag", range: range)
            let dashes = try #require(stroke.dashes)
            #expect(dashes.intervals.map(\.initialValue) == [0, 10])
            #expect(dashes.offset.initialValue == 0 && !dashes.isAnimated)
            #expect(stroke.cap == .round && stroke.join == .round && stroke.width.initialValue == 5)
        }
    }

    /// 实际动画/Custom载荷的每个短前缀、尾随、非法枚举及NaN都明确失败，不发布半个Stroke。
    @Test func malformedPayloadsFailCompletely() throws {
        for (name, range) in [("PAG_LOGO.pag", 10252..<10312), ("test.pag", 205..<221)] {
            let data = try PAGFixtures.data(named: name).subdata(in: range)
            for end in 0..<data.count { #expect(throws: PAGError.self) { try StrokeFixtures.decode(data.prefix(end)) } }
            #expect(throws: PAGError.self) { try StrokeFixtures.decode(data + Data([0])) }
        }
        let data = try PAGFixtures.data(named: "PAG_LOGO.pag").subdata(in: 977..<988)
        for (index, reason) in [(2, "strokeLineCap"), (3, "strokeLineJoin")] {
            var damaged = data
            damaged[index] = 255
            #expect(throws: PAGError.unsupportedFeature(reason)) { try StrokeFixtures.decode(damaged) }
        }
        for (bit, value, reason): (UInt8, UInt8, String) in [(1, 1, "strokeBlendMode"), (2, 255, "strokeCompositeOrder")] {
            var damaged = data
            damaged[0] |= bit
            damaged.insert(value, at: 2)
            #expect(throws: PAGError.unsupportedFeature(reason)) { try StrokeFixtures.decode(damaged) }
        }
        var nonfinite = try PAGFixtures.data(named: "0.pag").subdata(in: 746..<760)
        nonfinite.replaceSubrange(10..<14, with: [0, 0, 0xc0, 0x7f])
        #expect(throws: PAGError.self) { try StrokeFixtures.decode(nonfinite) }
    }

    /// 低预算与预取消在内部入口失败；正式Loader在描边显示门禁通过后完整接受真实0.pag。
    @Test func budgetCancellationAndPublicGate() async throws {
        let data = try PAGFixtures.data(named: "0.pag")
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try StrokeFixtures.decode(data.subdata(in: 204..<213), maximumBytes: 511)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeFixtures.decode(data.subdata(in: 204..<213))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let file = try await PAGLoader().load(data: data)
        #expect(!file.composition.layers.isEmpty)
    }
}
