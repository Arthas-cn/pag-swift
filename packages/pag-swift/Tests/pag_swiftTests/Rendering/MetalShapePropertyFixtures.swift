@testable import pag_swift

/// 新形状轨道显示验收的纯语义场景；真实文件是否完整支持另由正式入口后的资源分类决定。
enum MetalShapePropertyFixtures {
    /// 固定矩形从半透明红变为不透明蓝，几何和GPU输入应保持身份。
    static func color() throws -> [SourceShape] {
        [ShapePropertyFixtures.rectangle(size: .init(constant: ScenePoint(x: 40, y: 40)),
            position: .init(constant: ScenePoint(x: 40, y: 40))),
         ShapePropertyFixtures.fill(color: try ShapePropertyFixtures.track(.defaultFill, SceneColor(red: 0, green: 0, blue: 255)),
            opacity: try ShapePropertyFixtures.track(UInt8(128), UInt8(255)))]
    }

    /// 两个相交子组共同从不透明淡出，交叉必须只应用一次外组alpha，零时清空旧画面。
    static func groupOpacity() throws -> [SourceShape] {
        let red: [SourceShape] = [ShapePropertyFixtures.rectangle(size: .init(constant: ScenePoint(x: 30, y: 30)),
            position: .init(constant: ScenePoint(x: 35, y: 35))), ShapePropertyFixtures.fill()]
        let blue: [SourceShape] = [ShapePropertyFixtures.rectangle(size: .init(constant: ScenePoint(x: 30, y: 30)),
            position: .init(constant: ScenePoint(x: 50, y: 35))),
            ShapePropertyFixtures.fill(color: .init(constant: SceneColor(red: 0, green: 0, blue: 255)))]
        return [.group(ShapePropertyFixtures.group(opacity: try ShapePropertyFixtures.track(UInt8(255), UInt8(0))),
            [.group(ShapePropertyFixtures.group(), red), .group(ShapePropertyFixtures.group(), blue)])]
    }

    /// 组位置从0移动到x40；两个远离边界的像素应交换覆盖，返回首帧时恢复原位置。
    static func movingGroup() throws -> [SourceShape] {
        [.group(ShapePropertyFixtures.group(position: try ShapePropertyFixtures.track(.zero, ScenePoint(x: 40, y: 0))),
            [ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 30, y: 30))),
             ShapePropertyFixtures.fill()])]
    }

    /// 矩形从20扩大到40并增加圆角；扩出的边中点变红，角内探针仍应透明。
    static func rectangle() throws -> [SourceShape] {
        [ShapePropertyFixtures.rectangle(size: try ShapePropertyFixtures.track(ScenePoint(x: 20, y: 20), ScenePoint(x: 40, y: 40)),
            position: .init(constant: ScenePoint(x: 40, y: 40)), roundness: try ShapePropertyFixtures.track(0.0, 8)),
         ShapePropertyFixtures.fill()]
    }
}
