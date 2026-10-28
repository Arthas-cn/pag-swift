/// 可跨 actor 传输的领域错误；主动取消另外传播 CancellationError。
public enum PAGError: Error, Sendable, Equatable {
    /// 参数不满足合同；关联值为参数名，不用于承载底层对象。
    case invalidArgument(String)
    /// 输入 URL 不是库允许的本地文件来源。
    case unsupportedURL
    /// 本地读取失败；保留系统错误域与数值编码。
    case ioFailure(domain: String, code: Int)
    /// 读取或素材会话期间来源发生变化，不能继续复用旧结果。
    case sourceChanged
    /// 缺少所需字节；offset 是检测到截断的位置。
    case truncatedData(offset: Int)
    /// 容器或内容非法；reason 用于诊断，offset 未知时为 nil。
    case invalidFile(reason: String, offset: Int?)
    /// 输入文件版本尚未实现；关联值为读取到的版本号。
    case unsupportedVersion(Int)
    /// 影响内容的功能尚未完整支持；关联值为功能标识。
    case unsupportedFeature(String)
    /// 请求超过显式资源预算；关联值说明超出的预算类别。
    case resourceLimitExceeded(String)
    /// 文本或图像索引不在文件允许编辑的集合中。
    case invalidEditableIndex(Int)
    /// 图层实例身份不属于当前文档。
    case invalidLayer
    /// 指定名称没有匹配的图像层；关联值保留原始名称。
    case noMatchingImageLayer(String)
    /// 系统缺少动画素材所需的逐帧能力；关联值说明格式或能力。
    case unsupportedAnimatedImage(String)
    /// 素材解码或视频轨校验失败；关联值为诊断信息。
    case mediaFailure(String)
    /// 需要合成的操作发生在安装合成之前。
    case missingComposition
    /// 需要显示目标的操作发生在绑定表面之前。
    case missingSurface
    /// 该显示表面已被另一个播放器占用。
    case surfaceInUse
    /// Metal 设备或必需图形能力不可用。
    case graphicsUnavailable
    /// GPU 编码或执行失败；关联值为诊断信息。
    case renderingFailure(String)
}
