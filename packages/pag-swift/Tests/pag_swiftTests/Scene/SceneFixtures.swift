import Foundation
@testable import pag_swift

/// 直接创建语义图以测试引用算法；这些值不冒充真实 PAG 字节夹具。
enum SceneFixtures {
    /// 无动画的恒等变换，可作为控制层或预合成的有效基础属性。
    static let transform = SourceTransform(anchor: .zero, position: .zero, scale: .one, rotation: 0, opacity: 255)

    /// 创建语义源层，允许测试显式传入无效引用或时长以验证失败路径。
    static func layer(_ id: UInt32, name: String = "shared", parent: UInt32? = nil,
                      start: Int64 = 0, duration: Int64 = 30,
                      active: Bool = true, transform: SourceTransformProperties? = nil,
                      content: SourceLayerContent = .null) -> SourceLayer {
        SourceLayer(id: id, name: name, parentID: parent, startFrame: start, durationFrames: duration,
                    isActive: active, transform: transform ?? SourceTransformProperties(constant: Self.transform), content: content)
    }

    /// 创建 30 fps 的语义合成，layers 始终表示编码顺序。
    static func composition(_ id: UInt32, layers: [SourceLayer], rate: Double = 30) throws -> SourceComposition {
        SourceComposition(id: id, size: try PAGSize(width: 100, height: 100), durationFrames: 30,
                          frameRate: rate, background: SceneColor(red: 0, green: 0, blue: 0), layers: layers)
    }

    /// 使用固定测试身份验证语义图；不调用文件解码器或声称其字节有效。
    static func build(_ compositions: [SourceComposition], limits: PAGLoadLimits = .standard,
                      resources: SourceResources = SourceResources()) throws -> PAGFile {
        var budget = DecodeBudget(limit: limits.maximumDecodedBytes)
        return try SceneValidator.build(compositions: compositions, identity: DocumentIdentity(data: Data("semantic fixture".utf8)),
                                        limits: limits, budget: &budget, resources: resources)
    }
}
