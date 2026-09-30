import Testing
@testable import pag_swift

/// 新生成器进入共同准备器、描述值匹配和FramePlan后的动画时间、复用与失败原子性。
struct ShapeGeneratorPreparationTests {
    /// 九条新轨道单独变化都标记动画、替换几何身份，恢复旧帧则复用先前描述。
    @Test(arguments: 0..<9)
    func everyTrackInvalidatesGeometryAndRestores(_ field: Int) throws {
        let source = try animatedSource(field)
        let elements = [source, ShapePropertyFixtures.fill()]
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try ShapePreparation.isAnimated(elements, budget: &budget))
        let first = try ShapePropertyFixtures.prepare(elements)
        let changed = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [first])
        #expect(first.geometries[0] !== changed.geometries[0])
        let restored = try ShapePropertyFixtures.prepare(elements, reuse: [changed, first])
        #expect(restored.geometries[0] === first.geometries[0])
    }

    /// 颜色和alpha变化不生成新路径身份，warm网格在仅允许一次查找工作的预算内复用。
    @Test(arguments: [false, true])
    func paintOnlyChangesReuseGeometryAndMesh(_ polyStar: Bool) throws {
        let source: SourceShape = polyStar ? .polyStar(ShapeGeneratorFixtures.polyStar()) : .ellipse(ShapeGeneratorFixtures.ellipse())
        let fill = try ShapePropertyFixtures.fill(color: ShapePropertyFixtures.track(.defaultFill, SceneColor(red: 0, green: 20, blue: 90)),
            opacity: ShapePropertyFixtures.track(UInt8(200), UInt8(100)))
        let first = try ShapePropertyFixtures.prepare([source, fill])
        let middle = try ShapePropertyFixtures.prepare([source, fill], frame: 5, reuse: [first])
        #expect(first.geometries[0] === middle.geometries[0])
        var cache = try RenderGeometryCache()
        var cold = try GeometryBudget()
        let mesh = try cache.mesh(for: .shape(first.geometries[0]), transform: .identity, budget: &cold)
        var warm = try GeometryBudget(maximumWork: 1)
        #expect(try cache.mesh(for: .shape(middle.geometries[0]), transform: .identity, budget: &warm) === mesh)
        #expect(cold.work > warm.work && warm.work == 1)
    }

    /// 新轮廓保留组矩阵并向父fill累计，透明子组仍有路径；变换后不能复用旧几何。
    @Test(arguments: [false, true])
    func transparentGroupsKeepParentContoursAndMatrixIdentity(_ polyStar: Bool) throws {
        let source: SourceShape = polyStar ? .polyStar(ShapeGeneratorFixtures.polyStar()) : .ellipse(ShapeGeneratorFixtures.ellipse())
        let transform = try ShapePropertyFixtures.group(position: ShapePropertyFixtures.track(.zero, ScenePoint(x: 20, y: 30)),
            opacity: .init(constant: 0))
        let elements: [SourceShape] = [.group(transform, [source, ShapePropertyFixtures.fill()]), ShapePropertyFixtures.fill()]
        let first = try ShapePropertyFixtures.prepare(elements)
        let changed = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [first])
        #expect(first.instructions.count == 1 && first.geometryIndicesByPaint == [1: 0])
        #expect(first.geometries[0] !== changed.geometries[0])
        #expect(changed.geometries[0].contours[0].matrix == (try .translation(x: 20, y: 30)))
        #expect(try ShapeGeneratorFixtures.mesh(changed.geometries[0]).vertices.isEmpty == false)
    }

    /// 同源两个实例在帧5/10独立求值，不再次减图层起点；两种轮廓均进入动态帧表。
    @Test(arguments: [false, true])
    func instancesKeepDistinctCompositionTimes(_ polyStar: Bool) async throws {
        let position = try ShapePropertyFixtures.track(ScenePoint.zero, ScenePoint(x: 20, y: 40))
        let source: SourceShape = polyStar ? .polyStar(ShapeGeneratorFixtures.polyStar(position: position))
                                          : .ellipse(ShapeGeneratorFixtures.ellipse(position: position))
        let file = try ShapePropertyFixtures.file([source, ShapePropertyFixtures.fill()], start: 5)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.isEmpty && scene.dynamicShapes != nil)
        let frame = try await ShapePathFixtures.plan(scene, at: 10)
        let paints = ShapePathFixtures.fills(frame)
        #expect(Set(paints.compactMap(\.geometryID.sampleFrame)) == [5, 10])
        for paint in paints {
            let sample = try #require(paint.geometryID.sampleFrame)
            let geometry = try #require(frame.shapes[paint.geometryID])
            switch geometry.contours[0] {
            case .ellipse(let contour):
                #expect(contour.left == Float(sample * 2) - 10 && contour.top == Float(sample * 4) - 5)
            case .polyStar(let contour):
                #expect(contour.position == ScenePoint(x: Double(sample) * 2, y: Double(sample) * 4))
            default: Issue.record("新源类型必须保持对应描述轮廓")
            }
        }
    }

    /// 常量生成器安装时准备，帧计划只保活相同描述资源，不创建动态owner。
    @Test func constantsStayOnInstallationPath() async throws {
        let file = try ShapePropertyFixtures.file([.ellipse(ShapeGeneratorFixtures.ellipse()),
            .polyStar(ShapeGeneratorFixtures.polyStar()), ShapePropertyFixtures.fill()], offsets: [0])
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.count == 1 && scene.dynamicShapes == nil)
        let first = try await ShapePathFixtures.plan(scene, at: 0)
        let last = try await ShapePathFixtures.plan(scene, at: 20)
        let id = try #require(ShapePathFixtures.fills(first).first?.geometryID)
        #expect(id.sampleFrame == nil && first.shapes[id] === last.shapes[id])
    }

    /// 最大合法组深度的叶子也能求值新载荷；Debug不得耗尽线程栈，超出一层仍明确失败。
    @Test(arguments: [false, true])
    func deepestLegalGroupsEvaluateNewGenerators(_ polyStar: Bool) throws {
        let source: SourceShape = polyStar ? .polyStar(ShapeGeneratorFixtures.polyStar()) : .ellipse(ShapeGeneratorFixtures.ellipse())
        var elements = [source, ShapePropertyFixtures.fill()]
        for _ in 0..<64 { elements = [.group(ShapePropertyFixtures.group(), elements)] }
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try ShapePreparation.isAnimated(elements, budget: &budget) == false)
        #expect(try ShapePropertyFixtures.prepare(elements).geometries.count == 1)
        let excessive: [SourceShape] = [.group(ShapePropertyFixtures.group(), elements)]
        #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) {
            try ShapePropertyFixtures.prepare(excessive)
        }
    }

    /// Polygon未使用的内轨道也完整求值；失败不替换四项缓存中原有成功样本。
    @Test func unusedPolygonTrackFailureDoesNotPublish() async throws {
        let largest = Double(Float.greatestFiniteMagnitude)
        let source = try ShapeGeneratorFixtures.polyStar(kind: .polygon,
            innerRadius: ShapePropertyFixtures.track(-largest, largest))
        let reference = SourceLayerReference(composition: 0, layer: 0)
        let store = try PreparedShapeStore(templates: [reference: [.polyStar(source), ShapePropertyFixtures.fill()]])
        let key = ShapeSampleKey(source: reference, frame: 0)
        let first = try await store.sample(key, maximumPreparedBytes: 1_000_000)
        let retained = await store.retainedBytes
        await #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try await store.sample(ShapeSampleKey(source: reference, frame: 5), maximumPreparedBytes: 1_000_000)
        }
        #expect(await store.retainedBytes == retained)
        let repeated = try await store.sample(key, maximumPreparedBytes: 1_000_000)
        #expect(repeated.geometries[0] === first.geometries[0])
    }

    /// 只令一个字段变化，其余常量相同；完整描述匹配不能漏掉同类型字段。
    private func animatedSource(_ field: Int) throws -> SourceShape {
        let point = try ShapePropertyFixtures.track(ScenePoint(x: 20, y: 10), ScenePoint(x: 30, y: 40))
        if field < 2 {
            return .ellipse(ShapeGeneratorFixtures.ellipse(size: field == 0 ? point : .init(constant: .one),
                position: field == 1 ? point : .init(constant: .zero)))
        }
        let scalar = try ShapePropertyFixtures.track(1.0, 2.0)
        return .polyStar(ShapeGeneratorFixtures.polyStar(points: field == 2 ? scalar : .init(constant: 5),
            position: field == 3 ? point : .init(constant: .zero), rotation: field == 4 ? scalar : .init(constant: 90),
            innerRadius: field == 5 ? scalar : .init(constant: 1), outerRadius: field == 6 ? scalar : .init(constant: 2),
            innerRoundness: field == 7 ? scalar : .init(constant: 0), outerRoundness: field == 8 ? scalar : .init(constant: 0)))
    }
}
