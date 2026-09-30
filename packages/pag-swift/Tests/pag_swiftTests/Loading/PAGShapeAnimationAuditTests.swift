import Foundation
import Testing
@testable import pag_swift

/// 显式调查形状轨道及Ellipse/PolyStar路径输入；只读取源码已证明的布局，不产生可播放文档。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_SHAPE_ANIMATION_AUDIT"] == "1",
                "设置PAG_SHAPE_ANIMATION_AUDIT=1调查真实形状动画字段"))
struct PAGShapeAnimationAuditTests {
    /// 按真实容器边界递归调查全部资源；其他标签只作边界跳过，不能将该探针当完整解码成功。
    @Test func recordsRealAnimatedShapeFields() throws {
        let root = try PAGFixtures.rootURL().path + "/"
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            let name = url.path.replacingOccurrences(of: root, with: "")
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(data)
            let record: [String: Any] = ["file": name, "counts": inspection.counts,
                "animated": inspection.animated, "generators": inspection.generators]
            let encoded = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            print("SHAPE_ANIMATION \(String(decoding: encoded, as: UTF8.self))")
        }
    }
}

/// 测试专用的字段调查游标；独立逐字段消费与生产读取器相互核对，不调用正式形状门禁。
struct ShapeAnimationInspection {
    /// 调查侧逐字段调用基础属性读取器，完整消费动画组前缀后才访问子标签。
    private var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
    /// 对照侧调用五种形状属性读取器，与调查侧分别累计预算。
    private var production = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
    /// 五种目标标签各自实际发现的总数，包含静态记录。
    private(set) var counts: [String: Int] = [:]
    /// 具有动画的真实载荷范围、字段名和段数；只用于调查日志，不跨任务传送。
    private(set) var animated: [[String: Any]] = []
    /// 新路径生成器的源初值和轨道段数，供选择真实边界夹具；不表示正式播放器已经接纳。
    private(set) var generators: [[String: Any]] = []
    /// 渐变字段调查保留的有界真实载荷；不会送入正式文档或播放入口。
    private(set) var gradientPayloads: [GradientAuditPayload] = []

    /// 沿已取证的文件、矢量合成和形状图层边界进入目标标签，不扫描字节猜标签起点。
    mutating func inspect(_ data: Data) throws {
        var body = PAGByteReader(data: data)
        try body.skip(byteCount: 9)
        while let (code, _, payload) = try block(from: &body) {
            guard code == 2 else { continue }
            var composition = payload
            _ = try composition.readEncodedUInt32()
            while let (code, _, payload) = try block(from: &composition) {
                guard code == 5 else { continue }
                var layer = payload
                let kind = try layer.readUInt8()
                _ = try layer.readEncodedUInt32()
                guard kind == 4 else { continue }
                while let (code, range, payload) = try block(from: &layer) {
                    try shape(code, range: range, reader: payload, depth: 0)
                }
            }
        }
    }

    /// 布局分别来自shapes下ShapeGroup/Rectangle/Ellipse/PolyStar/Fill的Tag配置。
    private mutating func shape(_ code: UInt16, range: Range<Int>, reader input: PAGByteReader,
                                depth: Int) throws {
        guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
        var reader = input
        switch code {
        case 15:
            let flags = try PropertyFlags.read([.flag, .spatialProperty, .spatialProperty, .property,
                .property, .property, .property, .property, .flag], from: &reader)
            if flags[0].exists { _ = try reader.readUInt8() }
            let anchor = try decoder.readPointProperty(flags[1], defaultValue: .zero, spatial: true, reader: &reader)
            let position = try decoder.readPointProperty(flags[2], defaultValue: .zero, spatial: true, reader: &reader)
            let scale = try decoder.readPointProperty(flags[3], defaultValue: .one, spatial: false, reader: &reader)
            let skew = try decoder.readScalarProperty(flags[4], defaultValue: 0, reader: &reader)
            let axis = try decoder.readScalarProperty(flags[5], defaultValue: 0, reader: &reader)
            let rotation = try decoder.readScalarProperty(flags[6], defaultValue: 0, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[7], reader: &reader)
            var checked = input
            let properties = try production.readShapeGroupProperties(reader: &checked)
            #expect(checked.position == reader.position && properties.hasElements == flags[8].exists)
            let transform = properties.transform
            compare(transform.anchor, anchor)
            compare(transform.position, position)
            compare(transform.scale, scale)
            compare(transform.skew, skew)
            compare(transform.skewAxis, axis)
            compare(transform.rotation, rotation)
            compare(transform.opacity, opacity)
            #expect(transform.isAnimated == flags.contains(where: \.isAnimated))
            record(code, range: range, fields: ["anchor", "position", "scale", "skew", "skewAxis", "rotation", "opacity"],
                frames: [anchor.keyframes.count, position.keyframes.count, scale.keyframes.count, skew.keyframes.count,
                         axis.keyframes.count, rotation.keyframes.count, opacity.keyframes.count])
            if flags[8].exists {
                while let (child, range, payload) = try block(from: &reader) {
                    try shape(child, range: range, reader: payload, depth: depth + 1)
                }
            }
        case 16:
            let flags = try PropertyFlags.read([.flag, .property, .spatialProperty, .property], from: &reader)
            let size = try decoder.readPointProperty(flags[1], defaultValue: ScenePoint(x: 100, y: 100),
                                                     spatial: false, reader: &reader)
            let position = try decoder.readPointProperty(flags[2], defaultValue: .zero, spatial: true, reader: &reader)
            let radius = try decoder.readScalarProperty(flags[3], defaultValue: 0, reader: &reader)
            var checked = input
            let rectangle = try production.readRectangleProperties(reader: &checked)
            #expect(checked.position == reader.position && rectangle.reversed == flags[0].exists)
            compare(rectangle.size, size)
            compare(rectangle.position, position)
            compare(rectangle.roundness, radius)
            #expect(rectangle.isAnimated == flags.contains(where: \.isAnimated))
            record(code, range: range, fields: ["size", "position", "roundness"],
                   frames: [size.keyframes.count, position.keyframes.count, radius.keyframes.count])
        case 17:
            let flags = try PropertyFlags.read([.flag, .property, .spatialProperty], from: &reader)
            let size = try decoder.readPointProperty(flags[1], defaultValue: ScenePoint(x: 100, y: 100),
                                                     spatial: false, reader: &reader)
            let position = try decoder.readPointProperty(flags[2], defaultValue: .zero, spatial: true, reader: &reader)
            var checked = input
            let ellipse = try production.readEllipse(reader: &checked)
            #expect(checked.position == reader.position && ellipse.reversed == flags[0].exists)
            compare(ellipse.size, size)
            compare(ellipse.position, position)
            #expect(ellipse.isAnimated == flags.contains(where: \.isAnimated))
            record(code, range: range, fields: ["size", "position"],
                   frames: [size.keyframes.count, position.keyframes.count])
            generators.append(["tag": Int(code), "start": range.lowerBound, "end": range.upperBound,
                "reversed": flags[0].exists, "size": [size.initialValue.x, size.initialValue.y],
                "position": [position.initialValue.x, position.initialValue.y],
                "segments": [size.keyframes.count, position.keyframes.count]])
        case 18:
            try polyStar(range: range, reader: &reader)
        case 20:
            let flags = try PropertyFlags.read([.flag, .flag, .flag, .property, .property], from: &reader)
            for flag in flags.prefix(3) where flag.exists { _ = try reader.readUInt8() }
            let color = try decoder.readColorProperty(flags[3], defaultValue: .defaultFill, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[4], reader: &reader)
            var checked = input
            let fill = try production.readFillProperties(reader: &checked)
            #expect(checked.position == reader.position)
            compare(fill.color, color)
            compare(fill.opacity, opacity)
            #expect(fill.isAnimated == flags.contains(where: \.isAnimated))
            record(code, range: range, fields: ["color", "opacity"],
                   frames: [color.keyframes.count, opacity.keyframes.count])
        case 22, 23:
            gradientPayloads.append(GradientAuditPayload(code: code, range: range, reader: reader))
            return
        default:
            // 调查只负责目标标签；跳过其他已知边界不意味着播放器支持该语义。
            return
        }
        try StaticAttributes.requireEnd(of: reader)
    }

    /// PolyStar.cpp依次保存BitFlag、Value、Simple、Spatial及五个Simple轨道；圆度原值不能除100。
    private mutating func polyStar(range: Range<Int>, reader: inout PAGByteReader) throws {
        var checked = reader
        let source = try production.readPolyStar(reader: &checked)
        let flags = try PropertyFlags.read([.flag, .flag, .property, .spatialProperty,
            .property, .property, .property, .property, .property], from: &reader)
        let kind = try flags[1].exists ? reader.readUInt8() : 0
        let points = try decoder.readScalarProperty(flags[2], defaultValue: 5, reader: &reader)
        let position = try decoder.readPointProperty(flags[3], defaultValue: .zero, spatial: true, reader: &reader)
        #expect(source.kind.rawValue == kind && source.reversed == flags[0].exists)
        compare(source.points, points)
        compare(source.position, position)
        let names = ["rotation", "innerRadius", "outerRadius", "innerRoundness", "outerRoundness"]
        let defaults: [Double] = [0, 50, 100, 0, 0]
        let properties = [source.rotation, source.innerRadius, source.outerRadius,
                          source.innerRoundness, source.outerRoundness]
        var initial: [String: Double] = ["points": points.initialValue]
        var frames: [Int] = [points.keyframes.count, position.keyframes.count]
        for index in names.indices {
            let property = try decoder.readScalarProperty(flags[index + 4], defaultValue: defaults[index], reader: &reader)
            compare(properties[index], property)
            initial[names[index]] = property.initialValue
            frames.append(property.keyframes.count)
        }
        #expect(checked.position == reader.position && source.isAnimated == flags.contains(where: \.isAnimated))
        record(18, range: range, fields: ["points", "position"] + names, frames: frames)
        generators.append(["tag": 18, "start": range.lowerBound, "end": range.upperBound,
            "reversed": flags[0].exists, "kind": kind, "position": [position.initialValue.x, position.initialValue.y],
            "initial": initial, "segments": frames])
    }

    /// 比较独立字段读取与生产映射的初值、段数、时间和端值，防止同类型轨道错接字段。
    private func compare<Value: Sendable & Equatable>(_ actual: SourceProperty<Value>, _ expected: SourceProperty<Value>,
                                                     sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.initialValue == expected.initialValue, sourceLocation: sourceLocation)
        #expect(actual.keyframes.count == expected.keyframes.count, sourceLocation: sourceLocation)
        for (actual, expected) in zip(actual.keyframes, expected.keyframes) {
            #expect(actual.startFrame == expected.startFrame && actual.endFrame == expected.endFrame,
                    sourceLocation: sourceLocation)
            #expect(actual.startValue == expected.startValue && actual.endValue == expected.endValue,
                    sourceLocation: sourceLocation)
        }
    }

    /// 只输出真正含关键帧的记录，同时保留每种标签的总计便于核对调查覆盖。
    private mutating func record(_ code: UInt16, range: Range<Int>, fields: [String], frames: [Int]) {
        counts[String(code), default: 0] += 1
        guard frames.contains(where: { $0 > 0 }) else { return }
        var values: [String: Int] = [:]
        for (field, count) in zip(fields, frames) where count > 0 { values[field] = count }
        animated.append(["tag": Int(code), "start": range.lowerBound, "end": range.upperBound, "fields": values])
    }

    /// 读取独立子流并验证End处边界；范围始终保持真实文件绝对偏移。
    private func block(from reader: inout PAGByteReader) throws -> (UInt16, Range<Int>, PAGByteReader)? {
        let header = try PAGTagHeader.read(from: &reader)
        if header.code == 0 {
            try StaticAttributes.requireEnd(of: reader)
            return nil
        }
        return (header.code, header.payloadRange, try reader.readSubreader(byteCount: header.payloadRange.count))
    }
}
