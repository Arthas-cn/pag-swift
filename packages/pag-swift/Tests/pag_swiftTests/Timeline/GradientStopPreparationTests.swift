import Testing
@testable import pag_swift

/// 源中点与双表合并的独立字节金值；期望先手算通道，再验证Float数值域。
struct GradientStopPreparationTests {
    /// RGB中点.25插入127紫色，alpha在此处255*.25截为63，不能推迟到片元再量化。
    @Test func midpointIsQuantizedBeforeAlphaMerge() throws {
        let source = GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)], colorMidpoint: 0.25)
        let stops = try merge(source)
        #expect(stops.map(\.position) == [0, 0.25, 1])
        #expect(stops.map(\.color) == [SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(127, 0, 127, 63) / 255,
                                      SIMD4<Float>(0, 0, 1, 1)])
    }

    /// 两表交错时插值另一表并保持首末常值，.5的RGB127与.75的alpha191均来自截断。
    @Test func staggeredTablesKeepEdgesAndByteTruncation() throws {
        let source = GradientColorFixtures.colors(rgb: [(0.25, GradientColorFixtures.red), (0.75, GradientColorFixtures.green)],
                                                 alpha: [(0, 0), (0.5, 128), (1, 255)])
        let stops = try merge(source)
        #expect(stops.map(\.position) == [0, 0.25, 0.5, 0.75, 1])
        #expect(stops.map(\.color) == [SIMD4(255, 0, 0, 0), SIMD4(255, 0, 0, 64),
            SIMD4(127, 127, 0, 128), SIMD4(0, 255, 0, 191), SIMD4(0, 255, 0, 255)].map { $0 / Float(255) })
    }

    /// midpoint0/1展开产生的重复位置必须原序保留，末项中点不额外插入颜色。
    @Test func endpointMidpointsKeepHardStops() throws {
        let source = GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)], colorMidpoint: 0, alphaMidpoint: 1)
        let stops = try merge(source)
        #expect(stops.map(\.position) == [0, 0, 1, 1])
        #expect(stops.map(\.color) == [SIMD4(255, 0, 0, 0), SIMD4(127, 0, 127, 0),
                                     SIMD4(0, 0, 255, 127), SIMD4(0, 0, 255, 255)].map { $0 / Float(255) })
        let single = GradientColorFixtures.colors(rgb: [(0.5, GradientColorFixtures.red)], alpha: [(0.5, 42)],
                                                  colorMidpoint: 0, alphaMidpoint: 1)
        #expect(try merge(single).count == 1)
    }

    /// midpoint1仍执行源Float算式；独立编码金值证明展开点可比下一原点大一ULP，不能赋值或排序修正。
    @Test func midpointRoundingKeepsSourceOrder() throws {
        let first = Float(19234) * 0.00002, last = Float(47727) * 0.00002
        let source = GradientColorFixtures.colors(rgb: [(first, GradientColorFixtures.red), (last, GradientColorFixtures.blue)],
            alpha: [(0, 255)], colorMidpoint: 1)
        let stops = try merge(source)
        #expect(stops.map { $0.position.bitPattern } == [0, 0x3ec4f4c7, 0x3f745cbc, 0x3f745cbb])
        #expect(stops[2].color == SIMD4<Float>(127, 0, 127, 255) / 255)
    }

    /// 两表耗尽顺序均保留另一表末色/末alpha；未预乘RGB即使alpha为零也不可丢失。
    @Test func tableTailsUseFinalValues() throws {
        let first = GradientColorFixtures.colors(rgb: [(0, GradientColorFixtures.red), (1, GradientColorFixtures.blue)],
                                                 alpha: [(0.25, 0)])
        #expect(try merge(first).last?.color == SIMD4<Float>(0, 0, 1, 0))
        let second = GradientColorFixtures.colors(rgb: [(0.25, GradientColorFixtures.red)], alpha: [(0, 0), (1, 255)])
        #expect(try merge(second).last?.color == SIMD4<Float>(1, 0, 0, 1))
    }

    /// 每次编译使用独立预算，避免金值测试受到并行用例的计费状态影响。
    private func merge(_ source: SourceGradientColors) throws -> [GradientStop] {
        var budget = FramePlanBudget(limit: 1_000_000)
        return try GradientStopPreparation.merge(source, budget: &budget)
    }
}
