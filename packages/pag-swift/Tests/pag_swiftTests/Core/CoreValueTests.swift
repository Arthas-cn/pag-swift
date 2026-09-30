import Testing
@testable import pag_swift

/// 验证公开基础值的合法范围，确保非法输入不会进入时间或渲染计算。
struct CoreValueTests {
    /// 微秒保留 Int64 全范围，比较不能靠相减造成溢出。
    @Test func timesPreserveSignedMicroseconds() {
        let first = PAGTime(microseconds: .min)
        let last = PAGTime(microseconds: .max)
        #expect(first.microseconds == Int64.min)
        #expect(last.microseconds == Int64.max)
        #expect(first < .zero)
        #expect(PAGTime.zero < last)
        #expect(first < last)
    }

    /// 进度拒绝非有限和越界输入，不沿用上游超界取余的行为。
    @Test(arguments: [Double.nan, .infinity, -.infinity, -0.001, 1.001])
    func progressRejectsInvalidValues(_ value: Double) {
        #expect(throws: PAGError.invalidArgument("progress")) {
            try PAGProgress(value)
        }
    }

    /// 合法比例包含两个端点，固定端点与经过校验的同值实例相等。
    @Test func progressIncludesBothEndpoints() throws {
        #expect(try PAGProgress(0) == .start)
        #expect(try PAGProgress(1) == .end)
        #expect(try PAGProgress(0.375).value == 0.375)
    }

    /// 零、负数及非有限尺寸不能伪装成合法显示矩形。
    @Test(arguments: [0.0, -1, .nan, .infinity, -.infinity])
    func sizeRejectsInvalidDimensions(_ value: Double) {
        #expect(throws: PAGError.invalidArgument("width")) {
            try PAGSize(width: value, height: 1)
        }
        #expect(throws: PAGError.invalidArgument("height")) {
            try PAGSize(width: 1, height: value)
        }
    }

    /// 颜色校验每个通道，不把越界值隐式截成看似有效的颜色。
    @Test(arguments: [-0.1, 1.1, Double.nan, .infinity])
    func colorsRejectInvalidComponents(_ value: Double) {
        #expect(throws: PAGError.invalidArgument("red")) {
            try PAGColor(red: value, green: 0, blue: 0)
        }
        #expect(throws: PAGError.invalidArgument("green")) {
            try PAGColor(red: 0, green: value, blue: 0)
        }
        #expect(throws: PAGError.invalidArgument("blue")) {
            try PAGColor(red: 0, green: 0, blue: value)
        }
        #expect(throws: PAGError.invalidArgument("alpha")) {
            try PAGColor(red: 0, green: 0, blue: 0, alpha: value)
        }
    }

    /// 颜色保存非预乘通道；零 alpha 不改变 RGB，默认 alpha 为一。
    @Test func colorsRemainUnpremultiplied() throws {
        let clearRed = try PAGColor(red: 1, green: 0, blue: 0, alpha: 0)
        #expect(clearRed.red == 1)
        #expect(clearRed.alpha == 0)
        #expect(try PAGColor(red: 0.2, green: 0.3, blue: 0.4).alpha == 1)
    }

    /// 所有基础值都可跨隔离传递；普通泛型 Sendable 约束不能被 UI 默认隔离替代。
    @Test func coreValuesAreSendable() throws {
        requireSendable(PAGTime.zero)
        requireSendable(PAGProgress.end)
        requireSendable(try PAGSize(width: 1, height: 1))
        requireSendable(try PAGColor(red: 1, green: 0, blue: 0))
        requireSendable(PAGLoadLimits.standard)
        requireSendable(PAGScaleMode.aspectFit)
        requireSendable(PAGError.sourceChanged)
        #expect(PAGTime.zero.microseconds == 0)
    }

    /// 在编译期约束公开值为 Sendable，不执行额外运行时工作。
    private func requireSendable<Value: Sendable>(_ value: Value) {}
}
