import Testing
@testable import pag_swift

/// 求值层的矩阵次序、控制层父链与数值失败，不依赖 GPU 或主线程宿主。
struct TransformEvaluationTests {
    /// following 表示先当前后父级；平移和缩放交换时应得到不同结果。
    @Test func concatenationOrderMatchesColumnVectors() throws {
        let translation = try SceneAffine.translation(x: 10, y: 20)
        let scale = try SceneAffine.scale(x: 2, y: 3)
        let point = ScenePoint(x: 1, y: 2)
        #expect(try translation.following(scale).applying(to: point) == ScenePoint(x: 22, y: 66))
        #expect(try scale.following(translation).applying(to: point) == ScenePoint(x: 12, y: 26))
        #expect(try SceneAffine.identity.applying(to: point) == point)
    }

    /// 锚点映射为 position，偏离锚点的向量先缩放再旋转。
    @Test func layerTransformPreservesAnchorOrder() throws {
        let source = SourceTransform(anchor: ScenePoint(x: 10, y: 20), position: ScenePoint(x: 100, y: 200),
                                     scale: ScenePoint(x: 2, y: 3), rotation: 90, opacity: 128)
        let value = try TransformEvaluation.layer(source)
        try expect(value.matrix.applying(to: source.anchor), equals: source.position)
        try expect(value.matrix.applying(to: ScenePoint(x: 11, y: 22)), equals: ScenePoint(x: 94, y: 202))
        #expect(value.opacity == 128.0 / 255)
    }

    /// 控制层父链带来坐标变化，但父透明度为零也不能把子层自身 opacity 清零。
    @Test func parentControlOpacityIsNotInherited() throws {
        let child = EvaluatedTransform(matrix: try .translation(x: 5, y: 0), opacity: 0.75)
        let parent = EvaluatedTransform(matrix: try .scale(x: 2, y: 3), opacity: 0)
        let grandparent = EvaluatedTransform(matrix: try .translation(x: 100, y: 200), opacity: 0.2)
        let value = try child.followingParent(parent).followingParent(grandparent)
        #expect(value.opacity == 0.75)
        #expect(try value.matrix.applying(to: .zero) == ScenePoint(x: 110, y: 200))
    }

    /// 零缩放保留退化几何，负缩放保留翻转；矩阵构造不擅自决定可见性。
    @Test func degenerateAndReflectedScalesArePreserved() throws {
        let source = SourceTransform(anchor: .zero, position: .zero, scale: ScenePoint(x: -2, y: 0),
                                     rotation: 0, opacity: 255)
        let value = try TransformEvaluation.layer(source)
        #expect(try value.matrix.applying(to: ScenePoint(x: 3, y: 4)) == ScenePoint(x: -6, y: 0))
        #expect(value.opacity == 1)
    }

    /// 形状 skew 的负号和轴角对应上游三步矩阵；不能直接用正 tan(skew)。
    @Test func shapeSkewRespectsItsAxis() throws {
        let horizontal = SourceShapeTransform(base: SceneFixtures.transform, skew: 45, skewAxis: 0)
        let vertical = SourceShapeTransform(base: SceneFixtures.transform, skew: 45, skewAxis: 90)
        try expect(TransformEvaluation.shape(horizontal).matrix.applying(to: ScenePoint(x: 0, y: 2)),
                   equals: ScenePoint(x: -2, y: 2))
        try expect(TransformEvaluation.shape(vertical).matrix.applying(to: ScenePoint(x: 2, y: 0)),
                   equals: ScenePoint(x: 2, y: 2))
        let noSkew = SourceShapeTransform(base: SceneFixtures.transform, skew: 0, skewAxis: 90)
        #expect(try TransformEvaluation.shape(noSkew) == TransformEvaluation.layer(SceneFixtures.transform))
    }

    /// 真实 red 形状组的矩形中心和角点经组/层矩阵后应落在独立计算的位置。
    @Test func realRedGeometryKeepsItsSourceTransform() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        let layer = try #require(file.storage.compositions.last?.layers.first)
        guard case .shape(let elements) = layer.content,
              case .group(let group, _) = try #require(elements.first) else {
            Issue.record("red 必须保留其完整形状组")
            return
        }
        let combined = try TransformEvaluation.shape(group.value(at: 0)).matrix
            .following(TransformEvaluation.layer(layer.transform.value(at: 0)).matrix)
        try expect(combined.applying(to: .zero), equals: ScenePoint(x: 360, y: 640))
        try expect(combined.applying(to: ScenePoint(x: -750, y: -150)),
                   equals: ScenePoint(x: 0.1419416069984436, y: 1.7238044738769531))
        let display = try DisplayTransform(contentSize: file.composition.size, targetSize: PAGSize(width: 360, height: 360),
                                           scale: 2, mode: .aspectFit)
        try expect(combined.following(SceneAffine(display: display)).applying(to: .zero), equals: ScenePoint(x: 360, y: 360))
    }

    /// 非有限值、级联及点映射溢出必须在 FramePlan/GPU 之前失败。
    @Test func unrepresentableTransformsFail() throws {
        let failure = SceneValidator.invalid("unrepresentableTransform")
        #expect(throws: failure) { try SceneAffine.rotation(degrees: .infinity) }
        #expect(throws: failure) { try SceneAffine.translation(x: .nan, y: 0) }
        let huge = try SceneAffine.scale(x: Double.greatestFiniteMagnitude, y: 1)
        #expect(throws: failure) { try huge.following(.scale(x: 2, y: 1)) }
        #expect(throws: failure) { try huge.applying(to: ScenePoint(x: 2, y: 0)) }
    }

    /// 三角函数结果使用小数容差；业务坐标预期由测试场景独立确定。
    private func expect(_ actual: ScenePoint, equals expected: ScenePoint) {
        #expect(abs(actual.x - expected.x) < 0.000_001)
        #expect(abs(actual.y - expected.y) < 0.000_001)
    }
}
