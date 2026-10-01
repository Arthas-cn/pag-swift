import Foundation
import Testing
@testable import pag_swift

/// 既有形状属性的真实载荷、损坏边界及正式支持范围；不以字段成功冒充整文件支持。
struct PAGShapePropertyTests {
    /// 原119份与新增七份渐变的目标载荷均与独立字段调查一致，包含动画组内的嵌套元素。
    @Test func allRealFieldsMatchIndependentSurvey() throws {
        let urls = try PAGFixtures.allPAGURLs()
        var counts: [String: Int] = [:]
        var animatedCounts: [Int: Int] = [:]
        for url in urls {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(Data(contentsOf: url))
            for (tag, count) in inspection.counts { counts[tag, default: 0] += count }
            for record in inspection.animated {
                animatedCounts[try #require(record["tag"] as? Int), default: 0] += 1
            }
        }
        #expect(urls.count == 126)
        #expect(counts == ["15": 2182, "16": 27, "17": 35, "18": 4, "20": 1635])
        #expect(animatedCounts == [15: 54, 20: 12])
    }

    /// red真实载荷验证缺省值与Custom边界；组前缀必须停在首个子标签前。
    @Test func staticDefaultsAndGroupPrefixRemainExact() throws {
        let data = try PAGFixtures.data(named: "red.pag")
        var decoder = makeDecoder()
        var group = PAGByteReader(data: data.subdata(in: 133..<159))
        let properties = try decoder.readShapeGroupProperties(reader: &group)
        #expect(group.position == 10 && properties.hasElements)
        let value = try properties.transform.value(at: 0)
        #expect(properties.transform.isAnimated == false)
        #expect(value.base.anchor == .zero && value.base.position == .zero)
        #expect(value.base.rotation == 0 && value.base.opacity == 255 && value.skew == 0 && value.skewAxis == 0)
        #expect(value.base.scale == ScenePoint(x: 0.4798107445240021, y: 4.25517463684082))
        var rectangle = PAGByteReader(data: data.subdata(in: 145..<154))
        let rect = try decoder.readRectangleProperties(reader: &rectangle)
        #expect(rectangle.remainingByteCount == 0 && rect.isAnimated == false && rect.reversed == false)
        #expect(rect.size.initialValue == ScenePoint(x: 1500, y: 300))
        #expect(rect.position.initialValue == .zero && rect.roundness.initialValue == 0)
        var fill = PAGByteReader(data: data.subdata(in: 156..<157))
        let paint = try decoder.readFillProperties(reader: &fill)
        #expect(fill.remainingByteCount == 0 && paint.isAnimated == false)
        #expect(paint.color.initialValue == .defaultFill && paint.opacity.initialValue == 255)
        #expect(decoder.budget.used == 512 + 256 + 128)
    }

    /// 真实双动画组保留两条11段轨道；Fill透明轨道与组透明轨道独立保留，不退化为初值。
    @Test func animatedFieldsRetainTracks() throws {
        var decoder = makeDecoder()
        var group = PAGByteReader(data: try PAGFixtures.data(named: "list/18.pag").subdata(in: 3458..<4305))
        let transform = try decoder.readShapeGroupProperties(reader: &group).transform
        #expect(transform.position.keyframes.count == 11 && transform.rotation.keyframes.count == 11)
        #expect(transform.isAnimated && transform.anchor.isAnimated == false && transform.scale.isAnimated == false)
        var alpha = PAGByteReader(data: try PAGFixtures.data(named: "alpha2.pag").subdata(in: 1902..<1967))
        #expect(try decoder.readShapeGroupProperties(reader: &alpha).transform.opacity.keyframes.count == 2)
        var fill = PAGByteReader(data: try PAGFixtures.data(named: "wstask_circle.pag").subdata(in: 1623..<1637))
        let paint = try decoder.readFillProperties(reader: &fill)
        #expect(paint.isAnimated && paint.opacity.keyframes.count == 2 && paint.color.isAnimated == false)
    }

    /// 每个真实属性前缀被截短均失败；矩形与Fill尾随也不能发布源模型。
    @Test func truncationAndTrailingBytesFail() throws {
        for (tag, name, range): (UInt16, String, Range<Int>) in [
            (15, "list/18.pag", 3458..<4305), (16, "red.pag", 145..<154),
            (20, "list/8.pag", 4051..<4067)
        ] {
            let data = try PAGFixtures.data(named: name).subdata(in: range)
            let consumed = try read(tag, data: data)
            for end in 0..<consumed {
                #expect(throws: PAGError.self) { try read(tag, data: data.prefix(end)) }
            }
            // 组入口只读前缀，后续Custom由父读取器负责；其他两个标签必须在此处完整结束。
            if tag != 15 {
                #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: data.count)) {
                    try read(tag, data: data + Data([0]))
                }
            }
        }
    }

    /// 在真实静态载荷上插入非法Value，明确拒绝blend、填充顺序和规则，不宽容降级。
    @Test func unsupportedValuesRemainExplicit() throws {
        let original = try PAGFixtures.data(named: "red.pag")
        for (tag, bit, reason): (UInt16, UInt8, String) in [
            (15, 1, "shapeBlendMode"), (20, 1, "fillBlendMode"),
            (20, 2, "fillCompositeOrder"), (20, 4, "fillRule")
        ] {
            var damaged = original.subdata(in: tag == 15 ? 133..<159 : 156..<157)
            damaged[0] |= bit
            // 原始red在这些Value上均缺省；插入非零字节构造明确损坏/未支持输入。
            damaged.insert(255, at: tag == 15 ? 2 : 1)
            #expect(throws: PAGError.unsupportedFeature(reason)) { try read(tag, data: damaged) }
        }
    }

    /// 真实red的组缩放或矩形尺寸改为NaN时，读取器在具体Float偏移拒绝，不能等到矩阵/GPU才失败。
    @Test func nonfiniteStaticFieldsFailAtReadBoundary() throws {
        let original = try PAGFixtures.data(named: "red.pag")
        for (tag, range, offset): (UInt16, Range<Int>, Int) in [(15, 133..<159, 2), (16, 145..<154, 1)] {
            var damaged = original.subdata(in: range)
            damaged.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0xc0, 0x7f])
            #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: offset)) {
                try read(tag, data: damaged)
            }
        }
    }

    /// 正式shape节点的256字节预算与新Fill轨道外壳叠加，而不是被内部读取器替代。
    @Test func formalShapeBudgetIncludesBothShells() throws {
        let data = try PAGFixtures.data(named: "red.pag").subdata(in: 156..<157)
        var decoder = makeDecoder(maximumBytes: 384)
        var reader = PAGByteReader(data: data)
        _ = try decoder.readShape(code: 20, reader: &reader, depth: 0)
        #expect(decoder.budget.used == 384 && reader.remainingByteCount == 0)
        var limited = makeDecoder(maximumBytes: 383)
        var retry = PAGByteReader(data: data)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try limited.readShape(code: 20, reader: &retry, depth: 0)
        }
    }

    /// 真实0.pag的形状组自身为常量，内部动态Path仍正常通过正式解码与动画层识别。
    @Test func constantGroupsStillAcceptAnimatedChildren() async throws {
        let file = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "0.pag"))
        var sawAnimatedGroup = false
        for composition in file.storage.compositions {
            for layer in composition.layers {
                guard case .shape(let elements) = layer.content else { continue }
                for element in elements {
                    guard case .group(let transform, let children) = element else { continue }
                    #expect(transform.isAnimated == false)
                    var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
                    if try ShapePreparation.isAnimated(children, budget: &budget) { sawAnimatedGroup = true }
                }
            }
        }
        #expect(sawAnimatedGroup)
    }

    /// 每个新模型外壳先扣预算，动画段额外计费，预取消任务连常量载荷也不能发布。
    @Test func shellTrackBudgetsAndCancellation() async throws {
        let original = try PAGFixtures.data(named: "red.pag")
        for (tag, range, shell): (UInt16, Range<Int>, Int) in [
            (15, 133..<159, 512), (16, 145..<154, 256), (20, 156..<157, 128)
        ] {
            let data = original.subdata(in: range)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try read(tag, data: data, maximumBytes: shell - 1)
            }
            await #expect(throws: CancellationError.self) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.cancelAll()
                    group.addTask { _ = try read(tag, data: data) }
                    for try await _ in group {}
                }
            }
        }
        let data = try PAGFixtures.data(named: "list/8.pag").subdata(in: 4051..<4067)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try read(20, data: data, maximumBytes: 128)
        }
    }

    /// 动画门禁开放后四份完整文件正式载入，准备层确实安装动态轨道，而不是只返回静态首帧。
    @Test(arguments: ["list/14.pag", "list/16.pag", "list/18.pag", "list/9.pag"])
    func formalEntryPreservesCompleteAnimatedFiles(_ name: String) async throws {
        let file = try await PAGSceneDecoder.decode(PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.dynamicShapes != nil)
    }

    /// 其余三份文件仍有未支持语义，必须拒绝完整文件，不能因属性能读就跳过内容；渐变文件另组回归。
    @Test(arguments: [("alpha2.pag", "trackMatte"), ("list/2.pag", "layerTag:14"),
                      ("list/8.pag", "shapeTag:24")])
    func remainingContentStillFailsExplicitly(_ name: String, _ reason: String) async throws {
        await #expect(throws: PAGError.unsupportedFeature(reason)) {
            try await PAGSceneDecoder.decode(PAGFixtures.data(named: name))
        }
    }

    /// 建立只供字段测试使用的独立解码器，逻辑预算与完整文件解码相同。
    private func makeDecoder(maximumBytes: Int = 64 * 1024 * 1024) -> PAGSceneDecoder {
        PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
    }

    /// 调用目标内部读取器并返回所消费字节数；group只读前缀，其他标签完整消费。
    private func read(_ tag: UInt16, data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> Int {
        var decoder = makeDecoder(maximumBytes: maximumBytes)
        var reader = PAGByteReader(data: data)
        switch tag {
        case 15: _ = try decoder.readShapeGroupProperties(reader: &reader)
        case 16: _ = try decoder.readRectangleProperties(reader: &reader)
        case 20: _ = try decoder.readFillProperties(reader: &reader)
        default: throw PAGError.invalidArgument("shapePropertyTestTag")
        }
        return reader.position
    }
}
