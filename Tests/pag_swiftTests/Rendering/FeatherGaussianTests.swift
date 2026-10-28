import Testing
@testable import pag_swift

/// TGFX分轴Gaussian的源Float核、滤镜分支与有界透明halo，供Metal效果准备复用。
struct FeatherGaussianTests {
    /// sigma=2的半径为4，半核双侧归一化；边界阶跃值与实际drawable金值一致。
    @Test func sigmaTwoUsesSymmetricNormalizedRadiusFour() throws {
        let axis = try #require(try FeatherGaussianAxis.make(2))
        #expect(axis.radius == 4 && axis.weights.count == 5)
        let total = axis.weights[0] + 2 * axis.weights.dropFirst().reduce(0, +)
        #expect(abs(total - 1) < 0.000_001)
        #expect(abs(axis.weights[0] - 0.204_164) < 0.000_01)
        #expect(abs(axis.weights[1] - 0.180_174) < 0.000_01)
    }

    /// 任一负轴或两轴全零使上游Blur工厂返回nil；单轴和双轴保留各自透明halo。
    @Test func filterSelectionAndHaloFollowTwoAxisValues() throws {
        #expect(try FeatherGaussianLayout.make(nil, width: 40, height: 30) == nil)
        #expect(try FeatherGaussianLayout.make(ScenePoint(x: -1, y: 4), width: 40, height: 30) == nil)
        #expect(try FeatherGaussianLayout.make(.zero, width: 40, height: 30) == nil)
        let one = try #require(try FeatherGaussianLayout.make(ScenePoint(x: 4, y: 0), width: 40, height: 30))
        #expect(one.horizontal?.radius == 4 && one.vertical == nil)
        #expect(one.width == 48 && one.height == 30 && one.haloX == 4 && one.haloY == 0)
        let two = try #require(try FeatherGaussianLayout.make(ScenePoint(x: 4, y: 6), width: 40, height: 30))
        #expect(two.horizontal?.radius == 4 && two.vertical?.radius == 6)
        #expect(two.width == 48 && two.height == 42 && two.haloX == 4 && two.haloY == 6)
    }

    /// sigma11钳到10，扩出22的84宽样本先按10/11缩小并roundOut成77宽；极大附件先失败。
    @Test func largeSigmaUsesRoundedLocalReductionBeforeGPU() throws {
        let large = try #require(try FeatherGaussianLayout.make(ScenePoint(x: 22, y: 0),
                                                                  width: 40, height: 30))
        let reduction = try #require(large.reduction)
        #expect(large.horizontal?.radius == 20 && large.vertical == nil)
        #expect(large.width == 84 && large.height == 30)
        #expect(reduction.width == 77 && reduction.height == 30)
        #expect(abs(reduction.scaleX - Float(77.0 / 84.0)) < 0.000_001)
        #expect(reduction.scaleY == 1)
        #expect(reduction.sampleLeft == -22 && reduction.sampleTop == 0)
        #expect(throws: PAGError.resourceLimitExceeded("featherMaskDimensions")) {
            try FeatherGaussianLayout.make(ScenePoint(x: 20, y: 20), width: 16_380, height: 16_380)
        }
        #expect(throws: PAGError.resourceLimitExceeded("featherMaskDimensions")) {
            try FeatherGaussianLayout.make(ScenePoint(x: 10_000_000_000, y: 0),
                                           width: 40, height: 30)
        }
        #expect(throws: PAGError.resourceLimitExceeded("featherMaskDimensions")) {
            try FeatherGaussianLayout.make(ScenePoint(x: 4, y: 0), width: Int.max, height: 30)
        }
    }

    /// 负起点把可见输出clip左边推到源x=10，样本左边变为-12；实际倍率按104而非完整114宽重算。
    @Test func negativeOriginClipsSampleBeforeReduction() throws {
        let layout = try #require(try FeatherGaussianLayout.make(ScenePoint(x: 22, y: 0),
            width: 70, height: 100,
            clip: FeatherGaussianClip(originX: -10, originY: 0, width: 72, height: 120)))
        let reduction = try #require(layout.reduction)
        #expect(layout.width == 114 && layout.haloX == 22)
        #expect(reduction.sampleLeft == -12 && reduction.sampleTop == 0)
        #expect(reduction.width == 95 && reduction.height == 100)
        #expect(abs(reduction.scaleX - Float(95.0 / 104.0)) < 0.000_001)
        #expect(reduction.scaleY == 1)
    }

    /// 分数负起点先把可见clip向外取整，再外扩两轴羽化；不能把分数起点直接取整当样本左上角。
    @Test func fractionalNegativeClipRoundsBeforeTwoAxisSample() throws {
        let layout = try #require(try FeatherGaussianLayout.make(ScenePoint(x: 22, y: 26),
            width: 70, height: 70,
            clip: FeatherGaussianClip(originX: -9.75, originY: -5.25, width: 72, height: 72)))
        let reduction = try #require(layout.reduction)
        #expect(reduction.sampleLeft == -13 && reduction.sampleTop == -21)
        #expect(reduction.width == 96 && reduction.height == 91)
        #expect(abs(reduction.scaleX - Float(96.0 / 105.0)) < 0.000_001)
        #expect(abs(reduction.scaleY - Float(91.0 / 117.0)) < 0.000_001)
    }
}
