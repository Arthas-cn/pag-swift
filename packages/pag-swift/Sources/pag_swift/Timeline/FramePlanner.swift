/// 非主 actor 的共同场景求值入口；消费一次性准备资源，输出已支持内容的完整计划。
enum FramePlanner {
    /// 从已准备快照生成计划；不重建静态路径或触碰 drawable，取消保留 CancellationError。
    @concurrent static func prepare(_ scene: PreparedScene, at time: PAGTime,
                                     targetSize: PAGSize, scale: Double, mode: PAGScaleMode,
                                     maximumBytes: Int = 64 * 1024 * 1024) async throws -> PreparedFrame {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw PAGError.invalidArgument("maximumFramePlanBytes") }
        let composition = scene.composition
        let sample = try SceneTiming.root(at: time, in: composition.storage)
        let display = try DisplayTransform(contentSize: composition.size, targetSize: targetSize, scale: scale, mode: mode)
        var builder = FramePlanBuilder(scene: scene, time: sample, display: display,
                                       budget: FramePlanBudget(limit: maximumBytes))
        return try await builder.build()
    }
}

/// 一次调用独占的计划构建状态；所有增长在预算检查后执行，不进入公开场景快照。
private struct FramePlanBuilder {
    /// 此次安装的不可变准备结果，几何和快照属于同一文档。
    let scene: PreparedScene
    /// 此次编辑快照，O(1) 共享源资源和覆盖表。
    private var composition: PAGComposition { scene.composition }
    /// 已完成根量化的采样时刻。
    let time: RootSampleTime
    /// 根逻辑坐标到目标像素的共同显示变换。
    let display: DisplayTransform
    /// 命令、输入表、遍历和矩阵缓存的累计保守预算。
    var budget: FramePlanBudget
    /// 已生成的严格绘制顺序，组命令始终成对。
    private var commands: [FrameCommand] = []
    /// 当前计划使用的输入保活表，不持有 GPU 或 ImageIO 对象。
    private var images: [DocumentIdentity: PAGImage] = [:]
    /// 当前计划需要的共享几何对象，按源身份去重，不复制其轮廓。
    private var shapes: [ShapeGeometryID: ShapeGeometry] = [:]
    /// 本次计划已取得的动态源帧，防止owner四条LRU淘汰后同一帧表又重建相同采样。
    private var shapeSamples: [ShapeSampleKey: PreparedShapeLayer] = [:]
    /// 本次计划需要的文本资源；按准备代数去重，不在每帧重新整形。
    private var texts: [TextResourceID: PreparedTextLayer] = [:]
    /// 按实际PTS去重的输入交接槽；内部锁只交换引用，裸CV帧不进入构建器。
    private var videos: [VideoFrameID: VideoFrameTransfer] = [:]
    /// 显式预合成遍历栈，避免深场景的递归调用栈增长。
    private var stack: [PlanningContext] = []

    /// 接受经验证的快照、请求和显示变换；初始不分配逐层工作数组。
    init(scene: PreparedScene, time: RootSampleTime, display: DisplayTransform, budget: FramePlanBudget) {
        self.scene = scene
        self.time = time
        self.display = display
        self.budget = budget
    }

    /// 完整迭代所有可见实例并生成命令；任何失败丢弃 builder，调用方收不到部分内容。
    mutating func build() async throws -> PreparedFrame {
        let storage = composition.storage
        try await enter(compositionIndex: storage.rootIndex, instances: storage.rootLayers, frame: time.frame,
                  matrix: SceneAffine(display: display), opacity: 1, layerID: nil)
        while !stack.isEmpty {
            try Task.checkCancellation()
            let index = stack.count - 1
            if stack[index].nextInstance == stack[index].instances.count {
                try append(.endGroup)
                stack.removeLast()
                continue
            }
            let instanceIndex = stack[index].instances[stack[index].nextInstance]
            stack[index].nextInstance += 1
            let instance = storage.instances[instanceIndex]
            let source = storage.compositions[instance.compositionIndex]
            let layer = source.layers[instance.layerIndex]
            guard composition.edits.visibility[instance.id] ?? layer.isActive else { continue }
            // null 仍可被 sampler 当作控制父层，但本身没有内容或包含子树。
            if case .null = layer.content { continue }
            let frame = stack[index].frame
            guard let localTime = try SceneTiming.layer(layer, at: frame, frameRate: source.frameRate) else { continue }
            let transform = try stack[index].sampler.transform(for: instance.layerIndex)
            guard transform.opacity > 0, try transform.matrix.hasArea() else { continue }
            let matrix = try transform.matrix.following(stack[index].matrix)
            guard try matrix.hasArea() else { continue }
            switch layer.content {
            case let .solid(size, color):
                try append(.solid(FrameSolid(layerID: instance.id, size: size, color: color, matrix: matrix,
                                              opacity: transform.opacity)))
            case .image(let id):
                try image(resourceID: id, instance: instance, matrix: matrix,
                          opacity: transform.opacity, contentTime: localTime.contentTime)
            case let .precomposition(id, startFrame):
                guard let childIndex = storage.compositionIndices[id] else {
                    throw SceneValidator.invalid("missingCompositionReference")
                }
                let child = storage.compositions[childIndex]
                let childFrame = try SceneTiming.precomposition(at: frame, startFrame: startFrame,
                                                                 parentRate: source.frameRate, child: child)
                try await enter(compositionIndex: childIndex, instances: instance.children, frame: childFrame,
                          matrix: matrix, opacity: transform.opacity, layerID: instance.id)
            case .null: break
            case .shape:
                try await shape(instance: instance, frame: frame, matrix: matrix, opacity: transform.opacity)
            case .text:
                try text(instance: instance, matrix: matrix, opacity: transform.opacity)
            }
        }
        try Task.checkCancellation()
        return PreparedFrame(plan: FramePlan(time: time, targetBounds: display.clipRect, commands: commands),
                             images: images, shapes: shapes, texts: texts, videos: videos)
    }

    /// 进入一个根/预合成实例；保存整体透明度，子图元不单独乘入此 alpha。
    private mutating func enter(compositionIndex: Int, instances: [Int], frame: Int64,
                                matrix: SceneAffine, opacity: Double, layerID: PAGLayerID?) async throws {
        let storage = composition.storage
        let source = storage.compositions[compositionIndex]
        try budget.reserve(stride: 512)
        try budget.reserve(count: source.layers.count, stride: 128)
        let sampler = LayerTransformSampler(source: source, topology: storage.topologies[compositionIndex], frame: frame)
        try append(.beginGroup(FrameGroup(layerID: layerID, frame: frame,
                                           clip: FrameClip(size: source.size, matrix: matrix), opacity: opacity)))
        if let bitmap = source.bitmap {
            guard let sequence = bitmap.sequences.last, let store = scene.bitmaps else {
                throw SceneValidator.invalid("missingPreparedBitmap")
            }
            let index = try bitmap.frameIndex(at: frame, frameRate: source.frameRate)
            let identity = try sequence.imageIdentity(at: index)
            let image: PAGImage
            if let existing = images[identity] {
                image = existing
            } else {
                // 先计计划保活成本，再让媒体 owner 分配像素，避免多实例输入绕过单帧预算。
                try budget.reserve(stride: sequence.byteCount + 256)
                image = try await store.frame(for: sequence, at: index)
                try Task.checkCancellation()
                images[identity] = image
            }
            let local = try SceneAffine.scale(x: source.size.width / image.size.width, y: source.size.height / image.size.height)
            try append(.image(FrameImage(layerID: layerID, resourceID: identity, pixelSize: image.size,
                                          matrix: local.following(matrix), clip: nil, opacity: 1,
                                          contentTime: SceneValidator.time(frame: frame, rate: source.frameRate))))
        }
        if let video = source.video {
            try await sampleVideo(video, source: source, frame: frame, matrix: matrix, layerID: layerID)
        }
        stack.append(PlanningContext(instances: instances, frame: frame, matrix: matrix, sampler: sampler))
    }

    /// 先计输入预算再请求后台硬解；同PTS实例共享槽，不同时间不能互相覆盖输入。
    private mutating func sampleVideo(_ video: SourceVideoComposition, source: SourceComposition, frame: Int64,
                                      matrix: SceneAffine, layerID: PAGLayerID?) async throws {
        guard let sequence = video.sequences.last, let store = scene.videos else {
            throw SceneValidator.invalid("missingPreparedVideo")
        }
        let logical = try video.frame(at: frame, frameRate: source.frameRate)
        let actual = sequence.samples[sequence.sampleIndex(at: logical)].frame
        let identity = VideoFrameID(sequence: sequence.identity, frame: actual)
        let input: VideoFrameTransfer
        if let existing = videos[identity] { input = existing }
        else {
            let estimate = Int(sequence.decodedSize.width) * Int(sequence.decodedSize.height) * 3 / 2
            try budget.reserve(stride: estimate + 256)
            input = try await store.frame(for: sequence, at: logical)
            try Task.checkCancellation()
            guard input.identity == identity else { throw PAGError.mediaFailure("videoPlanFrameIdentity") }
            if input.byteCount > estimate { try budget.reserve(stride: input.byteCount - estimate) }
            videos[identity] = input
        }
        let local = try SceneAffine.scale(x: source.size.width / input.size.width, y: source.size.height / input.size.height)
        try append(.video(FrameVideo(layerID: layerID, resourceID: identity, pixelSize: input.size,
                                      matrix: local.following(matrix), opacity: 1)))
    }

    /// 建立图像像素布局并去重保活输入；原图与替换适配的差别在这里一次确定。
    private mutating func image(resourceID: UInt32, instance: LayerInstance, matrix: SceneAffine,
                                opacity: Double, contentTime: PAGTime) throws {
        guard let source = composition.storage.resources.images[resourceID] else {
            throw SceneValidator.invalid("missingImageReference")
        }
        let replacement = composition.edits.images[instance.id]
        let input = replacement ?? source.image
        let local: SceneAffine
        let clip: FrameClip?
        let sampleTime: PAGTime
        if let replacement {
            let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
            let layer = composition.storage.compositions[reference.composition].layers[reference.layer]
            // 规则缺省的LetterBox也优先于文件表；不能按规则是否显式写了scale来决定优先级。
            let mode = layer.imageFillRule?.scaleMode ?? composition.storage.catalog.imageScaleMode(for: reference)
            local = try ImagePlacement.replacement(replacement, source: source, mode: mode)
            clip = FrameClip(size: source.logicalSize, matrix: matrix)
            guard let mapping = scene.imageTimes.mappings[instance.id] else {
                throw SceneValidator.invalid("missingPreparedImageTime")
            }
            sampleTime = try mapping.time(at: time.frame,
                frameRate: composition.storage.compositions[composition.storage.rootIndex].frameRate)
        } else {
            local = try ImagePlacement.original(source)
            clip = nil
            sampleTime = contentTime
        }
        let identity = input.storage.identity
        let pixelMatrix = try local.following(matrix)
        guard try pixelMatrix.hasArea() else { return }
        if images[identity] == nil {
            try budget.reserve(stride: 256)
            images[identity] = input
        }
        try append(.image(FrameImage(layerID: instance.id, resourceID: identity, pixelSize: input.size,
                                      matrix: pixelMatrix, clip: clip,
                                      opacity: opacity, contentTime: sampleTime)))
    }

    /// 静态直接引用，动态按源合成帧取有界缓存；整体图层alpha与内部组/填充保持独立边界。
    private mutating func shape(instance: LayerInstance, frame: Int64, matrix: SceneAffine, opacity: Double) async throws {
        let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
        let prepared: PreparedShapeLayer
        let sampleFrame: Int64?
        if let existing = scene.shapes[reference] {
            prepared = existing
            sampleFrame = nil
        } else {
            let key = ShapeSampleKey(source: reference, frame: frame)
            sampleFrame = frame
            if let existing = shapeSamples[key] { prepared = existing }
            else {
                guard let store = scene.dynamicShapes else { throw SceneValidator.invalid("missingPreparedShape") }
                try budget.reserve(stride: 256)
                prepared = try await store.sample(key, maximumPreparedBytes: budget.limit - budget.used)
                // await之后只写本次builder，不可把取消的旧请求继续发布为新计划。
                try Task.checkCancellation()
                try budget.reserve(stride: prepared.estimatedBytes)
                shapeSamples[key] = prepared
            }
        }
        guard !prepared.instructions.isEmpty else { return }
        if opacity != 1 { try append(.beginOpacityGroup(FrameOpacityGroup(layerID: instance.id, opacity: opacity))) }
        for instruction in prepared.instructions {
            try Task.checkCancellation()
            switch instruction {
            case .beginOpacityGroup(let alpha):
                try append(.beginOpacityGroup(FrameOpacityGroup(layerID: instance.id, opacity: alpha)))
            case .endOpacityGroup:
                try append(.endOpacityGroup)
            case .fill(let paint):
                let id = ShapeGeometryID(document: composition.storage.identity, source: reference,
                                         index: paint.geometryIndex, sampleFrame: sampleFrame)
                if shapes[id] == nil {
                    try budget.reserve(stride: 256)
                    shapes[id] = prepared.geometries[paint.geometryIndex]
                }
                try append(.shape(FrameShape(layerID: instance.id, geometryID: id, matrix: matrix,
                                              material: paint.material, opacity: paint.opacity)))
            }
        }
        if opacity != 1 { try append(.endOpacityGroup) }
    }

    /// 引用已准备的文字轮次，填充/描边共同接受图层整体 alpha，不强加文字框裁剪。
    private mutating func text(instance: LayerInstance, matrix: SceneAffine, opacity: Double) throws {
        let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
        guard let prepared = scene.texts[reference] else { throw SceneValidator.invalid("missingPreparedText") }
        guard !prepared.passes.isEmpty else { return }
        if texts[prepared.identity] == nil {
            try budget.reserve(stride: 256)
            texts[prepared.identity] = prepared
        }
        if opacity != 1 { try append(.beginOpacityGroup(FrameOpacityGroup(layerID: instance.id, opacity: opacity))) }
        for index in prepared.passes.indices {
            try Task.checkCancellation()
            try append(.text(FrameText(layerID: instance.id, resourceID: prepared.identity, passIndex: index, matrix: matrix)))
        }
        if opacity != 1 { try append(.endOpacityGroup) }
    }

    /// 单条命令也先计量；不能等数组增长完成后才发现预算不足。
    private mutating func append(_ command: FrameCommand) throws {
        try budget.reserve(stride: 512)
        commands.append(command)
    }
}

/// 当前预合成实例的遍历和同帧父矩阵缓存；只属于一份 FramePlanBuilder。
private struct PlanningContext {
    /// 当前合成的直接子实例，已经按公开/绘制顺序排列。
    let instances: [Int]
    /// 当前合成已选定的合法帧。
    let frame: Int64
    /// 当前合成逻辑坐标到目标像素的映射。
    let matrix: SceneAffine
    /// 同一次合成采样中的控制父矩阵缓存，不跨实例共享采样时刻。
    var sampler: LayerTransformSampler
    /// 下一次读取 instances 的游标，等于 count 时输出组结束。
    var nextInstance = 0
}
