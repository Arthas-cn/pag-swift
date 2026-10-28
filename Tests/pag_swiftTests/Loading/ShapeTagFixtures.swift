import Foundation
@testable import pag_swift

/// 沿真实PAG容器和静态形状组边界提取字段，供路径与描边共用；遇到动画组明确跳过。
enum ShapeTagFixtures {
    /// 按固定头/合成/图层/组的源码布局收集目标形状标签范围，并记录明确跳过的动画组数量。
    static func ranges(in data: Data, tag: UInt16) throws -> (payloads: [Range<Int>], skippedGroups: Int) {
        var body = PAGByteReader(data: data)
        try body.skip(byteCount: 9)
        var paths: [Range<Int>] = []
        var skipped = 0
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
                    try collect(code: code, target: tag, range: range, reader: payload, paths: &paths, skipped: &skipped)
                }
            }
        }
        return (paths, skipped)
    }

    /// 按ShapeGroup.cpp先消费所有flags再读取静态值；遇到动画整组跳过，绝不猜子tag起点。
    private static func collect(code: UInt16, target: UInt16, range: Range<Int>, reader: PAGByteReader,
                                paths: inout [Range<Int>], skipped: inout Int) throws {
        if code == target {
            paths.append(range)
            return
        }
        guard code == 15 else { return }
        var reader = reader
        let flags = try PropertyFlags.read([.flag, .spatialProperty, .spatialProperty, .property,
                                           .property, .property, .property, .property, .flag], from: &reader)
        if flags.contains(where: \.isAnimated) {
            skipped += 1
            return
        }
        for (flag, count) in zip(flags.dropLast(), [1, 8, 8, 8, 4, 4, 4, 1]) where flag.exists {
            try reader.skip(byteCount: count)
        }
        if flags[8].exists {
            while let (childCode, childRange, payload) = try block(from: &reader) {
                try collect(code: childCode, target: target, range: childRange, reader: payload, paths: &paths, skipped: &skipped)
            }
        }
        try StaticAttributes.requireEnd(of: reader)
    }

    /// 取得真实标签的独立子流；End要求当前容器恰好结束，不能通过扫描字节猜中标签。
    private static func block(from reader: inout PAGByteReader) throws -> (UInt16, Range<Int>, PAGByteReader)? {
        let header = try PAGTagHeader.read(from: &reader)
        if header.code == 0 {
            try StaticAttributes.requireEnd(of: reader)
            return nil
        }
        return (header.code, header.payloadRange, try reader.readSubreader(byteCount: header.payloadRange.count))
    }

}
