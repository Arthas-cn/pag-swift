import Foundation
import Testing
@testable import pag_swift

/// 渐变取证专用的子流，边界来自真实tag容器，不扫描字节寻找形似标签的值。
struct GradientAuditPayload {
    /// GradientFill22或GradientStroke23。
    let code: UInt16
    /// 原文件中的绝对载荷范围，便于后续引用真实夹具。
    let range: Range<Int>
    /// 已限制在载荷边界内的独立游标。
    let reader: PAGByteReader
}

/// 按Gradient.cpp/DataTypes.cpp完整调查真实渐变字段；不开放生产tag或构造可播放文档。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_GRADIENT_AUDIT"] == "1",
                "设置PAG_GRADIENT_AUDIT=1调查真实渐变载荷"))
struct PAGGradientAuditTests {
    /// 全部真实PAG的渐变payload都完整消费并输出类型、轨道及原始stop信息，其他tag仍仅作边界跳过。
    @Test func recordsRealGradientFields() throws {
        let root = try PAGFixtures.rootURL().path + "/"
        var count = 0
        for url in try PAGFixtures.allPAGURLs() {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(Data(contentsOf: url))
            for payload in inspection.gradientPayloads {
                var fields = try inspect(payload)
                fields["file"] = String(url.path.dropFirst(root.count))
                let json = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
                print("GRADIENT_AUDIT \(String(decoding: json, as: UTF8.self))")
                count += 1
            }
        }
        print("GRADIENT_AUDIT_COUNT \(count)")
        #expect(count > 0)
    }

    /// 全flags先于payload；普通属性使用既有底层读取器，渐变stop由下述源码专用探针读取。
    func inspect(_ payload: GradientAuditPayload) throws -> [String: Any] {
        var reader = payload.reader
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
        let stroke = payload.code == 23
        let kinds: [AttributeEncoding] = stroke
            ? [.flag, .flag, .flag, .spatialProperty, .spatialProperty, .property, .property,
               .property, .flag, .flag, .property, .flag]
            : [.flag, .flag, .flag, .flag, .spatialProperty, .spatialProperty, .property, .property]
        let flags = try PropertyFlags.read(kinds, from: &reader)
        let valueCount = stroke ? 3 : 4
        var values: [UInt8] = []
        for flag in flags.prefix(valueCount) { values.append(try flag.exists ? reader.readUInt8() : 0) }
        let start = try decoder.readPointProperty(flags[valueCount], defaultValue: .zero, spatial: true, reader: &reader)
        let end = try decoder.readPointProperty(flags[valueCount + 1], defaultValue: ScenePoint(x: 100, y: 0),
                                               spatial: true, reader: &reader)
        let colors = try colorProperty(flags[valueCount + 2], decoder: &decoder, reader: &reader)
        let opacity = try decoder.readOpacityProperty(flags[valueCount + 3], reader: &reader)
        var result: [String: Any] = ["tag": Int(payload.code), "start": payload.range.lowerBound,
            "end": payload.range.upperBound, "values": values, "colors": colors.tables,
            "colorTimes": colors.times, "colorKinds": colors.kinds,
            "animatedFlags": flags.enumerated().filter { $0.element.isAnimated }.map(\.offset),
            "startPoint": [start.initialValue.x, start.initialValue.y],
            "endPoint": [end.initialValue.x, end.initialValue.y], "opacity": opacity.initialValue]
        if stroke {
            let width = try decoder.readScalarProperty(flags[7], defaultValue: 2, reader: &reader)
            let cap = try flags[8].exists ? reader.readUInt8() : 0
            let join = try flags[9].exists ? reader.readUInt8() : 0
            let miter = try decoder.readScalarProperty(flags[10], defaultValue: 4, reader: &reader)
            result["stroke"] = ["width": width.initialValue, "cap": Double(cap),
                                "join": Double(join), "miter": miter.initialValue]
            if flags[11].exists {
                // Dashes.cpp以三位存count-1；全部属性flags后才读offset和interval，不能按writer截成六项。
                reader.alignToByte()
                let count = Int(try reader.readUnsignedBits(count: 3)) + 1
                let dashFlags = try PropertyFlags.read(Array(repeating: .property, count: count + 1), from: &reader)
                var dashes: [Double] = []
                for index in dashFlags.indices {
                    dashes.append(try decoder.readScalarProperty(dashFlags[index], defaultValue: index == 0 ? 0 : 10,
                                                                 reader: &reader).initialValue)
                }
                result["dashes"] = dashes
            }
        }
        try StaticAttributes.requireEnd(of: reader)
        return result
    }

    /// GradientColorHandle为SimpleProperty，动画读n+1份stop表再读一维ease；此探针只记录表，不插值。
    private func colorProperty(_ flag: PropertyFlags, decoder: inout PAGSceneDecoder,
                               reader: inout PAGByteReader) throws
        -> (tables: [[String: Any]], times: [Int64], kinds: [UInt32]) {
        guard flag.exists else { return ([], [], []) }
        guard flag.isAnimated else { return ([try stops(reader: &reader)], [], []) }
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0, count < reader.remainingByteCount else { throw PAGError.invalidArgument("gradientAuditKeyframes") }
        try decoder.budget.reserve(count: count, stride: 256)
        var kinds: [UInt32] = []
        for _ in 0..<count { kinds.append(try reader.readUnsignedBits(count: 2)) }
        var times: [Int64] = []
        for _ in 0...count { times.append(try StaticAttributes.frame(from: &reader)) }
        var tables: [[String: Any]] = []
        for _ in 0...count { tables.append(try stops(reader: &reader)) }
        _ = try decoder.readEasings(header: KeyframeHeader(kinds: kinds, times: times), dimensions: 1, reader: &reader)
        return (tables, times, kinds)
    }

    /// ReadGradientColor先读alpha/color计数，再读各自UInt16位置/中点及字节值；保留编码顺序以调查重复位置。
    private func stops(reader: inout PAGByteReader) throws -> [String: Any] {
        let alphaCount = Int(try reader.readEncodedUInt32())
        let colorCount = Int(try reader.readEncodedUInt32())
        guard alphaCount <= reader.remainingByteCount / 5, colorCount <= reader.remainingByteCount / 7 else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        var alphas: [[Int]] = [], colors: [[Int]] = []
        for _ in 0..<alphaCount {
            alphas.append([Int(try reader.readUInt16()), Int(try reader.readUInt16()), Int(try reader.readUInt8())])
        }
        for _ in 0..<colorCount {
            colors.append([Int(try reader.readUInt16()), Int(try reader.readUInt16()),
                           Int(try reader.readUInt8()), Int(try reader.readUInt8()), Int(try reader.readUInt8())])
        }
        return ["alpha": alphas, "rgb": colors]
    }
}
