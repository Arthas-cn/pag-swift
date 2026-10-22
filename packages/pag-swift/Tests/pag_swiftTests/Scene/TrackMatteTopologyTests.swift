import Testing
@testable import pag_swift

/// 轨道遮罩只按所属合成的编码邻层建立源索引，不借图层ID、父链或显示状态推断。
struct TrackMatteTopologyTests {
    /// 首层保留原模式但无引用；其余遮罩层引用紧邻前层，即使前层inactive或ID无序。
    @Test func encodedNeighborWinsOverLayerIDAndVisibility() throws {
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(400, trackMatte: .alpha),
            SceneFixtures.layer(20, active: false),
            SceneFixtures.layer(900, trackMatte: .luma),
            SceneFixtures.layer(7, parent: 400, trackMatte: .alphaInverted)
        ])
        let file = try SceneFixtures.build([source])
        #expect(source.layers[0].trackMatte == .alpha)
        #expect(file.storage.topologies[0].trackMatteSources == [nil, nil, 1, 2])
        #expect(file.storage.topologies[0].parents == [nil, nil, nil, 0])
    }

    /// 预合成边界两侧各自建立邻层索引，不能把子合成首层接到外层最后一层。
    @Test func referencesStayWithinEachComposition() throws {
        let child = try SceneFixtures.composition(11, layers: [
            SceneFixtures.layer(7, trackMatte: .lumaInverted),
            SceneFixtures.layer(8, trackMatte: .alpha)
        ])
        let root = try SceneFixtures.composition(22, layers: [
            SceneFixtures.layer(30, content: .precomposition(id: 11, startFrame: 0)),
            SceneFixtures.layer(40, trackMatte: .luma)
        ])
        let file = try SceneFixtures.build([child, root])
        #expect(file.storage.topologies[0].trackMatteSources == [nil, 0])
        #expect(file.storage.topologies[1].trackMatteSources == [nil, 0])
        #expect(child.layers[0].trackMatte == .lumaInverted)
    }
}
