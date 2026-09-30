import Foundation
import Testing
@testable import pag_swift

/// 路径压缩字段的真实片段、完整动画与失败边界；内部读取不代表ShapePath已经可以公开播放。
struct PAGPathTests {
    /// 全部静态组前缀内的2087个真实tag19均完整消费；54个动画组明确未探查内部内容。
    @Test(.timeLimit(.minutes(2))) func realPayloadSurvey() throws {
        var count = 0
        var animated = 0
        var skipped = 0
        var files = 0
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            let survey = try PathFixtures.ranges(in: data)
            skipped += survey.skippedGroups
            if !survey.paths.isEmpty { files += 1 }
            for range in survey.paths {
                do {
                    let property = try PathFixtures.decode(data.subdata(in: range))
                    count += 1
                    if property.isAnimated { animated += 1 }
                } catch {
                    Issue.record("真实路径读取失败：\(url.lastPathComponent) \(range)：\(error)")
                }
            }
        }
        #expect(count == 2_087 && animated == 591 && files == 39 && skipped == 54)
    }

    /// 六份真实短字段覆盖8种压缩records，核对独立Float位模式及省略控制点的补齐顺序。
    @Test func compressedRecordsKeepExactPoints() throws {
        let horizontal = try PathFixtures.property(named: "list/12.pag", range: 597..<605).initialValue
        #expect(horizontal.verbs == [.move, .line])
        #expect(bits(horizontal) == [[0x41c1999a, 0x41f86667], [0x42053333, 0x41f86667]])
        let vertical = try PathFixtures.property(named: "list/12.pag", range: 52_757..<52_765).initialValue
        #expect(bits(vertical) == [[0x40f66667, 0x424b6667], [0x40f66667, 0x42366667]])
        let line = try PathFixtures.property(named: "list/7.pag", range: 1_636..<1_644).initialValue
        #expect(bits(line) == [[0x410a6667, 0xc138cccd], [0xc10a6667, 0x4138cccd]])
        let first = try PathFixtures.property(named: "list/9.pag", range: 25_604..<25_615).initialValue
        #expect(first.verbs == [.move, .cubic])
        #expect(bits(first) == [[0xc11f3333, 0xc08ccccd], [0xc11f3333, 0xc08ccccd],
                               [0x40c66667, 0xc0833333], [0x411f3333, 0x408ccccd]])
        let second = try PathFixtures.property(named: "list/8.pag", range: 5_996..<6_008).initialValue
        #expect(bits(second) == [[0x41e06667, 0xc1173333], [0x41dccccd, 0xc1166667],
                                [0xc1e06667, 0x41173333], [0xc1e06667, 0x41173333]])
        let closed = try PathFixtures.property(named: "list/17.pag", range: 242_899..<242_906).initialValue
        #expect(closed.verbs == [.move, .cubic, .close])
        #expect(bits(closed) == [[0xbdcccccd, 0xbdcccccd], [0x3dcccccd, 0x3dcccccd],
                                [0, 0], [0xbdcccccd, 0xbdcccccd]])
    }

    /// 0.pag真实动画在line/cubic之间形变，末值之后的Bezier从剩余位开始；不得提前对齐丢失控制点。
    @Test func realMorphTracksAndUnalignedEasing() throws {
        let first = try PathFixtures.property(named: "0.pag", range: 631..<744)
        #expect(first.keyframes.map(\.startFrame) == [0, 6, 12, 18])
        #expect(first.keyframes.map(\.endFrame) == [6, 12, 18, 25])
        #expect(first.keyframes[1].endValue.verbs == [.move, .line, .line])
        let second = try PathFixtures.property(named: "0.pag", range: 1_056..<1_135)
        #expect(second.keyframes.map(\.startFrame) == [6, 12, 18])
        #expect(second.keyframes.map(\.endFrame) == [12, 18, 25])
        for key in first.keyframes + second.keyframes {
            guard case .bezier(let curve, nil) = key.easing else {
                Issue.record("真实路径缓动未保留Bezier")
                continue
            }
            #expect(abs(curve.timing(at: 0.5) - 0.5) < 0.0001)
        }
    }

    /// 默认/显式空路径都保留非nil空值；真实片段任意截断、尾随、攻击计数和低预算不能返回半个属性。
    @Test func emptyDamageAndBudget() throws {
        // 两个独立属性字段的空值分支；并非新造的完整PAG文件。
        #expect(try PathFixtures.decode(Data([0])).initialValue.verbs.isEmpty)
        #expect(try PathFixtures.decode(Data([1, 0])).initialValue.points.isEmpty)
        let data = try PAGFixtures.data(named: "0.pag").subdata(in: 631..<744)
        for count in 0..<data.count {
            #expect(throws: PAGError.self) { try PathFixtures.decode(data.prefix(count)) }
        }
        #expect(throws: PAGError.self) { try PathFixtures.decode(data + Data([0])) }
        #expect(throws: PAGError.self) { try PathFixtures.decode(Data([1, 255, 255, 255, 255, 15])) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try PathFixtures.decode(data, maximumBytes: 127)
        }
    }

    /// 预先取消的内部读取传播CancellationError；路径与描边门禁通过后整份真实0.pag可以完整载入。
    @Test func cancellationAndPublicGate() async throws {
        let data = try PAGFixtures.data(named: "0.pag")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PathFixtures.decode(data.subdata(in: 631..<744))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let file = try await PAGLoader().load(data: data)
        #expect(!file.composition.layers.isEmpty)
    }

    /// 将实际Float来源的坐标转成位模式，以独立读取记录核对精度，避免十进制容差掩盖布局错误。
    private func bits(_ path: SourcePath) -> [[UInt32]] {
        path.points.map { [Float($0.x).bitPattern, Float($0.y).bitPattern] }
    }
}
