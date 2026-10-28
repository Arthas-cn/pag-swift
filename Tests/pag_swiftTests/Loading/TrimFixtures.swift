import Foundation
@testable import pag_swift

/// Trim字段测试的独立游标与预算；真实载荷来自已证实范围，缺省边界仅构造属性子流。
enum TrimFixtures {
    /// 创建互不共享消费状态的内部读取器；不通过正式PAG载入绕过支持门禁。
    static func decoder(limit: Int = 64 * 1024 * 1024) -> PAGSceneDecoder {
        PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: limit))
    }

    /// 完整读取一份有界属性载荷，返回源模型及保守逻辑成本；错误与取消原样传播。
    static func read(_ data: Data, limit: Int = 64 * 1024 * 1024) throws
        -> (source: SourceTrimPaths, cost: Int) {
        var decoder = decoder(limit: limit)
        var reader = PAGByteReader(data: data)
        let source = try decoder.readTrimPaths(reader: &reader)
        return (source, decoder.budget.used)
    }

    /// 按固定真实tag边界提取载荷；这里没有文件头、容器或合法PAG拼接器。
    static func data(_ name: String, range: Range<Int>) throws -> Data {
        try PAGFixtures.data(named: name).subdata(in: range)
    }

    /// 只编码TrimPathsTag已证实的三个常量Float属性子流，验证有限宽范围，不将它当完整PAG。
    static func constants(start: Float, end: Float, offset: Float, mode: UInt8) -> Data {
        // ReadAttributeFlag低位优先：三个exists/非animated加mode存在，共七位为0x55。
        var data = Data([0x55])
        for value in [start, end, offset] {
            data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) })
        }
        data.append(mode)
        return data
    }
}
