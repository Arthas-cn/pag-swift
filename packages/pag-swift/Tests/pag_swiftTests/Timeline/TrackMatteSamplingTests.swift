import Testing
@testable import pag_swift

/// 轨道遮罩的邻层时间选择，区分无引用与有引用但源层当前为空。
struct TrackMatteSamplingTests {
    /// 首层非None不安装遮罩；后层引用inactive源仍按其自身起点求内容时刻。
    @Test func firstLayerAndInactiveSourceKeepDistinctSemantics() throws {
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(40, start: 10, duration: 5, active: false, trackMatte: .alpha),
            SceneFixtures.layer(10, trackMatte: .alpha)
        ])
        let file = try SceneFixtures.build([source])
        let topology = file.storage.topologies[0]
        #expect(try select(source, topology: topology, ownerIndex: 0, frame: 10) == .unmasked)
        #expect(try select(source, topology: topology, ownerIndex: 1, frame: 9) == .empty(mode: .alpha))
        let selected = try select(source, topology: topology, ownerIndex: 1, frame: 10)
        #expect(selected == .source(TrackMatteSourceState(
            mode: .alpha, layerIndex: 0, time: LayerSampleTime(contentFrame: 0, contentTime: .zero),
            transform: EvaluatedTransform(matrix: .identity, opacity: 1))))
        #expect(try select(source, topology: topology, ownerIndex: 1, frame: 15) == .empty(mode: .alpha))
    }

    /// 空源仍保留反向亮度模式，后续绘制层才能应用全留而非无条件消掉拥有者。
    @Test func emptySourceRetainsInverseMode() throws {
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(3, start: 10, duration: 2),
            SceneFixtures.layer(7, trackMatte: .lumaInverted)
        ])
        let file = try SceneFixtures.build([source])
        #expect(try select(source, topology: file.storage.topologies[0],
                           ownerIndex: 1, frame: 0) == .empty(mode: .lumaInverted))
    }

    /// 源层非零起点只影响内容帧；自身及inactive控制父层的动画按所属合成帧采样。
    @Test func sourceTransformUsesCompositionFrameAndParentMatrix() throws {
        let x = try SourceProperty<Double>(keyframes: [SourceKeyframe(
            startFrame: 0, endFrame: 20, startValue: 0, endValue: 100,
            easing: .linear, spatialCurve: nil)])
        let animated = SourceTransformProperties(
            anchor: SourceProperty(constant: .zero),
            position: .separated(x: x, y: SourceProperty(constant: 0)),
            scale: SourceProperty(constant: .one), rotation: SourceProperty(constant: 0),
            opacity: SourceProperty(constant: 255))
        let parent = SourceTransformProperties(constant: SourceTransform(
            anchor: .zero, position: ScenePoint(x: 20, y: 0), scale: .one, rotation: 0, opacity: 0))
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(40, parent: 99, start: 10, duration: 10, active: false, transform: animated),
            SceneFixtures.layer(10, trackMatte: .alpha),
            SceneFixtures.layer(99, start: 25, duration: 2, active: false, transform: parent)
        ])
        let file = try SceneFixtures.build([source])
        let selected = try select(source, topology: file.storage.topologies[0], ownerIndex: 1, frame: 10)
        guard case .source(let state) = selected else {
            Issue.record("源层位于时间区间内，应保留独立变换")
            return
        }
        #expect(state.time.contentFrame == 0)
        #expect(state.transform.matrix.tx == 70)
        #expect(state.transform.opacity == 1)
    }

    /// 有引用但源层自身零alpha或矩阵奇异时，应保留模式并交给空图形分支。
    @Test func sourceInvisibleTransformBecomesEmpty() throws {
        let transparent = SourceTransformProperties(constant: SourceTransform(
            anchor: .zero, position: .zero, scale: .one, rotation: 0, opacity: 0))
        let collapsed = SourceTransformProperties(constant: SourceTransform(
            anchor: .zero, position: .zero, scale: ScenePoint(x: 0, y: 1), rotation: 0, opacity: 255))
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, transform: transparent),
            SceneFixtures.layer(2, trackMatte: .alpha),
            SceneFixtures.layer(3, transform: collapsed),
            SceneFixtures.layer(4, trackMatte: .lumaInverted)
        ])
        let file = try SceneFixtures.build([source])
        let topology = file.storage.topologies[0]
        #expect(try select(source, topology: topology, ownerIndex: 1, frame: 0) == .empty(mode: .alpha))
        #expect(try select(source, topology: topology, ownerIndex: 3, frame: 0) == .empty(mode: .lumaInverted))
    }

    /// 首层虽写Alpha却没有引用，正式帧计划应继续发出原图元。
    @Test func firstLayerWithoutReferencePlansOriginalContent() async throws {
        let size = try PAGSize(width: 20, height: 20)
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, trackMatte: .alpha,
                                content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0)))
        ])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        #expect(frame.plan.commands.contains { if case .solid = $0 { true } else { false } })
    }

    /// inactive邻层仍单独求源图形，拥有者另成一段；计划不能将源误当普通兄弟层。
    @Test func referencedSourcePlansSeparateSourceAndOwner() async throws {
        let size = try PAGSize(width: 20, height: 20)
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, active: false,
                                content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0))),
            SceneFixtures.layer(2, trackMatte: .alpha,
                                content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        let commands = frame.plan.commands
        let begin = try #require(commands.firstIndex { if case .beginTrackMatte = $0 { true } else { false } })
        let separator = try #require(commands.firstIndex { if case .endTrackMatteSource = $0 { true } else { false } })
        let end = try #require(commands.firstIndex { if case .endTrackMatte = $0 { true } else { false } })
        #expect(begin < separator && separator < end)
        let colors = commands.compactMap { command -> SceneColor? in
            if case .solid(let value) = command { return value.color }
            return nil
        }
        #expect(colors.map(\.red) == [255, 0])
        #expect(colors.map(\.blue) == [0, 255])
        #expect(commands[(end + 1)...].allSatisfy { if case .solid = $0 { false } else { true } })
    }

    /// 有引用但源层尚未开始时，正向Alpha/Luma都隐藏拥有者，反向两种模式保留拥有者。
    @Test func emptyReferencedSourcePlansByInversion() async throws {
        let size = try PAGSize(width: 20, height: 20)
        for (mode, visible) in [(SourceTrackMatteType.alpha, false), (.luma, false),
                                (.alphaInverted, true), (.lumaInverted, true)] {
            let source = try SceneFixtures.composition(1, layers: [
                SceneFixtures.layer(1, start: 10, duration: 5,
                                    content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0))),
                SceneFixtures.layer(2, trackMatte: mode,
                                    content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
            ])
            let file = try SceneFixtures.build([source])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
            let solids = frame.plan.commands.compactMap { command -> FrameSolid? in
                if case .solid(let solid) = command { return solid }
                return nil
            }
            #expect(solids.count == (visible ? 1 : 0))
            if let solid = solids.first { #expect(solid.color.blue == 255) }
        }
    }

    /// 拓扑与源数组长度或邻层不符时必须失败，不能读到另一合成的图层。
    @Test func mismatchedTopologyFails() throws {
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1), SceneFixtures.layer(2, trackMatte: .alpha)
        ])
        let short = CompositionTopology(parents: [], trackMatteSources: [])
        #expect(throws: PAGError.invalidFile(reason: "invalidTrackMatteTopology", offset: nil)) {
            try select(source, topology: short, ownerIndex: 1, frame: 0)
        }
        let wrong = CompositionTopology(parents: [nil, nil], trackMatteSources: [nil, 1])
        #expect(throws: PAGError.invalidFile(reason: "invalidTrackMatteTopology", offset: nil)) {
            try select(source, topology: wrong, ownerIndex: 1, frame: 0)
        }
    }

    /// 每个时刻用对应合成帧的采样器，测试不会跨帧复用其内部缓存。
    private func select(_ source: SourceComposition, topology: CompositionTopology,
                        ownerIndex: Int, frame: Int64) throws -> TrackMatteSelection {
        var sampler = LayerTransformSampler(source: source, topology: topology, frame: frame)
        return try TrackMatteSampling.select(in: source, topology: topology,
                                             ownerIndex: ownerIndex, frame: frame, sampler: &sampler)
    }
}
