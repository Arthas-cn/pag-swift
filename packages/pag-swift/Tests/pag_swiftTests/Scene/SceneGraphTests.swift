import Testing
@testable import pag_swift

/// 源 DAG、公开实例路径、时间基以及资源验证，不依赖未证实的二进制构造。
struct SceneGraphTests {
    /// 多次引用同一源合成保留共享源记录，却产生不同路径身份与正确公开顺序。
    @Test func sharedCompositionHasDistinctInstances() throws {
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(10), SceneFixtures.layer(11)])
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0))
        ])
        let file = try SceneFixtures.build([child, root])
        let layers = file.composition.layers
        #expect(layers.map { $0.id.path } == [[21], [20]])
        #expect(layers[0].children.map { $0.id.path } == [[21, 11], [21, 10]])
        #expect(layers[1].children.map { $0.id.path } == [[20, 11], [20, 10]])
        #expect(file.composition.layers(named: "shared").map { $0.id.path } ==
                [[21], [21, 11], [21, 10], [20], [20, 11], [20, 10]])
        #expect(file.storage.compositions.count == 2)
        #expect(file.storage.instances.count == 6)
        for layer in file.composition.layers(named: "shared") {
            #expect(file.composition.layer(withID: layer.id)?.id == layer.id)
        }
    }

    /// Null 父变换节点不能从公开同级列表消失；父链不等于 children 树。
    @Test func parentControlLayerRemainsInTree() throws {
        let root = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1), SceneFixtures.layer(2, parent: 1)])
        let file = try SceneFixtures.build([root])
        #expect(file.composition.layers.count == 2)
        #expect(file.composition.layers.allSatisfy { $0.kind == .null && $0.children.isEmpty })
    }

    /// 子实例的时间使用其父源合成帧率，不能一律按根合成帧率换算。
    @Test func childTimesUseTheirOwnParentRate() throws {
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(10, start: -1, duration: 60)], rate: 60)
        let root = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0))])
        let file = try SceneFixtures.build([child, root])
        let layer = try #require(file.composition.layers.first?.children.first)
        #expect(layer.startTime == PAGTime(microseconds: -16_666))
        #expect(layer.duration == PAGTime(microseconds: 1_000_000))
    }

    /// 缺失预合成和缺失父层必须区分报告，不留下空引用假装成功。
    @Test func missingReferencesFail() throws {
        let missingComposition = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .precomposition(id: 9, startFrame: 0))])
        #expect(throws: SceneValidator.invalid("missingCompositionReference")) { try SceneFixtures.build([missingComposition]) }
        let missingParent = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, parent: 9)])
        #expect(throws: SceneValidator.invalid("missingParentLayer")) { try SceneFixtures.build([missingParent]) }
    }

    /// 同级图层或文档合成 ID 冲突均失败，不能以字典覆盖前一条记录。
    @Test func duplicateSourceIDsFail() throws {
        let root = try SceneFixtures.composition(1, layers: [])
        #expect(throws: PAGError.unsupportedFeature("duplicateCompositionID")) { try SceneFixtures.build([root, root]) }
        let repeated = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1), SceneFixtures.layer(1)])
        #expect(throws: SceneValidator.invalid("duplicateOrZeroLayerID")) { try SceneFixtures.build([repeated]) }
    }

    /// 父层自环与多节点环都必须失败，且不依赖递归耗尽栈才停止。
    @Test(arguments: [true, false])
    func parentCyclesFail(_ selfCycle: Bool) throws {
        let layers = selfCycle ? [SceneFixtures.layer(1, parent: 1)] : [SceneFixtures.layer(1, parent: 2), SceneFixtures.layer(2, parent: 1)]
        let root = try SceneFixtures.composition(1, layers: layers)
        #expect(throws: SceneValidator.invalid("parentLayerCycle")) { try SceneFixtures.build([root]) }
    }

    /// 即使根不引用坏合成，文档中存在的合成环仍使整个载入失败。
    @Test func unreachableCompositionCycleFails() throws {
        let a = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .precomposition(id: 2, startFrame: 0))])
        let b = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(2, content: .precomposition(id: 1, startFrame: 0))])
        let root = try SceneFixtures.composition(3, layers: [])
        #expect(throws: SceneValidator.invalid("compositionCycle")) { try SceneFixtures.build([a, b, root]) }
    }

    /// 合成根计为深度一；恰好上限允许，多一层必须在实例展开前失败。
    @Test func compositionDepthIsBounded() throws {
        let leaf = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1)])
        let root = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(2, content: .precomposition(id: 1, startFrame: 0))])
        #expect(try SceneFixtures.build([leaf, root], limits: PAGLoadLimits(maximumCompositionDepth: 2)).composition.layers.count == 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumCompositionDepth")) {
            try SceneFixtures.build([leaf, root], limits: PAGLoadLimits(maximumCompositionDepth: 1))
        }
    }

    /// 少量共享源节点可指数展开；计数必须在展开前限流，不能只限制源层数。
    @Test func expansionLimitPreventsExponentialAllocation() throws {
        var compositions = [try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1)])]
        for id in UInt32(2)...30 {
            compositions.append(try SceneFixtures.composition(id, layers: [
                SceneFixtures.layer(1, content: .precomposition(id: id - 1, startFrame: 0)),
                SceneFixtures.layer(2, content: .precomposition(id: id - 1, startFrame: 0))
            ]))
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumLayerCount")) {
            try SceneFixtures.build(compositions, limits: PAGLoadLimits(maximumLayerCount: 100))
        }
    }

    /// 源图层本身超限时也要拒绝，即使某些合成不从根可达。
    @Test func sourceLayerCountIsBounded() throws {
        let a = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1), SceneFixtures.layer(2)])
        let root = try SceneFixtures.composition(2, layers: [])
        #expect(throws: PAGError.resourceLimitExceeded("maximumLayerCount")) {
            try SceneFixtures.build([a, root], limits: PAGLoadLimits(maximumLayerCount: 1))
        }
    }

    /// 深父链仍可在线性时间内完成；控制层不占用合成引用深度。
    @Test func longParentChainUsesIteration() throws {
        let layers = (UInt32(1)...5000).map { SceneFixtures.layer($0, parent: $0 == 1 ? nil : $0 - 1) }
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: layers)])
        #expect(file.composition.layers.count == 5000)
    }

    /// 溢出的帧区间与无法换成微秒的时基都必须作为文件错误拒绝。
    @Test func invalidTimesFail() throws {
        let overflowing = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, start: .max, duration: 1)])
        #expect(throws: SceneValidator.invalid("invalidFrameRange")) { try SceneFixtures.build([overflowing]) }
        let tinyRate = try SceneFixtures.composition(1, layers: [], rate: .leastNonzeroMagnitude)
        #expect(throws: SceneValidator.invalid("unrepresentableTime")) { try SceneFixtures.build([tinyRate]) }
    }
}
