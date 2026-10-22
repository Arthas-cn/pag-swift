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
    /// TrimPaths调查保留的真实子流；只建立字段证据，不把字段读取等同于整文件播放支持。
    private(set) var trimPayloads: [TrimAuditPayload] = []
    /// MergePaths真实子流位置及单字节模式；不把源字段读取当成布尔画面实现。
    private(set) var mergePayloads: [(range: Range<Int>, mode: UInt8)] = []
    /// Repeater真实字段与轨道段数；只供合同调查，不送入正式播放器。
    private(set) var repeaterPayloads: [[String: Any]] = []
    /// 同一标签的原始有界子流，供正式读取器与独立调查值逐项比对。
    private(set) var repeaterReaders: [PAGByteReader] = []
    /// tag69只保留真实边界内的载荷供独立字段读取，不把它当作文字路径播放成功。
    private(set) var textPathReaders: [PAGByteReader] = []
    /// 与tag69同一文字层的原始mask，供路径引用与动画范围核对。
    private(set) var textPathMasks: [[SourceMask]] = []
    /// tag70每个动画器的有界子标签流；只供下一项文本动画源证据调查。
    private(set) var textAnimatorReaders: [PAGByteReader] = []
    /// tag63的有界原始层属性及编码身份；只供运动模糊证据调查。
    private(set) var layerExtraReaders: [(compositionID: UInt32, layerID: UInt32, kind: UInt8,
                                           reader: PAGByteReader, transform: PAGByteReader?,
                                           attributes: (code: UInt16, reader: PAGByteReader)?)] = []
    /// tag27的原始形状子流；先验证真实半径轨道，再决定几何实现范围。
    private(set) var roundCornersReaders: [PAGByteReader] = []
    /// tag29/65的有界DropShadow样式子流及版本，不把字段读取视为滤镜已支持。
    private(set) var dropShadowReaders: [(code: UInt16, reader: PAGByteReader)] = []
    /// tag56/57/58/59/61/85的效果原始子流；只用于真实门禁字段取证。
    private(set) var effectReaders: [(code: UInt16, compositionID: UInt32,
                                      layerID: UInt32, kind: UInt8, reader: PAGByteReader,
                                      transform: PAGByteReader?,
                                      attributes: (code: UInt16, reader: PAGByteReader)?)] = []
    /// 含MergePaths的每层组直接子标签顺序；只记录边界，不推断嵌套子组的画面。
    private(set) var mergeGroups: [[UInt16]] = []
    /// 含RoundCorners的直接组子标签顺序，用于判定圆角前实际路径种类。
    private(set) var roundCornerGroups: [[UInt16]] = []
    /// 真实图层属性中的Track Matte字节及紧邻前层类型；零值也保留以核对缺省。
    private(set) var trackMattePayloads: [(
        compositionID: UInt32, layerID: UInt32, layerIndex: Int, layerKind: UInt8,
        sourceLayerID: UInt32?, sourceKind: UInt8?,
        code: UInt16, offset: Int, length: Int, modeOffset: Int?, mode: UInt8
    )] = []
    /// 原始LayerAttributes的非默认blend字节及所属图层，供剩余门禁取证。
    private(set) var blendModePayloads: [(compositionID: UInt32, layerID: UInt32,
                                          layerKind: UInt8, mode: UInt8)] = []

    /// 沿已取证的文件、矢量合成和形状图层边界进入目标标签，不扫描字节猜标签起点。
    mutating func inspect(_ data: Data) throws {
        var body = PAGByteReader(data: data)
        try body.skip(byteCount: 9)
        while let (code, _, payload) = try block(from: &body) {
            guard code == 2 else { continue }
            var composition = payload
            let compositionID = try composition.readEncodedUInt32()
            var layerIndex = 0
            var previousLayer: (id: UInt32, kind: UInt8)?
            while let (code, _, payload) = try block(from: &composition) {
                guard code == 5 else { continue }
                var layer = payload
                let kind = try layer.readUInt8()
                let layerID = try layer.readEncodedUInt32()
                var textPathMaskReaders: [(code: UInt16, reader: PAGByteReader)] = []
                var hasTextPath = false
                var layerExtra: PAGByteReader?
                var layerTransform: PAGByteReader?
                var layerAttributes: (code: UInt16, reader: PAGByteReader)?
                var effectPayloads: [(code: UInt16, reader: PAGByteReader)] = []
                while let (code, range, payload) = try block(from: &layer) {
                    // Camera没有blend/trackMatte两个Value槽，不能按普通图层的位图误读后续字段。
                    if kind != 7, code == 6 || code == 52 || code == 62 {
                        do {
                            try trackMatte(code, range: range, reader: payload,
                                           compositionID: compositionID, layerID: layerID, layerIndex: layerIndex,
                                           layerKind: kind, previousLayer: previousLayer)
                        } catch {
                            // 原始文件有多份同名层；把编码身份与子流范围带入失败日志才能追溯字段。
                            print("PAG_TRACK_MATTE_FIELD_FAILURE comp=\(compositionID) layer=\(layerID) kind=\(kind) code=\(code) range=\(range) error=\(error)")
                            throw error
                        }
                    }
                    if kind == 4 { try shape(code, range: range, reader: payload, depth: 0) }
                    if kind == 3, code == 14 || code == 84 {
                        textPathMaskReaders.append((code, payload))
                    }
                    if kind == 3, code == 69 {
                        textPathReaders.append(payload)
                        hasTextPath = true
                    }
                    if kind == 3, code == 70 { textAnimatorReaders.append(payload) }
                    if code == 63 { layerExtra = payload }
                    if code == 13 { layerTransform = payload }
                    if code == 6 || code == 52 || code == 62 { layerAttributes = (code, payload) }
                    if code == 29 || code == 65 { dropShadowReaders.append((code, payload)) }
                    if code == 56 || code == 57 || code == 58 || code == 59 || code == 61 || code == 85 {
                        effectPayloads.append((code, payload))
                    }
                }
                for item in effectPayloads {
                    effectReaders.append((item.code, compositionID, layerID, kind,
                                          item.reader, layerTransform, layerAttributes))
                }
                if let layerExtra {
                    layerExtraReaders.append((compositionID, layerID, kind, layerExtra, layerTransform,
                                              layerAttributes))
                }
                if hasTextPath {
                    var masks: [SourceMask] = []
                    for (code, raw) in textPathMaskReaders {
                        var reader = raw
                        masks.append(try decoder.readMask(code: code, reader: &reader))
                    }
                    textPathMasks.append(masks)
                }
                layerIndex += 1
                previousLayer = (layerID, kind)
            }
        }
    }

    /// 只沿上游LayerAttributes的字段顺序读到Track Matte，不用后续未知标签猜测偏移。
    private mutating func trackMatte(_ code: UInt16, range: Range<Int>, reader input: PAGByteReader,
                                    compositionID: UInt32, layerID: UInt32, layerIndex: Int,
                                    layerKind: UInt8, previousLayer: (id: UInt32, kind: UInt8)?) throws {
        var reader = input
        var encodings: [AttributeEncoding] = [.flag, .flag]
        if code == 62 { encodings.append(.flag) }
        encodings += [.flag, .flag, .flag, .flag, .flag, .property, .fixed]
        if code != 6 { encodings.append(.flag) }
        let flags = try PropertyFlags.read(encodings, from: &reader)
        let p = code == 62 ? 3 : 2
        if flags[p].exists { _ = try reader.readEncodedUInt32() }
        if flags[p + 1].exists {
            _ = try reader.readEncodedInt32()
            _ = try reader.readEncodedUInt32()
        }
        if flags[p + 2].exists { _ = try StaticAttributes.frame(from: &reader) }
        if flags[p + 3].exists {
            blendModePayloads.append((compositionID, layerID, layerKind, try reader.readUInt8()))
        }
        let modeOffset = flags[p + 4].exists ? reader.position : nil
        let mode = try flags[p + 4].exists ? reader.readUInt8() : 0
        trackMattePayloads.append((compositionID, layerID, layerIndex, layerKind,
                                   previousLayer?.id, previousLayer?.kind,
                                   code, range.lowerBound, range.count, modeOffset, mode))
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
                var childrenCodes: [UInt16] = []
                while let (child, range, payload) = try block(from: &reader) {
                    childrenCodes.append(child)
                    try shape(child, range: range, reader: payload, depth: depth + 1)
                }
                if childrenCodes.contains(24) { mergeGroups.append(childrenCodes) }
                if childrenCodes.contains(27) { roundCornerGroups.append(childrenCodes) }
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
        case 24:
            // MergePathsTag只有一个FixedValue<UInt8>，没有属性flags或后续轨道。
            mergePayloads.append((range: range, mode: try reader.readUInt8()))
        case 25:
            trimPayloads.append(TrimAuditPayload(range: range, reader: reader))
            return
        case 26:
            // RepeaterTag的Value顺序由源码配置给出；完整子流消费可区分未知尾字段。
            repeaterReaders.append(input)
            let flags = try PropertyFlags.read([.flag, .property, .property, .spatialProperty,
                .spatialProperty, .property, .property, .property, .property], from: &reader)
            let order = try flags[0].exists ? reader.readUInt8() : 0
            let copies = try decoder.readScalarProperty(flags[1], defaultValue: 3, reader: &reader)
            let offset = try decoder.readScalarProperty(flags[2], defaultValue: 0, reader: &reader)
            let anchor = try decoder.readPointProperty(flags[3], defaultValue: .zero,
                                                       spatial: true, reader: &reader)
            let position = try decoder.readPointProperty(flags[4], defaultValue: ScenePoint(x: 100, y: 100),
                                                         spatial: true, reader: &reader)
            let scale = try decoder.readPointProperty(flags[5], defaultValue: .one,
                                                      spatial: false, reader: &reader)
            let rotation = try decoder.readScalarProperty(flags[6], defaultValue: 0, reader: &reader)
            let start = try decoder.readOpacityProperty(flags[7], reader: &reader)
            let end = try decoder.readOpacityProperty(flags[8], reader: &reader)
            repeaterPayloads.append(["offset": range.lowerBound, "length": range.count, "order": order,
                "copies": copies.initialValue, "shift": offset.initialValue,
                "anchor": [anchor.initialValue.x, anchor.initialValue.y],
                "position": [position.initialValue.x, position.initialValue.y],
                "scale": [scale.initialValue.x, scale.initialValue.y], "rotation": rotation.initialValue,
                "startOpacity": start.initialValue, "endOpacity": end.initialValue,
                "scaleFrames": scale.keyframes.map { ["start": $0.startFrame, "end": $0.endFrame,
                    "from": [$0.startValue.x, $0.startValue.y],
                    "to": [$0.endValue.x, $0.endValue.y]] as [String: Any] },
                "rotationFrames": rotation.keyframes.map { ["start": $0.startFrame, "end": $0.endFrame,
                    "from": $0.startValue, "to": $0.endValue] as [String: Any] },
                "segments": [copies.keyframes.count, offset.keyframes.count, anchor.keyframes.count,
                             position.keyframes.count, scale.keyframes.count, rotation.keyframes.count,
                             start.keyframes.count, end.keyframes.count]])
        case 27:
            roundCornersReaders.append(input)
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
