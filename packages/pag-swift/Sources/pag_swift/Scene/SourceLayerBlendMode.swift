/// 已取证并实现的图层整体混合模式；其它原始值在解码时继续明确拒绝。
enum SourceLayerBlendMode: UInt8, Sendable {
    /// 上游Normal，整层结果以预乘SrcOver写入背景。
    case normal = 0
    /// 上游Screen，整层先合成后以源One、目标OneMinusSrc写入背景。
    case screen = 2
}
