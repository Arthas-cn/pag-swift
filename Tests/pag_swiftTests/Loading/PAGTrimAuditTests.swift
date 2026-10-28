import Foundation
import Testing
@testable import pag_swift

/// 真实TrimPaths载荷及其绝对范围；只保存已由tag容器界定的子流，不搜索疑似字节。
struct TrimAuditPayload {
    /// 不包含tag header的文件内绝对范围。
    let range: Range<Int>
    /// 独立有界游标；消费不能越过此载荷进入下一标签。
    let reader: PAGByteReader
}

/// 取证得到的三条Float轨道与原始枚举值；不安装正式文档或渲染节点。
struct TrimAuditFields {
    /// 按源Float保存的start，未夹到0...1或除100。
    let start: TrimAuditProperty
    /// 缺省100是源兼容值，与显式1的语义不同。
    let end: TrimAuditProperty
    /// 源角度轨道，单位为度，读取阶段不取余。
    let offset: TrimAuditProperty
    /// Value原始字节；正常枚举0/1的支持另由正式读取器决定。
    let kind: UInt8
}

/// 独立探针保留的原始Float值和关键帧头，不调用生产标量属性读取或SourceProperty构造。
struct TrimAuditProperty {
    /// 常量恰好一项，动画为段数加一项，保持编码顺序。
    let values: [Double]
    /// 动画端点帧；常量为空，数量与values一致。
    let times: [Int64]
    /// 每段原始两位缓动类型，0/1线性、2Bezier、3Hold；常量为空。
    let kinds: [UInt32]
}

/// TrimPaths.cpp字段调查，完整消费每份真实载荷并报告轨道；不宣称完整PAG可播放。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_TRIM_AUDIT"] == "1",
                "设置PAG_TRIM_AUDIT=1调查真实TrimPaths字段"))
struct PAGTrimAuditTests {
    /// 遍历真实资源的已证实容器边界，记录初值、关键帧及原始枚举以选取独立回归夹具。
    @Test func recordsRealTrimFields() throws {
        let root = try PAGFixtures.rootURL().path + "/"
        var count = 0
        for url in try PAGFixtures.allPAGURLs() {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(Data(contentsOf: url))
            for payload in inspection.trimPayloads {
                let fields = try Self.inspect(payload)
                let properties = [fields.start, fields.end, fields.offset]
                let record: [String: Any] = [
                    "file": String(url.path.dropFirst(root.count)), "start": payload.range.lowerBound,
                    "end": payload.range.upperBound, "kind": fields.kind,
                    "initial": properties.map { $0.values[0] }, "segments": properties.map { $0.kinds.count },
                    "frames": properties.map { property in
                        property.kinds.indices.map { [property.times[$0], property.times[$0 + 1]] }
                    },
                    "values": properties.map { property in
                        property.kinds.indices.map { [property.values[$0], property.values[$0 + 1]] }
                    },
                    "kinds": properties.map(\.kinds)
                ]
                let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print("TRIM_AUDIT \(String(decoding: json, as: UTF8.self))")
                count += 1
            }
        }
        print("TRIM_AUDIT_COUNT \(count)")
        #expect(count > 0)
    }

    /// TrimPathsTag先保存全部flags，再依start/end/offset/type读取；defaultEnd=100不能修成1。
    static func inspect(_ payload: TrimAuditPayload) throws -> TrimAuditFields {
        var reader = payload.reader
        let flags = try PropertyFlags.read([.property, .property, .property, .flag], from: &reader)
        let start = try property(flags[0], defaultValue: 0, reader: &reader)
        let end = try property(flags[1], defaultValue: 100, reader: &reader)
        let offset = try property(flags[2], defaultValue: 0, reader: &reader)
        let kind = try flags[3].exists ? reader.readUInt8() : 0
        try StaticAttributes.requireEnd(of: reader)
        return TrimAuditFields(start: start, end: end, offset: offset, kind: kind)
    }

    /// 按AttributeHelper的段数、两位类型、n+1时间和值读取，独立消费一维ease避免以生产结果自证。
    private static func property(_ flag: PropertyFlags, defaultValue: Double,
                                 reader: inout PAGByteReader) throws -> TrimAuditProperty {
        guard flag.exists else { return TrimAuditProperty(values: [defaultValue], times: [], kinds: []) }
        guard flag.isAnimated else {
            return TrimAuditProperty(values: [Double(try reader.readFloat32())], times: [], kinds: [])
        }
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0, count < reader.remainingByteCount else {
            throw PAGError.invalidArgument("trimAuditKeyframes")
        }
        var kinds: [UInt32] = [], times: [Int64] = [], values: [Double] = []
        for _ in 0..<count { kinds.append(try reader.readUnsignedBits(count: 2)) }
        for _ in 0...count { times.append(Int64(bitPattern: try reader.readEncodedUInt64())) }
        for _ in 0...count { values.append(Double(try reader.readFloat32())) }
        // ReadTimeEase无论有没有Bezier都读bit width；SimpleProperty每段最多四个有符号控制分量。
        let width = try reader.readBitWidth()
        for kind in kinds where kind == 2 {
            for _ in 0..<4 { _ = try reader.readSignedBits(count: width) }
        }
        return TrimAuditProperty(values: values, times: times, kinds: kinds)
    }
}
