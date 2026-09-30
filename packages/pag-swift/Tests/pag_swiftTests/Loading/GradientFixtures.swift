import Foundation
@testable import pag_swift

/// 渐变内部读取测试的真实载荷入口；边界来自容器调查，不合成可播放PAG。
enum GradientFixtures {
    /// 每次建立独立的非隔离解码器，预算不在测试之间共享。
    static func decoder(limit: Int = 64 * 1024 * 1024) -> PAGSceneDecoder {
        PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: limit))
    }

    /// 读取已核对范围的真实Fill，并要求整个payload消费完毕。
    static func fill(_ name: String = "list/1.pag", range: Range<Int> = 159..<210) throws -> SourceGradientFill {
        var decoder = decoder()
        var reader = try PAGByteReader(data: PAGFixtures.data(named: name).subdata(in: range))
        return try decoder.readGradientFill(reader: &reader)
    }

    /// 读取已核对范围的真实Stroke；失败保持生产错误。
    static func stroke(_ name: String = "TextAnimatorMode.pag", range: Range<Int> = 326..<359) throws -> SourceGradientStroke {
        var decoder = decoder()
        var reader = try PAGByteReader(data: PAGFixtures.data(named: name).subdata(in: range))
        return try decoder.readGradientStroke(reader: &reader)
    }

    /// 内部边界测试共用的分发，返回完整读取后的预算；其他tag属于测试调用错误。
    static func read(_ tag: UInt16, data: Data, limit: Int = 64 * 1024 * 1024) throws -> Int {
        var decoder = decoder(limit: limit)
        var reader = PAGByteReader(data: data)
        switch tag {
        case 22: _ = try decoder.readGradientFill(reader: &reader)
        case 23: _ = try decoder.readGradientStroke(reader: &reader)
        default: throw PAGError.invalidArgument("gradientTestTag")
        }
        return decoder.budget.used
    }

    /// 只读GradientColor字段并验证无尾随；返回原表和累计预算，供排序/预算断言。
    static func colors(_ data: Data, limit: Int = 64 * 1024 * 1024) throws -> (SourceGradientColors, Int) {
        var decoder = decoder(limit: limit)
        var reader = PAGByteReader(data: data)
        let value = try decoder.readGradientColors(reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return (value, decoder.budget.used)
    }
}
