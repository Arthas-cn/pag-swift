import Testing
@testable import pag_swift

/// 静态形状的路径累计、填充顺序、组 alpha 和几何边界；语义片段不冒充完整 PAG 文件。
struct ShapePreparationTests {
    /// fill 使用此前所有路径且不清空；缺省 BelowPrevious 反转绘制项，相同路径快照复用。
    @Test func fillsAccumulatePathsAndDrawBelowPrevious() throws {
        let prepared = try prepare([
            rectangle(), .fill(color: red, opacity: 255), rectangle(x: 30),
            .fill(color: blue, opacity: 128), .fill(color: green, opacity: 255)
        ])
        let paints = fills(prepared)
        #expect(try paints.map { try $0.material.solidColor() } == [green, blue, red])
        #expect(paints.map(\.geometryIndex) == [1, 1, 0])
        #expect(prepared.geometries.map { $0.contours.count } == [1, 2])
        #expect(paints[1].opacity == Double(128) / 255)
    }

    /// 零 alpha 子组没有自己的画面，但其变换后的路径仍参与外层 fill。
    @Test func invisibleGroupStillContributesPathsToOuterFill() throws {
        let group = transformed(x: 40, opacity: 0)
        let prepared = try prepare([.group(group, [rectangle(), .fill(color: red, opacity: 255)]),
                                    .fill(color: blue, opacity: 255)])
        let paints = fills(prepared)
        #expect(try paints.count == 1 && paints[0].material.solidColor() == blue && paints[0].opacity == 1)
        let contour = try #require(prepared.geometries[paints[0].geometryIndex].contours.first)
        #expect(contour.matrix.tx == 40 && contour.matrix.ty == 0)
        #expect(prepared.instructions.count == 1)
        #expect(prepared.geometries.count == 1)
    }

    /// 子组画面插在同组旧内容下方，外层后续填充在最下方；内部两次填充共享整体 alpha。
    @Test func nestedPaintsKeepOneOpacityBoundary() throws {
        let prepared = try prepare([
            rectangle(), .fill(color: red, opacity: 255),
            .group(transformed(x: 30, opacity: 128), [rectangle(), .fill(color: blue, opacity: 255),
                                                    .fill(color: green, opacity: 255)]),
            .fill(color: white, opacity: 255)
        ])
        #expect(try fills(prepared).map { try $0.material.solidColor() } == [white, green, blue, red])
        #expect(prepared.instructions.count == 6)
        guard case .beginOpacityGroup(let alpha) = prepared.instructions[1],
              case .endOpacityGroup = prepared.instructions[4] else {
            Issue.record("透明度组必须只包住两次内部 fill")
            return
        }
        #expect(alpha == Double(128) / 255)
        #expect(fills(prepared).allSatisfy { $0.opacity == 1 })
        let outer = try #require(fills(prepared).first)
        #expect(prepared.geometries[outer.geometryIndex].contours.map(\.matrix.tx) == [0, 30])
    }

    /// 同一 fill 的正反两个轮廓必须保留在一个资源中，为后续 nonzero 孔洞填充提供完整信息。
    @Test func oppositeWindingContoursRemainOneCompoundGeometry() throws {
        let prepared = try prepare([rectangle(size: ScenePoint(x: 100, y: 100)),
                                    rectangle(reversed: true), .fill(color: red, opacity: 255)])
        let paint = try #require(fills(prepared).first)
        let geometry = prepared.geometries[paint.geometryIndex]
        #expect(fills(prepared).count == 1 && geometry.contours.count == 2)
        let contours = try geometry.contours.map { try rectangleContour($0) }
        #expect(contours.map(\.reversed) == [false, true])
        #expect(contours[0].center == contours[1].center)
    }

    /// 空路径和零透明fill不生成画面；零面积矩形保留给描边，后续fill仍使用完整累计路径。
    @Test func emptyAndTransparentPaintsDoNotConsumePaths() throws {
        let prepared = try prepare([.fill(color: blue, opacity: 255), rectangle(size: ScenePoint(x: 0, y: 20)),
                                    rectangle(), .fill(color: blue, opacity: 0), .fill(color: red, opacity: 255)])
        #expect(prepared.instructions.count == 1 && prepared.geometries.count == 1)
        #expect(prepared.geometries[0].contours.count == 2)
        #expect(try fills(prepared).first?.material.solidColor() == red)
    }

    /// 圆角先受源半尺寸限制；负尺寸随后规范化且圆角为零，反向标志保持原值。
    @Test func radiusAndSignedSizeFollowRectangleRules() throws {
        let rounded = try RoundedRectangleContour.make(size: ScenePoint(x: 100, y: 40), position: .zero,
                                                                roundness: 100, reversed: false, matrix: .identity)
        #expect(rounded.radius == 20)
        let negative = try RoundedRectangleContour.make(size: ScenePoint(x: -100, y: 40), position: .zero,
                                                                 roundness: 10, reversed: true, matrix: .identity)
        #expect(negative.size == ScenePoint(x: 100, y: 40))
        #expect(negative.radius == 0 && negative.reversed)
        let sharp = try RoundedRectangleContour.make(size: ScenePoint(x: 100, y: 40), position: .zero,
                                                              roundness: -1, reversed: false, matrix: .identity)
        #expect(sharp.radius == 0)
    }

    /// 静态组的多级平移和反射保留在轮廓矩阵中，后续图层矩阵不应再应用这些组变换。
    @Test func nestedTransformsAreBakedIntoContourPlacementOnce() throws {
        let reflection = SourceShapeTransform(base: SourceTransform(anchor: .zero, position: ScenePoint(x: 2, y: 0),
                                                                    scale: ScenePoint(x: -1, y: 1), rotation: 0, opacity: 255),
                                               skew: 0, skewAxis: 0)
        let prepared = try prepare([.group(transformed(x: 10), [.group(reflection, [rectangle()])]),
                                    .fill(color: red, opacity: 255)])
        let contour = try #require(prepared.geometries.first?.contours.first)
        #expect(contour.matrix.a == -1 && contour.matrix.tx == 12)
        #expect(try contour.matrix.applying(to: ScenePoint(x: 5, y: 0)) == ScenePoint(x: 7, y: 0))
    }

    /// 形状准备也遵守 64 层上限；语义图不能绕过解码入口的深度约束。
    @Test(arguments: [64, 65])
    func depthRemainsBounded(_ count: Int) throws {
        var elements: [SourceShape] = [rectangle(), .fill(color: red, opacity: 255)]
        for _ in 0..<count { elements = [.group(transformed(x: 1), elements)] }
        if count == 64 {
            let prepared = try prepare(elements)
            #expect(prepared.geometries.first?.contours.first?.matrix.tx == 64)
        } else {
            #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) { try prepare(elements) }
        }
    }

    /// 累计路径多次快照的真实增长必须计费，非有限几何拒绝，取消保留专用错误。
    @Test func budgetsInvalidGeometryAndCancellationFail() async throws {
        var elements: [SourceShape] = []
        for _ in 0..<30 { elements += [rectangle(), .fill(color: red, opacity: 255)] }
        var budget = FramePlanBudget(limit: 5000, resourceName: "maximumPreparedSceneBytes")
        #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try ShapePreparation.prepare(elements, budget: &budget)
        }
        #expect(throws: SceneValidator.invalid("unrepresentableShapeGeometry")) {
            try prepare([.rectangle(reversed: false, size: .one, position: .zero, roundness: .infinity)])
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try prepare([rectangle(), .fill(color: red, opacity: 255)])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 各测试独立预留预算，不让其他测试的几何缓存掩盖资源增长。
    private func prepare(_ elements: [SourceShape]) throws -> PreparedShapeLayer {
        var budget = FramePlanBudget(limit: 1_000_000, resourceName: "maximumPreparedSceneBytes")
        return try ShapePreparation.prepare(elements, budget: &budget)
    }

    /// 创建中心可偏移的矩形语义元素，默认不反向且无圆角。
    private func rectangle(x: Double = 0, size: ScenePoint = ScenePoint(x: 20, y: 20), reversed: Bool = false) -> SourceShape {
        .rectangle(reversed: reversed, size: size, position: ScenePoint(x: x, y: 0), roundness: 0)
    }

    /// 创建恒等缩放的水平组位移和指定整体 alpha。
    private func transformed(x: Double, opacity: UInt8 = 255) -> SourceShapeTransform {
        SourceShapeTransform(base: SourceTransform(anchor: .zero, position: ScenePoint(x: x, y: 0), scale: .one,
                                                   rotation: 0, opacity: opacity), skew: 0, skewAxis: 0)
    }

    /// 提取真实顺序的填充指令，不删除或重排资源。
    private func fills(_ layer: PreparedShapeLayer) -> [ShapePaint] {
        layer.instructions.compactMap { if case .fill(let paint) = $0 { paint } else { nil } }
    }

    /// 从复合几何中要求矩形分支；旧矩形测试不能把新增路径分支误当默认矩形。
    private func rectangleContour(_ contour: ShapeContour) throws -> RoundedRectangleContour {
        let value: RoundedRectangleContour? = if case .rectangle(let rectangle) = contour { rectangle } else { nil }
        return try #require(value)
    }

    /// 默认红色，用于区分先后填充的覆盖关系。
    private let red = SceneColor(red: 255, green: 0, blue: 0)
    /// 第二次填充使用的蓝色。
    private let blue = SceneColor(red: 0, green: 0, blue: 255)
    /// 第三次填充使用的绿色。
    private let green = SceneColor(red: 0, green: 255, blue: 0)
    /// 最外层填充的白色，与所有子组 paint 区分。
    private let white = SceneColor(red: 255, green: 255, blue: 255)
}
