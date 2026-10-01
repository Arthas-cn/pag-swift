@testable import pag_swift

/// 渐变真实drawable场景；全为纯语义模型，不替代正式PAG字节与完整文件验收。
enum MetalGradientFixtures {
    /// 水平60单位渐变，端点对准像素中心，径向中线的0/0.25/0.5/0.75/1可精确采样。
    static func material(kind: SourceGradientKind = .linear, colors: SourceGradientColors? = nil) -> SourceGradient {
        GradientShapeFixtures.gradient(kind: kind, start: .init(constant: ScenePoint(x: 20.5, y: 50.5)),
            end: .init(constant: ScenePoint(x: 80.5, y: 50.5)), colors: colors.map { .init(constant: $0) })
    }

    /// 10...90内的完整填充，所有色值探针远离几何边缘。
    static func filled(_ material: SourceGradient) -> [SourceShape] {
        [ShapePropertyFixtures.rectangle(size: .init(constant: ScenePoint(x: 80, y: 80)),
            position: .init(constant: ScenePoint(x: 50, y: 50))),
         .gradientFill(.init(compositeOrder: .belowPrevious, gradient: material))]
    }

    /// 第一段midpoint1在t0.5生成跳变；第二段仍为普通green→blue插值。
    static func hardstop() -> SourceGradientColors {
        SourceGradientColors(alphaStops: [.init(position: 0, midpoint: 0.5, opacity: 255),
                                         .init(position: 1, midpoint: 0.5, opacity: 255)],
            colorStops: [.init(position: 0, midpoint: 1, color: GradientColorFixtures.red),
                         .init(position: 0.5, midpoint: 0.5, color: GradientColorFixtures.green),
                         .init(position: 1, midpoint: 0.5, color: GradientColorFixtures.blue)])
    }

    /// 两个相同渐变的重叠矩形整体淡出；相同位置颜色相同，重叠alpha不能重复乘或叠加。
    static func groupOpacity() throws -> [SourceShape] {
        let source = material()
        let children: [SourceShape] = [40.0, 60.0].map { center in
            .group(ShapePropertyFixtures.group(), [ShapePropertyFixtures.rectangle(
                size: .init(constant: ScenePoint(x: 40, y: 40)), position: .init(constant: ScenePoint(x: center, y: 50))),
                .gradientFill(.init(compositeOrder: .belowPrevious, gradient: source))])
        }
        return [.group(ShapePropertyFixtures.group(opacity: try ShapePropertyFixtures.track(UInt8(255), UInt8(0))), children)]
    }

    /// 水平中心线10画10空，线宽4→12；reversed反转dash推进方向，材料方向保持不变。
    static func dashedStroke(reversed: Bool) throws -> [SourceShape] {
        let first = ScenePoint(x: 20.5, y: 50.5), last = ScenePoint(x: 80.5, y: 50.5)
        let path = try SourcePath(verbs: [.move, .line], points: reversed ? [last, first] : [first, last])
        let stroke = try SourceGradientStroke(compositeOrder: .abovePrevious, gradient: material(), cap: .butt,
            join: .miter, miterLimit: .init(constant: 4), width: ShapePropertyFixtures.track(4.0, 12),
            dashes: SourceDashes(offset: .init(constant: 0), intervals: [.init(constant: 10), .init(constant: 10)]))
        return [.path(.init(constant: path)), .gradientStroke(stroke)]
    }

    /// 颜色轨道从red/blue变green/blue，保持端点与几何，0/5/10/0验证旧程序不会污染新帧。
    static func animatedColor() throws -> [SourceShape] {
        let first = GradientColorFixtures.colors()
        let last = GradientColorFixtures.colors(rgb: [(0, GradientColorFixtures.green), (1, GradientColorFixtures.blue)])
        let source = try GradientShapeFixtures.gradient(start: .init(constant: ScenePoint(x: 20.5, y: 50.5)),
            end: .init(constant: ScenePoint(x: 80.5, y: 50.5)), colors: ShapePropertyFixtures.track(first, last))
        return filled(source)
    }

    /// 半径0→60→0切换solid/gradient管线；Radial零半径使用不透明蓝末色。
    static func animatedRadius() throws -> [SourceShape] {
        let source = try GradientShapeFixtures.gradient(kind: .radial, start: .init(constant: ScenePoint(x: 20.5, y: 50.5)),
            end: ShapePropertyFixtures.track(ScenePoint(x: 20.5, y: 50.5), ScenePoint(x: 80.5, y: 50.5)))
        return filled(source)
    }

    /// 组矩阵为[2,1,10;0,2,10]，独立期望可以直接解出local.y=(y-10)/2及local.x=(x-10-local.y)/2。
    static func sheared(kind: SourceGradientKind) -> [SourceShape] {
        let source = GradientShapeFixtures.gradient(kind: kind, start: .init(constant: .zero),
            end: .init(constant: ScenePoint(x: 40, y: 0)))
        let content = [ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 20, y: 20))),
            SourceShape.gradientFill(.init(compositeOrder: .belowPrevious, gradient: source))]
        return [.group(ShapePropertyFixtures.group(position: .init(constant: ScenePoint(x: 10, y: 10)),
            scale: .init(constant: ScenePoint(x: 2, y: 2)), skew: .init(constant: -26.56505117707799)), content)]
    }

    /// 负x缩放只反转显示方向，不交换材料端点；局部内容10...30映到世界20...60。
    static func mirrored() -> [SourceShape] {
        let source = GradientShapeFixtures.gradient(start: .init(constant: .zero), end: .init(constant: ScenePoint(x: 40, y: 0)))
        let content = [ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 20, y: 20))),
            SourceShape.gradientFill(.init(compositeOrder: .belowPrevious, gradient: source))]
        return [.group(ShapePropertyFixtures.group(position: .init(constant: ScenePoint(x: 80, y: 10)),
            scale: .init(constant: ScenePoint(x: -2, y: 1))), content)]
    }

    /// 大组平移被图层平移抵消；Mesh.origin须保留Double局部差值，不能提前转Float丢掉像素位置。
    static func largeOriginScene() async throws -> PreparedScene {
        let offset = 16_777_216.0
        let source = GradientShapeFixtures.gradient(start: .init(constant: .zero), end: .init(constant: ScenePoint(x: 40, y: 0)))
        let content = [ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 20, y: 20))),
            SourceShape.gradientFill(.init(compositeOrder: .belowPrevious, gradient: source))]
        let elements: [SourceShape] = [.group(ShapePropertyFixtures.group(position: .init(constant: ScenePoint(x: offset, y: offset))), content)]
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 10 - offset, y: 10 - offset), scale: .one, rotation: 0, opacity: 255))
        let composition = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, transform: transform, content: .shape(elements))])
        return try await PreparedScene.prepare(SceneFixtures.build([composition]).composition)
    }
}
