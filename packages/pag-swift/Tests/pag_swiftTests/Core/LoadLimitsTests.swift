import Testing
@testable import pag_swift

/// 验证资源限制的默认合同和配置错误，避免非正预算进入解码器。
struct LoadLimitsTests {
    /// 默认值应与公开初始化器一致，不能因静态快捷值与配置路径分开而漂移。
    @Test func standardLimitsMatchInitializer() throws {
        let limits = try PAGLoadLimits()
        #expect(limits == .standard)
        #expect(limits.maximumFileBytes == 268_435_456)
        #expect(limits.maximumDecodedBytes == 536_870_912)
        #expect(limits.maximumCompositionDepth == 64)
        #expect(limits.maximumLayerCount == 100_000)
    }

    /// 每项预算都拒绝零和负数，并指出具体出错的配置项。
    @Test(arguments: [0, -1, Int.min])
    func nonpositiveLimitsFail(_ value: Int) {
        #expect(throws: PAGError.invalidArgument("maximumFileBytes")) {
            try PAGLoadLimits(maximumFileBytes: value)
        }
        #expect(throws: PAGError.invalidArgument("maximumDecodedBytes")) {
            try PAGLoadLimits(maximumDecodedBytes: value)
        }
        #expect(throws: PAGError.invalidArgument("maximumCompositionDepth")) {
            try PAGLoadLimits(maximumCompositionDepth: value)
        }
        #expect(throws: PAGError.invalidArgument("maximumLayerCount")) {
            try PAGLoadLimits(maximumLayerCount: value)
        }
    }

    /// 上限只是策略值，初始化不得按大预算立即分配相应内存。
    @Test func positiveLimitsAreStoredWithoutAllocation() throws {
        let limits = try PAGLoadLimits(maximumFileBytes: .max, maximumLayerCount: 1)
        #expect(limits.maximumFileBytes == .max)
        #expect(limits.maximumLayerCount == 1)
    }
}
