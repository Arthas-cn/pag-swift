import VideoToolbox

/// 内嵌 H.264 视频的会话选择策略；不影响外部 MP4/MOV 替换的 AVPlayer，也不保证并发容量或帧率。
public enum PAGVideoDecodingPolicy: String, Sendable, Codable {
    /// 默认兼容策略：真实设备必须硬解；模拟器沿用原有允许系统解码的例外。
    case hardwareRequired
    /// 优先允许可用硬解，由 VideoToolbox 选择解码路径；不保证系统存在软件回退。
    case automatic

    /// 是否向 VideoToolbox 提交硬解硬约束；模拟器保留旧 SDK 行为。
    var requiresHardware: Bool {
        #if targetEnvironment(simulator)
        // 模拟器没有与真实设备相同的硬解能力，不把此例外当作真机通过证据。
        false
        #else
        self == .hardwareRequired
        #endif
    }

    /// 单个会话只设置一个选键；Require 已隐含 Enable，不同时提交冲突配置。
    var specificationKey: CFString {
        requiresHardware ? kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
            : kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
    }
}

/// 内部视频 owner 的有界实际会话快照；统计系统查询结果，不从配置猜测是否硬解。
struct VideoDecoderDiagnostics: Sendable {
    /// 此 owner 固定的内嵌视频策略。
    let policy: PAGVideoDecodingPolicy
    /// 系统明确报告使用硬解的当前会话数。
    var hardwareSessions = 0
    /// 系统明确报告未使用硬解的当前会话数。
    var softwareSessions = 0
    /// 系统查询尚无结果的当前会话数，不能算入硬解或软件解码。
    var unknownSessions = 0
}
