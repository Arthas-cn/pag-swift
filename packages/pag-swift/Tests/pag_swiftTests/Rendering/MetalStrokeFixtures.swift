import Foundation
@testable import pag_swift

/// 生产显示owner的三类回归输入，不通过整数或Bool把新增生成器和旧属性混为同一分支。
enum MetalShapeFixtureKind: Sendable, CaseIterable {
    /// 已支持的普通描边，包含真实文件回归。
    case stroke
    /// 已开放的组、矩形与填充属性动画。
    case properties
    /// 已开放的Ellipse/PolyStar，包含纯语义显示、迟到门禁与完整文件回归。
    case generators

    /// 已完成正式解码和三时刻Metal准备的文件；遇到后续未支持内容的文件不能列入。
    var completeFiles: [String] {
        switch self {
        case .stroke: ["0.pag", "list/0.pag", "list/12.pag", "list/13.pag", "list/15.pag", "list/19.pag"]
        case .properties: ["list/14.pag", "list/16.pag", "list/18.pag", "list/9.pag"]
        case .generators: ["TextDirection.pag"]
        }
    }

    /// 各类分别提供paint变化、几何变化和组alpha场景，三者参与完全相同的生产提交门禁。
    func elements() throws -> (color: [SourceShape], geometry: [SourceShape], group: [SourceShape]) {
        switch self {
        case .stroke:
            return try (MetalStrokeFixtures.animatedColor(), MetalStrokeFixtures.animatedWidth(), MetalStrokeFixtures.mixedGroup())
        case .properties:
            return try (MetalShapePropertyFixtures.color(), MetalShapePropertyFixtures.movingGroup(), MetalShapePropertyFixtures.groupOpacity())
        case .generators:
            return try (MetalShapeGeneratorFixtures.color(polyStar: false), MetalShapeGeneratorFixtures.starRadii(),
                        MetalShapeGeneratorFixtures.groupOpacity())
        }
    }
}

/// 描边显示门禁的纯语义场景；不构造PAG字节，整文件支持另由真实资源验收。
enum MetalStrokeFixtures {
    /// 两条长30、宽10的相交线共用一次paint，交叉部分不能重复叠加alpha。
    static func crossing(_ stroke: SourceStroke? = nil) throws -> [SourceShape] {
        let horizontal = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 10, y: 25), ScenePoint(x: 40, y: 25)])
        let vertical = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 25, y: 10), ScenePoint(x: 25, y: 40)])
        return [.path(.init(constant: horizontal)), .path(.init(constant: vertical)),
                .stroke(stroke ?? StrokeFixtures.make(width: .init(constant: 10),
                    color: .init(constant: SceneColor(red: 255, green: 0, blue: 0)), opacity: .init(constant: 128)))]
    }

    /// Fill Below、红Stroke Below和蓝Stroke Above包在半透明组内，三种颜色应依次覆盖。
    static func mixedGroup() -> [SourceShape] {
        let rectangle = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
            position: ScenePoint(x: 40, y: 40), roundness: 0)
        let red = StrokeFixtures.make(width: .init(constant: 12),
            color: .init(constant: SceneColor(red: 255, green: 0, blue: 0)))
        let blue = StrokeFixtures.make(width: .init(constant: 4),
            color: .init(constant: SceneColor(red: 0, green: 0, blue: 255)), order: .abovePrevious)
        return [.group(StrokeShapeFixtures.transform(opacity: 128), [rectangle, .stroke(red),
            .fill(color: SceneColor(red: 0, green: 255, blue: 0), opacity: 255), .stroke(blue)])]
    }

    /// 只有颜色和alpha变化的描边模板；完整几何和GPU输入应跨源帧复用。
    static func animatedColor() throws -> [SourceShape] {
        try crossing(StrokeFixtures.make(width: .init(constant: 10),
            color: StrokeFixtures.track(SceneColor(red: 255, green: 0, blue: 0), SceneColor(red: 0, green: 0, blue: 255)),
            opacity: StrokeFixtures.track(UInt8(128), UInt8(255))))
    }

    /// 宽度在0...10帧从10变为20，交叉面积从500变为800，需要新网格。
    static func animatedWidth() throws -> [SourceShape] {
        try crossing(StrokeFixtures.make(width: StrokeFixtures.track(10.0, 20),
            color: .init(constant: SceneColor(red: 255, green: 0, blue: 0)), opacity: .init(constant: 128)))
    }

    /// 将源层直接放在100×100根合成的0...29帧，避免precomp起点隐藏首帧。
    static func scene(_ elements: [SourceShape]) async throws -> PreparedScene {
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(elements))])
        return try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
    }

    /// 为真实owner生成有效播放许可；调用者可撤销该gate来模拟替换而不改目标尺寸。
    static func request(_ scene: PreparedScene, epoch: UUID, frame: Int64 = 0,
                        gate: PlaybackSubmissionGate = PlaybackSubmissionGate(), revision: UInt64 = 1) throws -> PlaybackFrameRequest {
        let token = PlaybackRequestToken(documentID: scene.composition.storage.identity, compositionRevision: revision,
            playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
        gate.allow(token)
        return PlaybackFrameRequest(scene: scene, time: try SceneValidator.time(frame: frame, rate: scene.composition.frameRate),
            scaleMode: .none, token: token, gate: gate, endsPlayback: false)
    }
}
