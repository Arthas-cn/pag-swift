@testable import pag_swift

/// Ellipse/PolyStar显示门禁的纯语义场景；不制作PAG字节，完整文件验收在正式开放后单独执行。
enum MetalShapeGeneratorFixtures {
    /// 固定生成器从半透明红变为不透明蓝，远离边缘的中心像素只反映paint轨道。
    static func color(polyStar: Bool) throws -> [SourceShape] {
        let center = SourceProperty(constant: ScenePoint(x: 40, y: 40))
        let shape: SourceShape = polyStar ? .polyStar(ShapeGeneratorFixtures.polyStar(points: .init(constant: 5),
            position: center, innerRadius: .init(constant: 10), outerRadius: .init(constant: 20)))
            : .ellipse(ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: 40, y: 40)), position: center))
        return [shape, ShapePropertyFixtures.fill(color: try ShapePropertyFixtures.track(.defaultFill,
            SceneColor(red: 0, green: 0, blue: 255)), opacity: try ShapePropertyFixtures.track(UInt8(128), UInt8(255)))]
    }

    /// 椭圆从20×20扩大到60×40；中点与右侧像素能区分几何实际变化和旧网格复用。
    static func ellipseSize() throws -> [SourceShape] {
        [.ellipse(ShapeGeneratorFixtures.ellipse(size: try ShapePropertyFixtures.track(
            ScenePoint(x: 20, y: 20), ScenePoint(x: 60, y: 40)), position: .init(constant: ScenePoint(x: 50, y: 50)))),
         ShapePropertyFixtures.fill()]
    }

    /// 五角星内外半径分别10→20与20→35，右方顶点在末帧扩展到x85。
    static func starRadii() throws -> [SourceShape] {
        [.polyStar(ShapeGeneratorFixtures.polyStar(points: .init(constant: 5),
            position: .init(constant: ScenePoint(x: 50, y: 50)),
            innerRadius: try ShapePropertyFixtures.track(10.0, 20), outerRadius: try ShapePropertyFixtures.track(20.0, 35))),
         ShapePropertyFixtures.fill()]
    }

    /// 三边形变为六边形，顶点数改变时必须重新生成拓扑，左上探针由外部进入内部。
    static func polygonPoints() throws -> [SourceShape] {
        [.polyStar(ShapeGeneratorFixtures.polyStar(kind: .polygon, points: try ShapePropertyFixtures.track(3.0, 6),
            position: .init(constant: ScenePoint(x: 50, y: 50)), outerRadius: .init(constant: 30))),
         ShapePropertyFixtures.fill()]
    }

    /// 负宽内椭圆以反向绕序形成孔洞，两个轮廓必须属于同一次nonzero填充。
    static func ellipseHole() -> [SourceShape] {
        [.ellipse(ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: 60, y: 60)),
            position: .init(constant: ScenePoint(x: 50, y: 50)))),
         .ellipse(ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: -30, y: 30)),
            position: .init(constant: ScenePoint(x: 50, y: 50)))), ShapePropertyFixtures.fill()]
    }

    /// 10画/10空的四单位描边从顶部起步；reversed只改变沿圆周的推进方向。
    static func ellipseDash(reversed: Bool) throws -> [SourceShape] {
        try [.ellipse(ShapeGeneratorFixtures.ellipse(reversed: reversed, size: .init(constant: ScenePoint(x: 40, y: 40)),
            position: .init(constant: ScenePoint(x: 50, y: 50)))),
         .stroke(StrokeFixtures.make(width: .init(constant: 4), color: .init(constant: .defaultFill),
             dashes: SourceDashes(offset: .init(constant: 0), intervals: [.init(constant: 10), .init(constant: 10)])))]
    }

    /// 两种生成器的重叠组整体淡出，交叉处只施加一次alpha，零时清除之前显示的像素。
    static func groupOpacity() throws -> [SourceShape] {
        let ellipse: [SourceShape] = [.ellipse(ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: 40, y: 40)),
            position: .init(constant: ScenePoint(x: 40, y: 50)))), ShapePropertyFixtures.fill()]
        let polygon: [SourceShape] = [.polyStar(ShapeGeneratorFixtures.polyStar(kind: .polygon, points: .init(constant: 4),
            position: .init(constant: ScenePoint(x: 60, y: 50)), outerRadius: .init(constant: 20))),
            ShapePropertyFixtures.fill(color: .init(constant: SceneColor(red: 0, green: 0, blue: 255)))]
        return [.group(ShapePropertyFixtures.group(opacity: try ShapePropertyFixtures.track(UInt8(255), UInt8(0))),
            [.group(ShapePropertyFixtures.group(), ellipse), .group(ShapePropertyFixtures.group(), polygon)])]
    }
}
