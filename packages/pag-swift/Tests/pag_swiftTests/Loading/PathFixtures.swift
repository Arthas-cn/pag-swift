import Foundation
@testable import pag_swift

/// 从真实容器边界取得路径片段；只下降静态形状组，不把未读取的动画组称为完整遍历。
enum PathFixtures {
    /// 沿共用容器枚举器只选择tag19，不改变原路径调查范围或跳过计数。
    static func ranges(in data: Data) throws -> (paths: [Range<Int>], skippedGroups: Int) {
        let result = try ShapeTagFixtures.ranges(in: data, tag: 19)
        return (result.payloads, result.skippedGroups)
    }

    /// 对一份真实字段执行内部完整读取；数据已限制在tag载荷内，适合损坏边界测试。
    static func decode(_ data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> SourceProperty<SourcePath> {
        var reader = PAGByteReader(data: data)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
        return try decoder.readShapePath(reader: &reader)
    }

    /// 读取指定真实源文件范围，不写入或生成自称合法的PAG容器。
    static func property(named name: String, range: Range<Int>) throws -> SourceProperty<SourcePath> {
        try decode(PAGFixtures.data(named: name).subdata(in: range))
    }
}
