/// 限制文件读取和解码工作量；这些值是库策略，不是 PAG 格式字段。
public struct PAGLoadLimits: Sendable, Hashable {
    /// 单次读取允许的原始文件字节数上限，必须为正。
    public let maximumFileBytes: Int
    /// 解码展开数据允许占用的字节数上限，必须为正。
    public let maximumDecodedBytes: Int
    /// 合成引用链的最大深度，必须为正。
    public let maximumCompositionDepth: Int
    /// 源图层记录数与展开实例数各自的上限，必须为正。
    public let maximumLayerCount: Int

    /// 创建正数资源预算；任一非正参数抛出同名 invalidArgument。
    public init(
        maximumFileBytes: Int = 268_435_456,
        maximumDecodedBytes: Int = 536_870_912,
        maximumCompositionDepth: Int = 64,
        maximumLayerCount: Int = 100_000
    ) throws {
        for (name, value) in [
            ("maximumFileBytes", maximumFileBytes),
            ("maximumDecodedBytes", maximumDecodedBytes),
            ("maximumCompositionDepth", maximumCompositionDepth),
            ("maximumLayerCount", maximumLayerCount),
        ] {
            guard value > 0 else { throw PAGError.invalidArgument(name) }
        }
        self.maximumFileBytes = maximumFileBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumCompositionDepth = maximumCompositionDepth
        self.maximumLayerCount = maximumLayerCount
    }

    /// 默认预算，与公开初始化器的默认参数一致。
    public static let standard = PAGLoadLimits(standardDefaults: ())

    /// 仅构造固定正数默认预算，避免公开静态默认值需要强制解包错误。
    private init(standardDefaults: Void) {
        maximumFileBytes = 268_435_456
        maximumDecodedBytes = 536_870_912
        maximumCompositionDepth = 64
        maximumLayerCount = 100_000
    }
}
