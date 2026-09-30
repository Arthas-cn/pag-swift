import Testing
@testable import pag_swift

/// TGFX解析分支与独立系数金值；这里只验证颜色程序，布局与drawable另行验收。
struct GradientColorizerTests {
    /// 两色保持Single算式，透明红仍参与RGB插值；t=.5预乘前后分别为紫.5与紫.25。
    @Test func transparentRedBlueUsesStraightAlphaInterpolation() throws {
        let value = try GradientColorFixtures.compile(.init(
            alphaStops: [.init(position: 0, midpoint: 0.5, opacity: 0), .init(position: 1, midpoint: 0.5, opacity: 255)],
            colorStops: [.init(position: 0, midpoint: 0.5, color: GradientColorFixtures.red),
                         .init(position: 1, midpoint: 0.5, color: GradientColorFixtures.blue)]))
        guard case .analytic(.single) = value.result else { Issue.record("两色应为Single"); return }
        let sampled = try GradientColorFixtures.sample(value, at: 0.5)
        #expect(sampled == SIMD4<Float>(0.5, 0, 0.5, 0.5))
        #expect(SIMD4(sampled.x * sampled.w, sampled.y * sampled.w, sampled.z * sampled.w, sampled.w)
                == SIMD4<Float>(0.25, 0, 0.25, 0.5))
    }

    /// 非对称中点经字节合并再编译Dual；独立Float位模式锁定减、除、乘次序。
    @Test func midpointDualCoefficientsMatchIndependentFloatGoldens() throws {
        let value = try GradientColorFixtures.compile(GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)], colorMidpoint: 0.25))
        let rows = try intervals(value)
        try #require(rows.count == 2)
        #expect(rows.map(\.upperBound) == [0.25, 1])
        #expect(bits(rows[0].scale) == [0xc0008080, 0, 0x3ffefeff, 0x3f7cfcfd])
        #expect(bits(rows[0].bias) == [0x3f800000, 0, 0, 0])
        #expect(bits(rows[1].scale) == [0xbf29ff55, 0, 0x3f2b5600, 0x3f808081])
        #expect(bits(rows[1].bias) == [0x3f29ff55, 0, 0x3ea953ff, 0xbb8080a0])
        #expect(try bits(GradientColorFixtures.sample(value, at: 0.5)) == [0x3ea9ff55, 0, 0x3f2a5500, 0x3efeff00])
    }

    /// 三色阈值等号选右段；四色near使用较早阈值，不把近而不等的间距重新拉伸。
    @Test func dualThresholdAndNearHardStopUseRightSide() throws {
        let tri = try GradientColorFixtures.compile(GradientColorFixtures.colors(rgb: [
            (0, GradientColorFixtures.red), (0.25, GradientColorFixtures.green), (1, GradientColorFixtures.blue)]))
        #expect(try GradientColorFixtures.sample(tri, at: 0.25) == SIMD4<Float>(0, 1, 0, 1))
        #expect(try GradientColorFixtures.sample(tri, at: 0.625) == SIMD4<Float>(0, 0.5, 0.5, 1))
        let four = try GradientColorFixtures.compile(GradientColorFixtures.colors(rgb: [
            (0, GradientColorFixtures.red), (0.5, GradientColorFixtures.green),
            (Float(25001) * 0.00002, GradientColorFixtures.blue), (1, SceneColor(red: 255, green: 255, blue: 255))]))
        #expect(try intervals(four).map(\.upperBound) == [0.5, 1])
        #expect(try GradientColorFixtures.sample(four, at: 0.5) == SIMD4<Float>(0, 0, 1, 1))
        #expect(try GradientColorFixtures.sample(four, at: 0.75) == SIMD4<Float>(0.5, 0.5, 1, 1))
        #expect(try GradientColorFixtures.sample(four, at: Float(0.5).nextDown).y > 0.99)
    }

    /// 交错表形成四个Unrolled区间；各段alpha系数的不同ulp不能被平均化。
    @Test func staggeredUnrolledCoefficientsKeepByteQuantization() throws {
        let source = GradientColorFixtures.colors(rgb: [(0.25, GradientColorFixtures.red), (0.75, GradientColorFixtures.green)],
                                                  alpha: [(0, 0), (0.5, 128), (1, 255)])
        let rows = try intervals(GradientColorFixtures.compile(source))
        #expect(rows.map(\.upperBound) == [0.25, 0.5, 0.75, 1])
        #expect(rows.map { $0.scale.w.bitPattern } == [0x3f808081, 0x3f808081, 0x3f7cfcfc, 0x3f808080])
        #expect(rows.map { $0.bias.w.bitPattern } == [0, 0, 0x3c0080c0, 0xbb808000])
    }

    /// 两端hardstop同时基于未剥除列表识别，边色仍保留原首末RGBA，解析程序只取中间两色。
    @Test func bothEndpointHardStopsKeepOriginalBorders() throws {
        let value = try GradientColorFixtures.compile(GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)],
                                                                                  colorMidpoint: 0, alphaMidpoint: 1))
        guard case .analytic(.single(let first, let last)) = value.result else { Issue.record("应剥为Single"); return }
        #expect(first == SIMD4<Float>(127, 0, 127, 0) / 255 && last == SIMD4<Float>(0, 0, 255, 127) / 255)
        #expect(value.first == SIMD4<Float>(1, 0, 0, 0) && value.last == SIMD4<Float>(0, 0, 1, 1))
        #expect(try GradientColorFixtures.sample(value, at: 0) == value.first)
        #expect(try GradientColorFixtures.sample(value, at: 1) == value.last)
    }

    /// near阈值是固定绝对1/4096且包含等号，临界内剥首色，临界外保留Dual。
    @Test(arguments: [Float(12) * 0.00002, Float(13) * 0.00002, Float(1) / 4096, (Float(1) / 4096).nextUp])
    func nearBoundarySelectsSourceBranch(_ middle: Float) throws {
        let value = try GradientColorFixtures.compile(GradientColorFixtures.colors(rgb: [
            (0, GradientColorFixtures.red), (middle, GradientColorFixtures.green), (1, GradientColorFixtures.blue)]))
        if middle <= 1 / 4096 {
            guard case .analytic(.single(let first, _)) = value.result else { Issue.record("near应剥首色"); return }
            #expect(first == SIMD4<Float>(0, 1, 0, 1))
        } else { #expect(try intervals(value).count == 2) }
        #expect(value.first == SIMD4<Float>(1, 0, 0, 1))
    }

    /// 八段后还有零宽区间时先命中容量拒绝；超过16色不偷偷生成LUT，拒绝状态仍保留边色。
    @Test func intervalCapacityPrecedesZeroWidthSkip() throws {
        let codes = stride(from: 0, through: 50000, by: 6250).map { Float($0) * 0.00002 }
        let source = GradientColorFixtures.colors(rgb: codes.map { ($0, GradientColorFixtures.red) })
        #expect(try intervals(GradientColorFixtures.compile(source)).count == 8)
        for positions in [codes + [Float(55000) * 0.00002], (0...16).map { Float($0) / 16 }] {
            let value = try GradientColorFixtures.compile(GradientColorFixtures.colors(rgb: positions.map { ($0, GradientColorFixtures.red) }))
            guard case .requiresTexture = value.result else { Issue.record("容量分支必须记录requiresTexture"); return }
            #expect(value.first == SIMD4<Float>(1, 0, 0, 1) && value.last == value.first)
        }
    }

    /// 超出1规范化后的Dual除零、Unrolled不足八段的未定义尾部都记录失败，不能外推末段。
    @Test func nonfiniteAndUndefinedTailAreDeferredStates() throws {
        let beyond = [Float(55000) * 0.00002, Float(60000) * 0.00002]
        let first = GradientColorFixtures.colors(rgb: [(beyond[0], GradientColorFixtures.red), (beyond[1], GradientColorFixtures.blue)],
                                                 alpha: beyond.map { ($0, 255) })
        let positions = [0, 1, 2, 49998, 49999, 50000].map { Float($0) * 0.00002 }
        let second = GradientColorFixtures.colors(rgb: positions.map { ($0, GradientColorFixtures.red) })
        for source in [first, second] {
            let value = try GradientColorFixtures.compile(source)
            guard case .invalidPrecision = value.result else { Issue.record("应记录invalidPrecision"); return }
            #expect(value.first == SIMD4<Float>(1, 0, 0, 1))
        }
    }

    /// 只有原合并项数为一才走singleColor，不能因所有颜色相同跳过正常解析容量或矩阵语义。
    @Test func oneMergedStopIsTheOnlySolidShortcut() throws {
        let value = try GradientColorFixtures.compile(GradientColorFixtures.colors(
            rgb: [(0.5, GradientColorFixtures.red)], alpha: [(0.5, 0)]))
        guard case .singleColor = value.result else { Issue.record("单合并色应为singleColor"); return }
        #expect(value.first == SIMD4<Float>(1, 0, 0, 0) && value.last == value.first)
    }

    /// 返回解析区间作为系数断言的前置条件；分支不符时测试明确失败而不是数组越界。
    private func intervals(_ value: PreparedGradientColorizer) throws -> [GradientColorInterval] {
        guard case .analytic(.intervals(let result)) = value.result else {
            Issue.record("期望解析区间程序")
            throw PAGError.invalidArgument("gradientTestProgram")
        }
        return result
    }

    /// 将四个Float通道转换为独立金值使用的IEEE754位模式，不容忍算序被Double重排。
    private func bits(_ value: SIMD4<Float>) -> [UInt32] {
        [value.x.bitPattern, value.y.bitPattern, value.z.bitPattern, value.w.bitPattern]
    }
}
