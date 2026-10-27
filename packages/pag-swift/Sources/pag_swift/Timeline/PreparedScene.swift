/// 场景安装时建立的不可变求值资源；逐帧只引用资源，不重复编译静态几何。
struct PreparedScene: Sendable {
    /// 准备结果所属的编辑快照，后续编辑不会倒写此值。
    let composition: PAGComposition
    /// 每个静态源形状层的一份准备结果，展开实例共享同一个对象。
    let shapes: [SourceLayerReference: PreparedShapeLayer]
    /// 当前播放器的动态形状模板与有限采样缓存；纯静态场景为nil，不增加逐帧actor往返。
    let dynamicShapes: PreparedShapeStore?
    /// 每个静态源文本层的完整编辑资源，同一源层的展开实例共享。
    let texts: [SourceLayerReference: PreparedTextLayer]
    /// 静态形状准备的保守累计计费，复用时仍须满足新调用的资源限制。
    let estimatedShapeBytes: Int
    /// 原字号单行宽度确实超框的文本层；缺失表示保留PAG原始框排版。
    let marqueeWidths: [SourceLayerReference: Double]
    /// 每个图片实例的根素材时间轴；同文档编辑共享，不在逐帧构建祖先链或裁剪曲线。
    let imageTimes: PreparedImageTimes
    /// 源定义及原始层的Picture请求资格；仅为后续决策提供纯值，不表示已命中GPU快照。
    let pictureCandidates: PictureCandidates
    /// 定义级静态分析和候选构建的保守费用；同源编辑复用仍向新预算收费。
    let estimatedPictureAnalysisBytes: Int
    /// 当前播放准备结果独占的有界 bitmap 基底；同播放器编辑复用，纯矢量场景为 nil。
    let bitmaps: BitmapFrameStore?
    /// 当前播放器的内嵌视频会话与有界输入缓存；其他播放器不可复用该可变owner。
    let videos: VideoFrameStore?
    /// 编辑快照中的 GIF/WebP 按独立累计进度取帧，场景独占有界后台媒体 owner。
    let animatedImages: AnimatedImageFrameStore?
    /// 安装快照中允许使用的动图素材，播放采样复用此集合，不逐帧重建覆盖表。
    let animatedMaterialIDs: Set<DocumentIdentity>
    /// 动图素材的独立起点；只在场景安装前更新，之后随完整请求作为不可变值传送。
    var imageAnimationTimeline: ImageAnimationTimeline
    /// 编辑快照中的MP4/MOV按图层内容时间取帧，场景独占系统视频会话。
    let externalVideos: (any ExternalVideoSampling)?
    /// 可选替换素材的实例级终态诊断；同一准备快照只记首次失败。
    let optionalMediaFailures: OptionalMediaFailures
    /// 只有占位实际出现时才建立的辅助时钟，普通素材无额外逐帧状态。
    let placeholderClock: PresentationActivationClock?
    /// 只有滚动文字实际有效呈现后才建立起点；暂停与 seek 不改变已累计的播放时间。
    let marqueeClock: PresentationActivationClock?

    /// 后台准备完整场景资源；同一源存储的旧结果可复用静态几何，媒体采样器可供确定性验证注入。
    /// 取消不发布部分结果，生产调用不注入时建立每场景独占的视频owner。
    @concurrent static func prepare(_ composition: PAGComposition, reusing previous: PreparedScene? = nil,
                                     maximumBytes: Int = 64 * 1024 * 1024,
                                     videoDecodingPolicy: PAGVideoDecodingPolicy = .hardwareRequired,
                                     externalVideoSampler: (any ExternalVideoSampling)? = nil) async throws -> PreparedScene {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw PAGError.invalidArgument("maximumPreparedSceneBytes") }
        let reusable = previous?.composition.storage === composition.storage ? previous : nil
        var budget = FramePlanBudget(limit: maximumBytes, resourceName: "maximumPreparedSceneBytes")
        var shapes = reusable?.shapes ?? [:]
        var dynamicTemplates: [SourceLayerReference: [SourceShape]] = [:]
        var marqueeWidths: [SourceLayerReference: Double] = [:]
        if let reusable { try budget.reserve(stride: reusable.estimatedShapeBytes) }
        var shapeCost = budget.used
        var texts: [SourceLayerReference: PreparedTextLayer] = [:]
        for (compositionIndex, source) in composition.storage.compositions.enumerated() {
            for (layerIndex, layer) in source.layers.enumerated() {
                try Task.checkCancellation()
                let reference = SourceLayerReference(composition: compositionIndex, layer: layerIndex)
                switch layer.content {
                case .shape(let elements) where reusable == nil:
                    let before = budget.used
                    try budget.reserve(stride: 256)
                    if try ShapePreparation.isAnimated(elements, budget: &budget) {
                        dynamicTemplates[reference] = elements
                    } else {
                        shapes[reference] = try ShapePreparation.prepare(elements, budget: &budget)
                    }
                    shapeCost += budget.used - before
                case .text(let text):
                    try budget.reserve(stride: 256)
                    let slot = composition.storage.catalog.slots[reference]
                    let style = slot.flatMap { composition.edits.texts[$0] } ?? text.style
                    let overflow = slot.flatMap { composition.edits.textOverflows[$0] }
                    // 截断产物的 style.text 已是可见前缀；复用必须比较旧快照的完整输入，
                    // 不能用产物代替输入身份，也不应因无关编辑反复执行截断测宽和字形准备。
                    let previousStyle = slot.flatMap { reusable?.composition.edits.texts[$0] } ?? text.style
                    if let old = reusable?.texts[reference], previousStyle == style,
                       slot.flatMap({ reusable?.composition.edits.textOverflows[$0] }) == overflow {
                        try budget.reserve(stride: old.estimatedBytes)
                        texts[reference] = old
                        marqueeWidths[reference] = reusable?.marqueeWidths[reference]
                    } else {
                        if case .marquee? = overflow {
                            let result = try MarqueeTextPreparation.prepare(text, reference: reference,
                                style: style, budget: &budget)
                            texts[reference] = result.text
                            marqueeWidths[reference] = result.scrollingWidth
                        } else if case .truncate? = overflow {
                            texts[reference] = try TruncateTextPreparation.prepare(text, reference: reference,
                                style: style, budget: &budget)
                        } else {
                            texts[reference] = try TextPreparation.prepare(text, reference: reference,
                                style: style, budget: &budget)
                        }
                    }
                default: break
                }
            }
        }
        try Task.checkCancellation()
        let imageTimes: PreparedImageTimes
        if let reusable {
            try budget.reserve(stride: reusable.imageTimes.estimatedBytes)
            imageTimes = reusable.imageTimes
        } else {
            imageTimes = try PreparedImageTimes.prepare(composition.storage, budget: &budget)
        }
        let pictureCandidates: PictureCandidates
        let pictureCost: Int
        if let reusable {
            // 候选只依赖不变的源定义；文本编辑改变像素身份，但不会改变Auto请求资格。
            try budget.reserve(stride: reusable.estimatedPictureAnalysisBytes)
            pictureCandidates = reusable.pictureCandidates
            pictureCost = reusable.estimatedPictureAnalysisBytes
        } else {
            let startCost = budget.used
            let storage = composition.storage
            let ranges = try VectorStaticRanges.make(compositions: storage.compositions,
                                                      indices: storage.compositionIndices, budget: &budget)
            pictureCandidates = try PictureCandidates.make(compositions: storage.compositions,
                                                            indices: storage.compositionIndices,
                                                            vectorRanges: ranges, budget: &budget)
            pictureCost = budget.used - startCost
        }
        let hasBitmaps = composition.storage.compositions.contains { $0.bitmap != nil }
        let hasVideos = composition.storage.compositions.contains { $0.video != nil }
        // 静态几何可以复用，视频会话策略不同则必须建立新的媒体 owner，不能沿用旧硬约束。
        let videos: VideoFrameStore?
        if hasVideos {
            if let previousVideos = reusable?.videos, previousVideos.decodingPolicy == videoDecodingPolicy {
                // 同策略、同源编辑保留已有会话和帧缓存，避免无谓重建系统解码器。
                videos = previousVideos
            } else {
                // 首次安装或策略不同必须使用新的实例独占 owner。
                videos = VideoFrameStore(decodingPolicy: videoDecodingPolicy)
            }
        } else {
            // 纯矢量/位图内容不创建任何内嵌视频解码 owner。
            videos = nil
        }
        let animatedMaterialIDs = Set((Array(composition.edits.images.values) + Array(composition.edits.placeholders.values))
            .compactMap { $0.animation?.identity })
        let hasExternalVideos = composition.edits.images.values.contains { $0.video != nil }
        let retainedPlaceholders = Set(composition.edits.placeholders.compactMap { entry -> PAGLayerID? in
            guard let old = reusable?.composition.edits.placeholders[entry.key],
                  old.kind == entry.value.kind, old.storage.identity == entry.value.storage.identity else { return nil }
            return entry.key
        })
        let hasMarquee = !marqueeWidths.isEmpty
        let retainedMarquees = Set(composition.storage.instances.compactMap { instance -> PAGLayerID? in
            let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
            guard marqueeWidths[reference] != nil, let old = reusable,
                  let slot = composition.storage.catalog.slots[reference],
                  old.composition.edits.textOverflows[slot] == composition.edits.textOverflows[slot],
                  old.composition.edits.texts[slot] == composition.edits.texts[slot] else { return nil }
            return instance.id
        })
        let dynamicShapes = try reusable?.dynamicShapes ?? (dynamicTemplates.isEmpty ? nil : PreparedShapeStore(templates: dynamicTemplates))
        let imageAnimationTimeline = try ImageAnimationTimeline(composition, reusing: reusable, budget: &budget)
        // 最后一次分析或同源复用收费后仍可能被撤销；完整场景只有在最终取消检查后才发布。
        try Task.checkCancellation()
        return PreparedScene(composition: composition, shapes: shapes, dynamicShapes: dynamicShapes,
                             texts: texts, estimatedShapeBytes: shapeCost, marqueeWidths: marqueeWidths,
                             imageTimes: imageTimes, pictureCandidates: pictureCandidates,
                             estimatedPictureAnalysisBytes: pictureCost,
                             bitmaps: hasBitmaps ? reusable?.bitmaps ?? BitmapFrameStore() : nil,
                             videos: videos,
                             animatedImages: !animatedMaterialIDs.isEmpty ?
                                reusable?.animatedImages ?? AnimatedImageFrameStore() : nil,
                             animatedMaterialIDs: animatedMaterialIDs,
                             imageAnimationTimeline: imageAnimationTimeline,
                             externalVideos: hasExternalVideos ?
                                externalVideoSampler ?? reusable?.externalVideos ?? ExternalVideoFrameStore() : nil,
                             optionalMediaFailures: OptionalMediaFailures(),
                             placeholderClock: composition.edits.placeholders.isEmpty ? nil :
                                reusable?.placeholderClock?.retaining(retainedPlaceholders) ?? PresentationActivationClock(),
                             marqueeClock: hasMarquee ?
                                reusable?.marqueeClock?.retaining(retainedMarquees) ?? PresentationActivationClock() : nil)
    }
}
