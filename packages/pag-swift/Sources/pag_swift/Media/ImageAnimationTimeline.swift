/// 已安装动图的独立播放起点；这是场景值的一部分，不调度任务、不持有解码器。
struct ImageAnimationTimeline: Sendable {
    /// 当前编辑快照里确实使用动画的实例，包含暂时不在 PAG 可见区间的实例。
    private let instances: Set<PAGLayerID>
    /// 素材安装时的累计图片播放微秒；新素材在正式安装前暂不设起点。
    private var starts: [PAGLayerID: PAGTime]

    /// 同文档只保留相同素材的起点；不同 tag 换素材互不重置，分配先计入场景预算。
    init(_ composition: PAGComposition, reusing previous: PreparedScene?, budget: inout FramePlanBudget) throws {
        let animated = composition.edits.images.filter { $0.value.animation != nil }
        try budget.reserve(count: animated.count, stride: 128)
        instances = Set(animated.keys)
        var starts: [PAGLayerID: PAGTime] = [:]
        for (id, image) in animated {
            if previous?.composition.edits.images[id]?.animation?.identity == image.animation?.identity,
               let start = previous?.imageAnimationTimeline.starts[id] {
                starts[id] = start
            }
        }
        self.starts = starts
    }

    /// 场景原子安装时给新素材建立起点；重装文档须显式 reset，普通编辑仅填充新素材。
    mutating func install(at time: PAGTime, reset: Bool = false) {
        if reset { starts.removeAll(keepingCapacity: true) }
        for id in instances where starts[id] == nil { starts[id] = PAGTime(microseconds: max(0, time.microseconds)) }
    }

    /// 返回独立进度；直接帧计划测试未经过播放器安装时以零为起点，根帧位置不参与计算。
    func elapsed(for id: PAGLayerID, at time: PAGTime) -> PAGTime {
        let start = starts[id]?.microseconds ?? 0
        guard time.microseconds >= start else { return .zero }
        return PAGTime(microseconds: time.microseconds - start)
    }
}
