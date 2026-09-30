@testable import pag_swift

/// 路径共同计划和GPU测试使用的纯语义图；真实路径片段仍经正式内部读取，不编码假PAG文件。
enum ShapePathFixtures {
    /// 以给定宽度创建起点(10,10)的方形路径；反向用于nonzero孔洞测试。
    static func square(_ width: Double, reversed: Bool = false) throws -> SourcePath {
        let points = [ScenePoint(x: 10, y: 10), ScenePoint(x: 10 + width, y: 10),
                      ScenePoint(x: 10 + width, y: 10 + width), ScenePoint(x: 10, y: 10 + width)]
        return try SourcePath(verbs: [.move, .line, .line, .line, .close], points: reversed ? points.reversed() : points)
    }

    /// 在合成0...20帧由10边长变为30边长，颜色填充保持静态，便于独立面积断言。
    static func track() throws -> SourceProperty<SourcePath> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 20,
            startValue: square(10), endValue: square(30), easing: .linear, spatialCurve: nil)])
    }

    /// 一条路径后跟红色fill，可作为静态或动态源层模板。
    static func elements(_ property: SourceProperty<SourcePath>) -> [SourceShape] {
        [.path(property), .fill(color: .defaultFill, opacity: 255)]
    }

    /// 同一child被多个precomposition引用，offset影响源采样帧；position把真实字段的局部坐标放入测试视口。
    static func file(_ property: SourceProperty<SourcePath>, offsets: [Int64] = [0, 5], start: Int64 = 0,
                     position: ScenePoint = .zero) throws -> PAGFile {
        let transform = SourceShapeTransform(base: SourceTransform(anchor: .zero, position: position,
            scale: .one, rotation: 0, opacity: 255), skew: 0, skewAxis: 0)
        let shapes: [SourceShape] = [.group(transform, elements(property))]
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, start: start,
            duration: 30 - start, content: .shape(shapes))])
        let layers = offsets.enumerated().map { index, offset in
            SceneFixtures.layer(UInt32(index + 10), content: .precomposition(id: 1, startFrame: offset))
        }
        let root = try SceneFixtures.composition(2, layers: layers)
        return try SceneFixtures.build([child, root])
    }

    /// 生成根指定帧的计划，时间取整和显示尺寸由同一库入口完成。
    static func plan(_ scene: PreparedScene, at frame: Int64) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: frame, rate: 30),
            targetSize: scene.composition.size, scale: 1, mode: .none)
    }

    /// 提取计划中的全部实际shape命令，不混入组边界或其他图层种类。
    static func fills(_ frame: PreparedFrame) -> [FrameShape] {
        frame.plan.commands.compactMap { if case .shape(let shape) = $0 { shape } else { nil } }
    }
}
