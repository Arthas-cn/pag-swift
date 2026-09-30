/// 根请求的已量化采样时刻；请求微秒与将呈现的帧时间分别保存。
struct RootSampleTime: Sendable, Equatable {
    /// 钳到根合法微秒区间后的请求位置。
    let requestedTime: PAGTime
    /// 根合成的合法帧号，范围为 0..<durationFrames。
    let frame: Int64
    /// 该帧的 ceil 代表微秒，只能在有效显示提交后成为 presentedTime。
    let representedTime: PAGTime
}

/// 可见图层的内容时刻；属性仍在所属合成时间轴采样，不使用 contentFrame。
struct LayerSampleTime: Sendable, Equatable {
    /// 相对图层 startFrame 的帧，范围为 0..<durationFrames。
    let contentFrame: Int64
    /// 以上述内容帧和所属合成帧率换算的非负微秒，供媒体素材使用。
    let contentTime: PAGTime
}

/// 已验证源场景的时间映射；不受编辑状态或缓存命中影响，不推进播放器。
enum SceneTiming {
    /// 根微秒先钳制再 floor 量化，返回请求与显示时刻；无效源时基报告文件错误。
    static func root(at time: PAGTime, in storage: DocumentStorage) throws -> RootSampleTime {
        let source = storage.compositions[storage.rootIndex]
        let request = try TimeMapping.clamped(time, duration: storage.duration)
        let selected: Int64
        do { selected = try TimeMapping.frame(at: request, frameRate: source.frameRate) }
        catch { throw SceneValidator.invalid("unrepresentableCompositionTime") }
        // 微秒时长采用 ceil，或极端帧率造成浮点边界误差时，帧仍不能越过源末端。
        let frame = min(max(selected, 0), source.durationFrames - 1)
        return RootSampleTime(requestedTime: request, frame: frame,
                              representedTime: try SceneValidator.time(frame: frame, rate: source.frameRate))
    }

    /// 以右开可见区间选择内容帧；区间外返回 nil，不进行可能溢出的相对减法。
    static func layer(_ source: SourceLayer, at frame: Int64, frameRate: Double) throws -> LayerSampleTime? {
        let end = source.startFrame.addingReportingOverflow(source.durationFrames)
        guard source.durationFrames > 0, !end.overflow else { throw SceneValidator.invalid("invalidFrameRange") }
        guard frame >= source.startFrame, frame < end.partialValue else { return nil }
        // 已处于正且可表示的区间内，差值必定位于 0..<durationFrames。
        let content = frame - source.startFrame
        return LayerSampleTime(contentFrame: content, contentTime: try SceneValidator.time(frame: content, rate: frameRate))
    }

    /// 按源码 Float 帧率比与 roundf 映射预合成，并钳到子首末帧；起点不是可见起点。
    static func precomposition(at parentFrame: Int64, startFrame: Int64, parentRate: Double,
                               child: SourceComposition) throws -> Int64 {
        let delta = parentFrame.subtractingReportingOverflow(startFrame)
        let parent = Float(parentRate)
        let rate = Float(child.frameRate)
        guard !delta.overflow, parent.isFinite, parent > 0, rate.isFinite, rate > 0,
              child.durationFrames > 0 else { throw SceneValidator.invalid("unrepresentableCompositionTime") }
        // 上游先用两个 Float 帧率求比，再乘 Float 帧差；不能改为 Double 比后一次转换。
        let ratio = rate / parent
        let value = (Float(delta.partialValue) * ratio).rounded(.toNearestOrAwayFromZero)
        guard ratio.isFinite, ratio > 0, let frame = Int64(exactly: value) else {
            throw SceneValidator.invalid("unrepresentableCompositionTime")
        }
        return min(max(frame, 0), child.durationFrames - 1)
    }
}
