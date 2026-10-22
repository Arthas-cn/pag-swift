/// 图层tag29/65的静态投影字段；只记录已证实的源值，具体子范围由渲染准备门禁决定。
struct SourceDropShadow: Sendable {
    /// 原始混合枚举字节；当前上游滤镜没有消费它，不能据此改变目标混合方式。
    let blendMode: UInt8
    /// 阴影RGB，未乘投影透明度。
    let color: SceneColor
    /// 投影自己的0...255透明度，不代替图层不透明度。
    let opacity: UInt8
    /// 源角度，位移按angle减180度解释。
    let angle: Double
    /// 沿源角度的像素距离；非正值使位移归零。
    let distance: Double
    /// 源投影尺寸；tag29为离散属性，tag65为普通标量属性。
    let size: Double
    /// V2扩散份额；tag29没有此字段，使用源默认零。
    let spread: Double
}
