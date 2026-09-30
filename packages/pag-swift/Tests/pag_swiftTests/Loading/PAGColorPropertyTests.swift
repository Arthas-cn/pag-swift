import Foundation
import Testing
@testable import pag_swift

/// SimpleProperty颜色的真实字段读取；不因此开放仍有其他未支持属性的Fill或整文件。
struct PAGColorPropertyTests {
    /// 两份真实Fill颜色轨道都只有一套缓动，时间/全部RGB及半程UInt8截断符合独立调查。
    @Test func realColorFieldsUseSingleEasing() throws {
        for (range, green) in [(1002..<1026, UInt8(223)), (1200..<1224, UInt8(224))] {
            let track = try StrokeFixtures.color(PAGFixtures.data(named: "list/1.pag").subdata(in: range))
            #expect(track.keyframes.map(\.startFrame) == [0, 28])
            #expect(track.keyframes.map(\.endFrame) == [28, 41])
            #expect(track.initialValue == SceneColor(red: 255, green: 88, blue: 88))
            #expect(track.keyframes[0].endValue == SceneColor(red: 255, green: green, blue: 81))
            #expect(track.keyframes[1].endValue == track.initialValue)
            for keyframe in track.keyframes {
                guard case .bezier(_, nil) = keyframe.easing else { Issue.record("SimpleProperty Color不能消费多维ease"); return }
            }
            let middle = try PropertyEvaluation.color(track, at: 14)
            #expect(middle == SceneColor(red: 255, green: green == 223 ? 155 : 156, blue: 84))
        }
    }

    /// 默认颜色不消费任何字节；真实静态RGB字段使用三个通道而不是额外读取alpha。
    @Test func defaultsAndStaticColorsConsumeOnlyTheirFields() throws {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 10_000))
        var empty = PAGByteReader(data: Data())
        let white = SceneColor(red: 255, green: 255, blue: 255)
        let absent = try decoder.readColorProperty(PropertyFlags(exists: false, isAnimated: false, hasSpatial: false),
            defaultValue: white, reader: &empty)
        #expect(absent.initialValue == white && !absent.isAnimated && empty.position == 0)
        var reader = PAGByteReader(data: try PAGFixtures.data(named: "0.pag").subdata(in: 210..<213))
        let color = try decoder.readColorProperty(PropertyFlags(exists: true, isAnimated: false, hasSpatial: false),
            defaultValue: white, reader: &reader)
        #expect(color.initialValue == SceneColor(red: 34, green: 31, blue: 31))
        #expect(reader.remainingByteCount == 0 && !color.isAnimated)
    }

    /// 真实颜色载荷截断或附加尾随不能成功，关键帧预算在读取其列表之前扣减。
    @Test func truncatedColorAndBudgetFail() throws {
        let data = try PAGFixtures.data(named: "list/1.pag").subdata(in: 1002..<1026)
        for end in 0..<data.count { #expect(throws: PAGError.self) { try StrokeFixtures.color(data.prefix(end)) } }
        #expect(throws: PAGError.self) { try StrokeFixtures.color(data + Data([0])) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try StrokeFixtures.color(data, maximumBytes: 1)
        }
    }
}
