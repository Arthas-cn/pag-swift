import Testing
@testable import pag_swift

/// Repeater复制份数、顺序、末份透明度和预算的纯值求值回归。
struct RepeaterSamplingTests {
    /// 负份数保留此前组，零份数清组；这两支不读取后续变换轨道。
    @Test func nonpositiveCopiesKeepOrClearPreviousGroup() throws {
        var budget = FramePlanBudget(limit: 1024)
        guard case .unchanged = try RepeaterSampling.select(source(copies: -1), at: 0, budget: &budget) else {
            Issue.record("负份数应保留原组")
            return
        }
        guard case .cleared = try RepeaterSampling.select(source(copies: 0), at: 0, budget: &budget) else {
            Issue.record("零份数应清空原组")
            return
        }
    }

    /// 2.5份形成三个克隆，末份只保留一半alpha；Above把源序号反向排列。
    @Test func fractionalLastCopyAndAboveOrder() throws {
        var budget = FramePlanBudget(limit: 4096)
        guard case .copies(let below) = try RepeaterSampling.select(source(copies: 2.5), at: 0, budget: &budget),
              case .copies(let above) = try RepeaterSampling.select(source(copies: 2.5, order: .above),
                                                                    at: 0, budget: &budget) else {
            Issue.record("正份数应返回复制列表")
            return
        }
        #expect(below.map(\.sourceIndex) == [0, 1, 2])
        #expect(above.map(\.sourceIndex) == [2, 1, 0])
        #expect(below.map(\.opacity) == [1, 1, 0.5])
    }

    /// 第二份围绕锚点旋转后，再按progress施加位移；透明度按UInt8插值截断。
    @Test func anchorRotationAndOpacityOrder() throws {
        let value = SourceRepeater(order: .below, copies: SourceProperty(constant: 2),
            offset: SourceProperty(constant: 0), anchor: SourceProperty(constant: ScenePoint(x: 0, y: 10)),
            position: SourceProperty(constant: ScenePoint(x: 5, y: 0)), scale: SourceProperty(constant: .one),
            rotation: SourceProperty(constant: 90), startOpacity: SourceProperty(constant: 0),
            endOpacity: SourceProperty(constant: 255))
        var budget = FramePlanBudget(limit: 4096)
        guard case .copies(let copies) = try RepeaterSampling.select(value, at: 0, budget: &budget) else {
            Issue.record("应形成两份复制")
            return
        }
        let mapped = try copies[1].matrix.applying(to: ScenePoint(x: 0, y: 10))
        #expect(abs(mapped.x - 5) < 0.0001 && abs(mapped.y - 10) < 0.0001)
        #expect(copies[0].opacity == 0)
        #expect(copies[1].opacity == Double(Float(127) / 255))
    }

    /// 巨大份数必须在数组分配前按当前帧剩余额度失败。
    @Test func copyCountReservesBeforeAllocation() throws {
        var budget = FramePlanBudget(limit: 512)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try RepeaterSampling.select(source(copies: 1000), at: 0, budget: &budget)
        }
    }

    /// 用缺省变换构造语义源值，避免把测试数据伪装成合法PAG字节。
    private func source(copies: Double, order: SourceRepeaterOrder = .below) -> SourceRepeater {
        SourceRepeater(order: order, copies: SourceProperty(constant: copies),
            offset: SourceProperty(constant: 0), anchor: SourceProperty(constant: .zero),
            position: SourceProperty(constant: .zero), scale: SourceProperty(constant: .one),
            rotation: SourceProperty(constant: 0), startOpacity: SourceProperty(constant: 255),
            endOpacity: SourceProperty(constant: 255))
    }
}
