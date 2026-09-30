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
    /// 每个图片实例的根素材时间轴；同文档编辑共享，不在逐帧构建祖先链或裁剪曲线。
    let imageTimes: PreparedImageTimes
    /// 当前播放准备结果独占的有界 bitmap 基底；同播放器编辑复用，纯矢量场景为 nil。
    let bitmaps: BitmapFrameStore?
    /// 当前播放器的内嵌视频会话与有界输入缓存；其他播放器不可复用该可变owner。
    let videos: VideoFrameStore?

    /// 后台准备完整场景资源；同一源存储的旧结果可显式复用静态几何，取消不发布部分结果。
    @concurrent static func prepare(_ composition: PAGComposition, reusing previous: PreparedScene? = nil,
                                     maximumBytes: Int = 64 * 1024 * 1024) async throws -> PreparedScene {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw PAGError.invalidArgument("maximumPreparedSceneBytes") }
        let reusable = previous?.composition.storage === composition.storage ? previous : nil
        var budget = FramePlanBudget(limit: maximumBytes, resourceName: "maximumPreparedSceneBytes")
        var shapes = reusable?.shapes ?? [:]
        var dynamicTemplates: [SourceLayerReference: [SourceShape]] = [:]
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
                    // 同文档不代表同文字；完整样式匹配后才能复用，隐藏也不能跳过未支持文本语义。
                    if let old = reusable?.texts[reference], old.style == style {
                        try budget.reserve(stride: old.estimatedBytes)
                        texts[reference] = old
                    } else {
                        texts[reference] = try TextPreparation.prepare(text, style: style, budget: &budget)
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
        let hasBitmaps = composition.storage.compositions.contains { $0.bitmap != nil }
        let hasVideos = composition.storage.compositions.contains { $0.video != nil }
        let dynamicShapes = try reusable?.dynamicShapes ?? (dynamicTemplates.isEmpty ? nil : PreparedShapeStore(templates: dynamicTemplates))
        return PreparedScene(composition: composition, shapes: shapes, dynamicShapes: dynamicShapes,
                             texts: texts, estimatedShapeBytes: shapeCost,
                             imageTimes: imageTimes,
                             bitmaps: hasBitmaps ? reusable?.bitmaps ?? BitmapFrameStore() : nil,
                             videos: hasVideos ? reusable?.videos ?? VideoFrameStore() : nil)
    }
}
