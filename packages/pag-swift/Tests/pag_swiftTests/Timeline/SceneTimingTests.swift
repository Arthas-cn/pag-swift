import Testing
@testable import pag_swift

/// 根量化、层内容时间及预合成帧率映射；语义图测试不声称存在对应字节夹具。
struct SceneTimingTests {
    /// 30 fps 的请求保留原始钳制微秒，显示时刻则为所选帧的 ceil 代表时间。
    @Test(arguments: [
        (Int64(-1), Int64(0), Int64(0), Int64(0)),
        (33_333, 33_333, 0, 0), (33_334, 33_334, 1, 33_334),
        (999_999, 999_999, 29, 966_667), (.max, 999_999, 29, 966_667)
    ])
    func rootQuantizesOnce(_ input: Int64, _ requested: Int64, _ frame: Int64, _ represented: Int64) throws {
        let source = try SceneFixtures.composition(1, layers: [])
        let file = try SceneFixtures.build([source])
        let sample = try SceneTiming.root(at: PAGTime(microseconds: input), in: file.storage)
        #expect(sample == RootSampleTime(requestedTime: PAGTime(microseconds: requested), frame: frame,
                                        representedTime: PAGTime(microseconds: represented)))
    }

    /// 图层可见起点允许为负，右端不可见；内容微秒从该层起点重新计数。
    @Test func negativeStartAndOpenEnd() throws {
        let layer = SceneFixtures.layer(1, start: -5, duration: 10)
        #expect(try SceneTiming.layer(layer, at: .min, frameRate: 30) == nil)
        #expect(try SceneTiming.layer(layer, at: -6, frameRate: 30) == nil)
        #expect(try SceneTiming.layer(layer, at: -5, frameRate: 30) == LayerSampleTime(contentFrame: 0, contentTime: .zero))
        #expect(try SceneTiming.layer(layer, at: 0, frameRate: 30) == LayerSampleTime(
            contentFrame: 5, contentTime: PAGTime(microseconds: 166_667)))
        #expect(try SceneTiming.layer(layer, at: 4, frameRate: 30)?.contentFrame == 9)
        #expect(try SceneTiming.layer(layer, at: 5, frameRate: 30) == nil)
        #expect(try SceneTiming.layer(layer, at: .max, frameRate: 30) == nil)
    }

    /// 30→60 fps 倍频与 30→15 fps 的 half-away 舍入遵循源公式，不一律 floor。
    @Test func precompositionUsesSourceRatesAndRounding() throws {
        let doubleRate = try SceneFixtures.composition(1, layers: [], rate: 60)
        #expect(try SceneTiming.precomposition(at: 14, startFrame: 4, parentRate: 30, child: doubleRate) == 20)
        let halfRate = try SceneFixtures.composition(1, layers: [], rate: 15)
        #expect(try SceneTiming.precomposition(at: 1, startFrame: 0, parentRate: 30, child: halfRate) == 1)
        #expect(try SceneTiming.precomposition(at: 3, startFrame: 0, parentRate: 30, child: halfRate) == 2)
        #expect(try SceneTiming.precomposition(at: 2, startFrame: 0, parentRate: 30, child: halfRate) == 1)
    }

    /// 子合成范围外保持首末帧；compositionStart 与层的可见起点不能混用或重复扣除。
    @Test func childClampsIndependentlyOfLayerVisibleRange() throws {
        let child = try SceneFixtures.composition(1, layers: [])
        let layer = SceneFixtures.layer(9, start: 20, duration: 90, content: .precomposition(id: 1, startFrame: 10))
        #expect(try SceneTiming.layer(layer, at: 20, frameRate: 30)?.contentFrame == 0)
        #expect(try SceneTiming.precomposition(at: 20, startFrame: 10, parentRate: 30, child: child) == 10)
        #expect(try SceneTiming.precomposition(at: 5, startFrame: 10, parentRate: 30, child: child) == 0)
        #expect(try SceneTiming.precomposition(at: 109, startFrame: 10, parentRate: 30, child: child) == 29)
    }

    /// 上游 100000μs、30fps、偏移一帧的例子应到子帧 2，不能因 ceil 微秒偏移退到帧 1。
    @Test func integerFrameOffsetAvoidsMicrosecondDoubleQuantization() throws {
        let child = try SceneFixtures.composition(1, layers: [])
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(2, content: .precomposition(id: 1, startFrame: 1))
        ])
        let file = try SceneFixtures.build([child, root])
        let request = try SceneTiming.root(at: PAGTime(microseconds: 100_000), in: file.storage)
        #expect(request.frame == 3)
        #expect(try SceneTiming.precomposition(at: request.frame, startFrame: 1, parentRate: 30, child: child) == 2)
    }

    /// 编辑合成只改变覆盖表，相同请求在旧值和新值上保持相同根帧与代表微秒。
    @Test func editsDoNotChangeSampleClock() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "replacement.pag"))
        var edited = file.composition
        let layer = try #require(edited.layers.first)
        try edited.setVisibility(false, for: layer.id)
        for microseconds: Int64 in [0, 500_000, 1_000_000, .max] {
            let time = PAGTime(microseconds: microseconds)
            #expect(try SceneTiming.root(at: time, in: file.storage) == SceneTiming.root(at: time, in: edited.storage))
        }
    }

    /// 减法、Float 比值和整数转换溢出都失败，不能靠钳到首末帧吞掉无效时基。
    @Test func unrepresentableCompositionTimeFails() throws {
        let child = try SceneFixtures.composition(1, layers: [])
        #expect(throws: SceneValidator.invalid("unrepresentableCompositionTime")) {
            try SceneTiming.precomposition(at: .max, startFrame: .min, parentRate: 30, child: child)
        }
        #expect(throws: SceneValidator.invalid("unrepresentableCompositionTime")) {
            try SceneTiming.precomposition(at: .max, startFrame: 0, parentRate: 1, child: child)
        }
        for rate in [Double.zero, .nan, .infinity, Double(Float.leastNonzeroMagnitude)] {
            #expect(throws: SceneValidator.invalid("unrepresentableCompositionTime")) {
                try SceneTiming.precomposition(at: 1, startFrame: 0, parentRate: rate, child: child)
            }
        }
    }
}
