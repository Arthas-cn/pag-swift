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
    /// 已发出的实际图元数；空Vector候选不能形成可选快照范围。
    private var primitiveCount = 0
    /// 当前计划使用的输入保活表，不持有 GPU 或 ImageIO 对象。
    private var images: [DocumentIdentity: PAGImage] = [:]
    /// 当前计划需要的共享几何对象，按源身份去重，不复制其轮廓。
    private var shapes: [ShapeGeometryID: ShapeGeometry] = [:]
    /// 本次计划已取得的动态源帧，防止owner四条LRU淘汰后同一帧表又重建相同采样。
    private var shapeSamples: [ShapeSampleKey: PreparedShapeLayer] = [:]
    /// 本次计划需要的文本资源；按准备代数去重，不在每帧重新整形。
    private var texts: [TextResourceID: PreparedTextLayer] = [:]
    /// 同一帧计划中的路径文字展开实例共享完成的逐帧矩阵，不能跨帧复用位置。
    private var textSamples: [TextSampleKey: PreparedTextLayer] = [:]
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
                let context = stack[index]
                if context.isTrackMatteScope {
                    try append(.endTrackMatte)
                    stack.removeLast()
                    continue
                }
                try append(.endGroup)
                if let begin = context.vectorBeginIndex {
                    if primitiveCount > context.primitiveCountAtEnter {
                        try append(.endVectorPicture)
                    } else {
                        // 原始定义仍保留空组，但空Picture不得占缓存身份或请求纹理。
                        commands.remove(at: begin)
                    }
                }
                if context.hasExternalOpacity { try append(.endOpacityGroup) }
                if context.hasLayerMask { try append(.endMask) }
                if context.hasDropShadow { try append(.endDropShadow) }
                stack.removeLast()
                continue
            }
            if stack[index].isTrackMatteScope, stack[index].nextInstance == 1 {
                // 源预合成整棵子树已退出；只有此时才允许拥有者开始自己的内容作用域。
                try append(.endTrackMatteSource)
            }
            let isTrackMatteSource = stack[index].isTrackMatteScope && stack[index].nextInstance == 0
            let isTrackMatteOwner = stack[index].isTrackMatteScope && stack[index].nextInstance == 1
            let instanceIndex = stack[index].instances[stack[index].nextInstance]
            stack[index].nextInstance += 1
            let instance = storage.instances[instanceIndex]
            let source = storage.compositions[instance.compositionIndex]
            let layer = source.layers[instance.layerIndex]
            guard isTrackMatteSource || (composition.edits.visibility[instance.id] ?? layer.isActive) else { continue }
            // null 仍可被 sampler 当作控制父层，但本身没有内容或包含子树。
            if case .null = layer.content { continue }
            let frame = stack[index].frame
            guard let localTime = try SceneTiming.layer(layer, at: frame, frameRate: source.frameRate) else { continue }
            let matte = if isTrackMatteOwner { TrackMatteSelection.unmasked }
                        else { try TrackMatteSampling.select(in: source,
                            topology: storage.topologies[instance.compositionIndex], ownerIndex: instance.layerIndex,
                            frame: frame, sampler: &stack[index].sampler) }
            switch matte {
            case .unmasked:
                break
            case .empty(mode: .alpha), .empty(mode: .luma):
                // 上游空Graphic的正向MaskModifier不绘制拥有者；无需创建局部附件。
                continue
            case .empty(mode: .alphaInverted), .empty(mode: .lumaInverted):
                // 反向空Graphic的MakeMask直接返回nil，保留拥有者原有绘制路径。
                break
            case .empty(mode: .none):
                throw SceneValidator.invalid("invalidTrackMatteTopology")
            case .source(let state):
                guard !stack[index].isTrackMatteScope,
                      stack[index].nextInstance < stack[index].instances.count else {
                    // 链式遮罩要由Metal完整嵌套合同另行验收，不能把源作用域误当普通兄弟层。
                    throw PAGError.unsupportedFeature("nestedTrackMatte")
                }
                let sourceInstanceIndex = stack[index].instances[stack[index].nextInstance]
                let sourceInstance = storage.instances[sourceInstanceIndex]
                guard sourceInstance.compositionIndex == instance.compositionIndex,
                      sourceInstance.layerIndex == state.layerIndex else {
                    throw SceneValidator.invalid("invalidTrackMatteTopology")
                }
                try budget.reserve(stride: 512)
                try append(.beginTrackMatte(FrameTrackMatte(ownerID: instance.id, mode: state.mode)))
                // 编码相邻源在公开逆序数组中紧接拥有者；临时栈不加合成组，继承同帧祖先矩阵。
                stack.append(PlanningContext(instances: [sourceInstanceIndex, instanceIndex], frame: frame,
                    matrix: stack[index].matrix, sampler: stack[index].sampler,
                    vectorBeginIndex: nil, primitiveCountAtEnter: primitiveCount,
                    hasExternalOpacity: false, hasLayerMask: false, isTrackMatteScope: true))
                continue
            }
            let transform = try stack[index].sampler.transform(for: instance.layerIndex)
            guard transform.opacity > 0, try transform.matrix.hasArea() else { continue }
            let matrix = try transform.matrix.following(stack[index].matrix)
            guard try matrix.hasArea() else { continue }
            let hasDropShadow = !layer.dropShadows.isEmpty
            if hasDropShadow {
                try append(.beginDropShadow(FrameDropShadow(layerID: instance.id,
                    matrix: matrix, layerMatrix: transform.matrix,
                    styles: layer.dropShadows, opacity: transform.opacity)))
            }
            // 上游图层saveLayer把整体alpha放在滤镜外；阴影源图不能提前乘该alpha。
            let contentOpacity = hasDropShadow ? 1 : transform.opacity
            let feather: SampledFeatherMask?
            if layer.masks.contains(where: { $0.feather != nil || $0.opacity.isAnimated || $0.opacity.initialValue != 255 }) {
                // LayerCache先按完整列表选分支；None或开放路径不能让羽化层退回普通clip。
                guard let value = try FeatherMaskSampling.sample(layer.masks, at: frame, budget: &budget) else {
                    throw PAGError.renderingFailure("featherMaskSelection")
                }
                feather = value
            } else {
                feather = nil
            }
            let sampled = feather == nil ? try MaskPreparation.orderedPaths(layer.masks, at: frame, budget: &budget) : nil
            if let feather {
                try append(.beginMask(FrameMask(layerID: instance.id, source: .feather(feather),
                                                isInverted: false, matrix: matrix)))
            } else if let sampled {
                let source: FrameMaskSource
                let inverted: Bool
                switch sampled {
                case .path(let value): source = .path(value.path); inverted = value.isInverted
                case .expression(let value): source = .expression(value); inverted = value.isInverted
                }
                try append(.beginMask(FrameMask(layerID: instance.id, source: source,
                                                isInverted: inverted, matrix: matrix)))
            }
            let hasLayerMask = feather != nil || sampled != nil
            var enteredPrecomposition = false
            switch layer.content {
            case let .solid(size, color):
                try append(.solid(FrameSolid(layerID: instance.id, size: size, color: color, matrix: matrix,
                                              opacity: contentOpacity)))
            case .image(let id):
                try image(resourceID: id, instance: instance, matrix: matrix,
                          opacity: contentOpacity, contentTime: localTime.contentTime,
                          motionTile: layer.motionTile.map { try $0.value(at: frame) },
                          bulge: try layer.bulge?.value(at: frame),
                          cornerPin: try layer.cornerPin?.value(at: frame))
            case let .precomposition(id, startFrame):
                guard let childIndex = storage.compositionIndices[id] else {
                    throw SceneValidator.invalid("missingCompositionReference")
                }
                let child = storage.compositions[childIndex]
                let childFrame = try SceneTiming.precomposition(at: frame, startFrame: startFrame,
                                                                 parentRate: source.frameRate, child: child)
                let motionBlur: MotionBlurSampling?
                if layer.motionBlur {
                    // 首内容帧的上一帧仍是自身；父控制链也必须在那个内容帧重新求值。
                    let previousFrame = layer.startFrame + max(localTime.contentFrame - 1, 0)
                    var previousSampler = LayerTransformSampler(source: source,
                        topology: storage.topologies[instance.compositionIndex], frame: previousFrame)
                    let previous = try previousSampler.transform(for: instance.layerIndex)
                    let sampled = try MotionBlurSampling(previous: previous.matrix,
                                                         current: transform.matrix)
                    motionBlur = sampled.shouldSkip ? nil : sampled
                } else {
                    motionBlur = nil
                }
                try await enter(compositionIndex: childIndex, instances: instance.children, frame: childFrame,
                          matrix: matrix, opacity: contentOpacity, layerID: instance.id,
                          hasLayerMask: hasLayerMask, hasDropShadow: hasDropShadow,
                          blendMode: layer.blendMode, levelsGreenOnly: layer.levelsGreenOnly,
                          motionTile: try layer.motionTile.map { try FrameMotionTile($0.value(at: frame),
                              compositionSize: child.size) }, motionBlur: motionBlur)
                enteredPrecomposition = true
            case .null: break
            case .shape:
                try await shape(instance: instance, frame: frame, matrix: matrix, opacity: contentOpacity)
            case .text:
                try text(instance: instance, frame: frame, matrix: matrix, opacity: contentOpacity,
                    compositionSize: source.size, compositionMatrix: stack[index].matrix,
                    bulge: try layer.bulge?.value(at: frame))
            }
            if hasLayerMask, !enteredPrecomposition { try append(.endMask) }
            if hasDropShadow, !enteredPrecomposition { try append(.endDropShadow) }
        }
        try Task.checkCancellation()
        return PreparedFrame(plan: FramePlan(time: time, targetBounds: display.clipRect, commands: commands),
                             images: images, shapes: shapes, texts: texts, videos: videos)
    }

    /// 进入一个根/预合成实例；Vector候选将定义clip放进Picture，实例alpha留在范围外。
    private mutating func enter(compositionIndex: Int, instances: [Int], frame: Int64,
                                matrix: SceneAffine, opacity: Double, layerID: PAGLayerID?,
                                hasLayerMask: Bool = false, hasDropShadow: Bool = false,
                                blendMode: SourceLayerBlendMode = .normal,
                                levelsGreenOnly: Bool = false,
                                motionTile: FrameMotionTile? = nil,
                                motionBlur: MotionBlurSampling? = nil) async throws {
        let storage = composition.storage
        let source = storage.compositions[compositionIndex]
        try budget.reserve(stride: 512)
        try budget.reserve(count: source.layers.count, stride: 128)
        let sampler = LayerTransformSampler(source: source, topology: storage.topologies[compositionIndex], frame: frame)
        // Screen必须在完整子树合成后一次写到背景，可选Vector快照不能跳过这一语义边界。
        let vector = scene.pictureCandidates.vector[compositionIndex] && blendMode == .normal
        let hasExternalOpacity = vector && opacity != 1 && layerID != nil
        if hasExternalOpacity, let layerID {
            try append(.beginOpacityGroup(FrameOpacityGroup(layerID: layerID, opacity: opacity,
                                                            application: .perDraw)))
        }
        let vectorBeginIndex = vector ? commands.count : nil
        if vector {
            // visibility可对同定义的不同展开路径单独覆盖；编辑存在时不跨实例共享父像素。
            let variant = composition.edits.visibility.isEmpty ? nil : layerID
            try append(.beginVectorPicture(FrameVectorPicture(document: storage.identity,
                definitionIndex: compositionIndex, layerID: layerID, cacheVariant: variant,
                matrix: matrix)))
        }
        try append(.beginGroup(FrameGroup(layerID: layerID, frame: frame,
                                           clip: FrameClip(size: source.size, matrix: matrix),
                                           opacity: vector ? 1 : opacity,
                                           application: blendMode == .screen ? .composite : .perDraw,
                                           definitionIndex: compositionIndex, blendMode: blendMode,
                                           levelsGreenOnly: levelsGreenOnly, motionTile: motionTile,
                                           motionBlur: motionBlur)))
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
        stack.append(PlanningContext(instances: instances, frame: frame, matrix: matrix, sampler: sampler,
                                     vectorBeginIndex: vectorBeginIndex,
                                     primitiveCountAtEnter: primitiveCount,
                                     hasExternalOpacity: hasExternalOpacity,
                                     hasLayerMask: hasLayerMask, hasDropShadow: hasDropShadow,
                                     isTrackMatteScope: false))
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
                                opacity: Double, contentTime: PAGTime,
                                motionTile: SampledMotionTile?, bulge: SampledBulge?,
                                cornerPin: SampledCornerPin?) throws {
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
        // 替换素材的原始逻辑框裁剪属于效果输入；直采路径不能把它错误放在平铺结果之后。
        guard motionTile == nil || clip == nil else {
            throw PAGError.unsupportedFeature("motionTileReplacementClip")
        }
        guard bulge == nil || clip == nil else {
            throw PAGError.unsupportedFeature("bulgeReplacementClip")
        }
        guard cornerPin == nil || clip == nil else {
            throw PAGError.unsupportedFeature("cornerPinReplacementClip")
        }
        let tile = try motionTile.map { try FrameMotionTile($0, placement: local, pixelSize: input.size) }
        let cornerFrame = try cornerPin.map { try FrameCornerPin($0, placement: local) }
        let bulgeFrame = try bulge.map { try FrameBulge($0, placement: local,
            pixelSize: input.size, cornerPin: cornerFrame) }
        if images[identity] == nil {
            try budget.reserve(stride: 256)
            images[identity] = input
        }
        try append(.image(FrameImage(layerID: instance.id, resourceID: identity, pixelSize: input.size,
                                      matrix: pixelMatrix, clip: clip,
                                      opacity: opacity, contentTime: sampleTime,
                                      motionTile: tile, bulge: bulgeFrame, cornerPin: cornerFrame)))
    }

    /// 静态直接引用，动态按源合成帧取缓存；内部组逐draw继承alpha，与外层图层边界分开。
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
        // 外层alpha保留在Picture之外；只有真实纹理成功时才由一次绘回消费。
        if opacity != 1 { try append(.beginOpacityGroup(FrameOpacityGroup(layerID: instance.id, opacity: opacity, application: .perDraw))) }
        let eligible = scene.pictureCandidates.layerContent[reference.composition][reference.layer]
            && prepared.instructions.contains { if case .fill = $0 { true } else { false } }
        // 完整静态内容证书允许动态store按源帧采样，却必须给Picture稳定几何身份。
        let geometrySampleFrame = eligible ? nil : sampleFrame
        if eligible {
            try append(.beginPicture(FramePicture(document: composition.storage.identity, source: reference, matrix: matrix)))
        }
        for instruction in prepared.instructions {
            try Task.checkCancellation()
            switch instruction {
            case .beginOpacityGroup(let alpha):
                try append(.beginOpacityGroup(FrameOpacityGroup(layerID: instance.id, opacity: alpha, application: .perDraw)))
            case .endOpacityGroup:
                try append(.endOpacityGroup)
            case .fill(let paint):
                let id = ShapeGeometryID(document: composition.storage.identity, source: reference,
                                         index: paint.geometryIndex, sampleFrame: geometrySampleFrame)
                if shapes[id] == nil {
                    try budget.reserve(stride: 256)
                    shapes[id] = prepared.geometries[paint.geometryIndex]
                }
                try append(.shape(FrameShape(layerID: instance.id, geometryID: id, matrix: matrix,
                                              material: paint.material, opacity: paint.opacity)))
            }
        }
        if eligible { try append(.endPicture) }
        if opacity != 1 { try append(.endOpacityGroup) }
    }

    /// 引用已准备的文字轮次；可选Picture只包内容，回退时每次实际glyph绘制继承图层alpha。
    private mutating func text(instance: LayerInstance, frame: Int64,
                               matrix: SceneAffine, opacity: Double,
                               compositionSize: PAGSize, compositionMatrix: SceneAffine,
                               bulge: SampledBulge?) throws {
        let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
        guard let base = scene.texts[reference] else { throw SceneValidator.invalid("missingPreparedText") }
        let layer = composition.storage.compositions[reference.composition].layers[reference.layer]
        let prepared: PreparedTextLayer
        if !layer.textAnimators.isEmpty || layer.textPath != nil {
            guard case .text(let source) = layer.content else { throw SceneValidator.invalid("textEffectsInNonTextLayer") }
            let key = TextSampleKey(source: reference, frame: frame)
            if let existing = textSamples[key] { prepared = existing }
            else {
                var value = base
                if !layer.textAnimators.isEmpty {
                    value = try TextAnimatorPreparation.prepare(base: value, source: source,
                        animators: layer.textAnimators, at: frame, budget: &budget)
                }
                if let option = layer.textPath {
                    value = try TextPathPreparation.prepare(base: value, source: source, option: option,
                        masks: layer.masks, at: frame, budget: &budget)
                }
                textSamples[key] = value
                prepared = value
            }
        } else { prepared = base }
        guard prepared.source == reference else { throw SceneValidator.invalid("preparedTextSource") }
        let backgroundID: ShapeGeometryID?
        if case .text(let source) = layer.content, source.backgroundAlpha > 0 {
            let id = ShapeGeometryID(document: composition.storage.identity, source: reference,
                index: 0, sampleFrame: layer.textAnimators.isEmpty ? nil : frame)
            if shapes[id] == nil,
               let geometry = try TextBackgroundPreparation.prepare(text: prepared, source: source, budget: &budget) {
                try budget.reserve(stride: geometry.estimatedBytes)
                shapes[id] = geometry
            }
            backgroundID = shapes[id] == nil ? nil : id
        } else { backgroundID = nil }
        guard !prepared.passes.isEmpty || backgroundID != nil else { return }
        if !prepared.passes.isEmpty && texts[prepared.identity] == nil {
            try budget.reserve(stride: 256)
            texts[prepared.identity] = prepared
        }
        if let bulge {
            // 上游先把背景和全部字形合成，再以父合成尺寸而非字形AABB施加Bulge。
            let background: FrameShape?
            if let backgroundID, case .text(let source) = layer.content {
                background = FrameShape(layerID: instance.id, geometryID: backgroundID, matrix: matrix,
                    material: .solid(source.backgroundColor), opacity: Double(source.backgroundAlpha) / 255)
            } else { background = nil }
            let passes = prepared.passes.indices.map {
                FrameText(layerID: instance.id, resourceID: prepared.identity, passIndex: $0, matrix: matrix)
            }
            let effect = try FrameBulge(bulge, placement: .identity, pixelSize: compositionSize)
            try append(.textBulge(FrameTextBulge(layerID: instance.id, frame: frame,
                compositionSize: compositionSize, compositionMatrix: compositionMatrix,
                bulge: effect, opacity: opacity, background: background, passes: passes)))
            return
        }
        // 每轮可能含多个glyph；快照缺席时先组合整层再乘alpha会改变重叠区。
        if opacity != 1 { try append(.beginOpacityGroup(FrameOpacityGroup(layerID: instance.id, opacity: opacity, application: .perDraw))) }
        let eligible = scene.pictureCandidates.layerContent[reference.composition][reference.layer]
        if eligible {
            try append(.beginPicture(FramePicture(document: composition.storage.identity, source: reference,
                matrix: matrix, content: .text(resourceID: prepared.identity, layerID: instance.id))))
        }
        if let backgroundID, case .text(let source) = layer.content {
            // 背景与字形使用同一图层矩阵，但必须先于全部fill/stroke轮次绘制。
            try append(.shape(FrameShape(layerID: instance.id, geometryID: backgroundID, matrix: matrix,
                material: .solid(source.backgroundColor), opacity: Double(source.backgroundAlpha) / 255)))
        }
        for index in prepared.passes.indices {
            try Task.checkCancellation()
            try append(.text(FrameText(layerID: instance.id, resourceID: prepared.identity, passIndex: index, matrix: matrix)))
        }
        if eligible { try append(.endPicture) }
        if opacity != 1 { try append(.endOpacityGroup) }
    }

    /// 单条命令也先计量；不能等数组增长完成后才发现预算不足。
    private mutating func append(_ command: FrameCommand) throws {
        try budget.reserve(stride: 512)
        switch command {
        case .solid, .image, .video, .shape, .text, .textBulge: primitiveCount += 1
        default: break
        }
        commands.append(command)
    }
}

/// 动态文字的临时帧身份；同源不同合成帧的字形变换或路径不能混用。
private struct TextSampleKey: Hashable {
    /// 源合成及图层下标，避免重复编码ID碰撞。
    let source: SourceLayerReference
    /// 上游TextContentCache所在合成的采样帧。
    let frame: Int64
}

/// 当前预合成或轨道遮罩两段实例的遍历状态和同帧父矩阵缓存；只属于一份FramePlanBuilder。
private struct PlanningContext {
    /// 当前合成的直接子实例，已经按公开/绘制顺序排列。
    let instances: [Int]
    /// 当前合成已选定的合法帧。
    let frame: Int64
    /// 当前合成逻辑坐标到目标像素的映射。
    let matrix: SceneAffine
    /// 同一次合成采样中的控制父矩阵缓存，不跨实例共享采样时刻。
    var sampler: LayerTransformSampler
    /// Vector起点在命令数组中的下标；nil表示此定义不具额外Picture资格。
    let vectorBeginIndex: Int?
    /// 进入定义前的图元数，退出时据此剔除空候选。
    let primitiveCountAtEnter: Int
    /// 候选预合成的外部alpha需在Vector和定义clip之外关闭。
    let hasExternalOpacity: Bool
    /// 进入本定义前安装的外层图层蒙版；该定义整棵子树退出后才可恢复。
    let hasLayerMask: Bool
    /// 图层投影包围整个预合成内容，须在子组和蒙版退出后才关闭。
    var hasDropShadow = false
    /// 仅邻层源/拥有者两项的内部作用域；不另建合成边界，也不直接输出到根pass。
    let isTrackMatteScope: Bool
    /// 下一次读取 instances 的游标，等于 count 时输出组结束。
    var nextInstance = 0
}
