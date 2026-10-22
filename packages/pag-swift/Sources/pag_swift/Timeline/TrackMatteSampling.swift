/// 一次所属合成帧的轨道遮罩源选择；保留源时间/变换，不冒充已生成的遮罩像素。
enum TrackMatteSelection: Sendable, Equatable {
    /// 文件值为None或首层无邻层引用；拥有者不安装轨道遮罩。
    case unmasked
    /// 引用存在，但源层在此帧不处于可见区间或自身变换不可见；保留正反向模式。
    case empty(mode: SourceTrackMatteType)
    /// 引用存在且源层在时间/变换上可见；实际图元还需后续内容准备。
    case source(TrackMatteSourceState)
}

/// 可见遮罩源的纯值身份；时间取源局部内容帧，变换按所属合成帧采样。
struct TrackMatteSourceState: Sendable, Equatable {
    /// 拥有者选择的alpha/luma及反向模式；不取源层自身的模式。
    let mode: SourceTrackMatteType
    /// 同一合成内的编码层下标，不受公开实例逆序影响。
    let layerIndex: Int
    /// 源层自己的内容时刻；素材和动态内容使用它。
    let time: LayerSampleTime
    /// 源层自身及控制父链的矩阵、自身透明度；不含拥有者的变换。
    let transform: EvaluatedTransform
}

/// 从编码邻层与所属合成帧选择遮罩源；不绘制内容或取得drawable。
enum TrackMatteSampling {
    /// 选择指定拥有者的源层、局部时刻和变换；sampler须属于同一合成帧。
    static func select(in composition: SourceComposition, topology: CompositionTopology,
                       ownerIndex: Int, frame: Int64,
                       sampler: inout LayerTransformSampler) throws -> TrackMatteSelection {
        try Task.checkCancellation()
        guard composition.layers.indices.contains(ownerIndex),
              topology.trackMatteSources.count == composition.layers.count else {
            throw SceneValidator.invalid("invalidTrackMatteTopology")
        }
        let mode = composition.layers[ownerIndex].trackMatte
        guard let sourceIndex = topology.trackMatteSources[ownerIndex] else {
            // 首层即使编码非None也没有相邻引用；上游直接跳过整个TrackMatte modifier。
            return .unmasked
        }
        guard mode != .none, sourceIndex == ownerIndex - 1 else {
            throw SceneValidator.invalid("invalidTrackMatteTopology")
        }
        let source = composition.layers[sourceIndex]
        guard let time = try SceneTiming.layer(source, at: frame, frameRate: composition.frameRate) else {
            // 引用存在而源层此时无内容，不等同于首层根本没有遮罩引用。
            return .empty(mode: mode)
        }
        let transform = try sampler.transform(for: sourceIndex)
        guard transform.opacity > 0, try transform.matrix.hasArea() else {
            // LayerCache::contentVisible在取图元前检查自身变换；父alpha和active不参与此判断。
            return .empty(mode: mode)
        }
        return .source(TrackMatteSourceState(mode: mode, layerIndex: sourceIndex,
                                             time: time, transform: transform))
    }
}
