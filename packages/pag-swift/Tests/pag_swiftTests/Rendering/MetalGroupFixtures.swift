import Foundation
@testable import pag_swift

/// 手工语义计划只验证渲染合同，不构造或声称支持新的PAG字节布局。
enum MetalGroupFixtures {
    /// 测试图元共用的合法内部实例身份，不参与字节解码。
    static var layer: PAGLayerID {
        get throws { try PAGLayerID(document: DocumentIdentity(data: Data("metal groups".utf8)), path: [1]) }
    }

    /// 在100×100显示中包裹命令；资源表为空，只供纯色组测试。
    static func frame(_ commands: [FrameCommand]) -> PreparedFrame {
        PreparedFrame(plan: FramePlan(time: RootSampleTime(requestedTime: .zero, frame: 0, representedTime: .zero),
                                       targetBounds: DisplayRect(x: 0, y: 0, width: 100, height: 100), commands: commands),
                      images: [:], shapes: [:], texts: [:])
    }

    /// 固定20×20矩形，平移与自身alpha可单独变化以区分组alpha。
    static func solid(x: Double = 10, y: Double = 20, alpha: Double = 1) throws -> FrameCommand {
        .solid(FrameSolid(layerID: try layer, size: try PAGSize(width: 20, height: 20),
                          color: SceneColor(red: 255, green: 0, blue: 0), matrix: try .translation(x: x, y: y), opacity: alpha))
    }

    /// 不增加裁剪的整体alpha边界，数组内的绘制必须先组合再应用该值。
    static func group(_ alpha: Double, _ children: [FrameCommand]) throws -> [FrameCommand] {
        [.beginOpacityGroup(FrameOpacityGroup(layerID: try layer, opacity: alpha))] + children + [.endOpacityGroup]
    }

    /// 实际owner提交的两级重叠透明组，使用验证后的语义图，避免伪造文件格式。
    static func composition() throws -> PAGComposition {
        let size = try PAGSize(width: 60, height: 60)
        let shifted = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: ScenePoint(x: 20, y: 20),
                                                                          scale: .one, rotation: 0, opacity: 255))
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0))),
            SceneFixtures.layer(2, transform: shifted, content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: ScenePoint(x: 10, y: 10),
                                                                       scale: .one, rotation: 0, opacity: 128))
        let middle = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(3, transform: half, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(4, content: .solid(size: size, color: SceneColor(red: 0, green: 255, blue: 0)))
        ])
        let root = try SceneFixtures.composition(3, layers: [SceneFixtures.layer(5, transform: half,
                                                                               content: .precomposition(id: 2, startFrame: 0))])
        return try SceneFixtures.build([child, middle, root]).composition
    }
}
