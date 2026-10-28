/// 已取证的图层整体混合模式；各层种类是否可播仍由解码末端的能力门禁决定。
enum SourceLayerBlendMode: UInt8, Sendable {
    /// 上游Normal，整层结果以预乘SrcOver写入背景。
    case normal = 0
    /// 上游Screen，整层先合成后以源One、目标OneMinusSrc写入背景。
    case screen = 2
    /// 上游HardLight；仅完整Shape FastBlur结果及其Track Matte拥有者已接入可编程混合。
    case hardLight = 8
}
