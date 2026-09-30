import Metal

/// 在取得drawable之前完成输入上传、必要组附件和所有pass常量准备。
enum MetalFramePreparation {
    /// 验证整份计划并准备顺序绘制；取消、资源缺失和未实现语义不会返回部分帧。
    static func prepare(_ frame: PreparedFrame, width: Int, height: Int, resources: MetalResources,
                        maximumBytes: Int = 64 * 1024 * 1024) throws -> MetalFrameBatch {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt128(width) * UInt128(height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("metalFrameDimensions")
        }
        let target = RenderPixelRect(x: 0, y: 0, width: width, height: height)
        var builder = MetalFrameBuilder(resources: resources, frame: frame,
                                        budget: try MetalFrameBudget(maximumBytes: maximumBytes), limit: target.bounds)
        var succeeded = false
        defer {
            // 任何取消、非法栈或管线失败都必须回收此前已借出的局部附件。
            if !succeeded { for loan in builder.loans { resources.groups.release(loan) } }
        }
        for command in frame.plan.commands {
            try Task.checkCancellation()
            switch command {
            case .beginGroup(let group):
                try builder.enter(kind: .composition, clip: group.clip, opacity: group.opacity)
            case .endGroup: try builder.leave(kind: .composition)
            case .beginOpacityGroup(let group):
                try builder.enter(kind: .opacity, clip: nil, opacity: group.opacity)
            case .endOpacityGroup: try builder.leave(kind: .opacity)
            case .solid(let solid): if builder.limit != nil { try builder.solid(solid) }
            case .image(let image): if builder.limit != nil { try builder.image(image) }
            case .video(let video): if builder.limit != nil { try builder.video(video) }
            case .shape(let shape): if builder.limit != nil { try builder.shape(shape) }
            case .text(let text): if builder.limit != nil { try builder.text(text) }
            }
        }
        guard builder.stack.isEmpty else { throw PAGError.renderingFailure("metalUnbalancedGroups") }
        let pipelines = try resources.pipelines()
        try Task.checkCancellation()
        try builder.finishRoot(target)
        let clipBuffer = try resources.clipBuffer(builder.clipEdges, budget: &builder.budget)
        succeeded = true
        return MetalFrameBatch(passes: builder.passes, pool: resources.groups, loans: builder.loans,
                               pipelines: pipelines, clipBuffer: clipBuffer)
    }
}

/// 单帧局部构建器；GPU资源与可变栈只在调用的RenderOwner域内存在。
private struct MetalFrameBuilder {
    /// 同一owner的输入缓存，不在当前帧创建另一份设备或队列。
    let resources: MetalResources
    /// 完整求值结果，保持来源和当前资源表一致。
    let frame: PreparedFrame
    /// 当前帧输入与暂存共享的计费。
    var budget: MetalFrameBudget
    /// 所有将被顺序编码的绘制；尚无drawable或command buffer。
    var draws: [MetalPendingDraw] = []
    /// 已关闭局部组的后序pass，根pass在准备结束时追加。
    var passes: [MetalFramePass] = []
    /// 当前帧独占的所有局部附件，成功后交给batch管理归还。
    var loans: [MetalGroupAttachment] = []
    /// 所有pass共享的凸裁剪边，取得drawable前完整上传一次。
    var clipEdges: [SIMD4<Float>] = []
    /// 相同凸区域按值共享边界范围，避免重复字形各自上传根裁剪。
    var clipRanges: [[SIMD4<Float>]: Int] = [:]
    /// 当前显示/祖先裁剪的保守可见范围；nil表示整组无需准备像素。
    var limit: RenderBounds?
    /// 当前全部真实矩形裁剪，退出组后恢复父值。
    var clips = MetalClipValues()
    /// 延迟到祖先组结果才应用的裁剪；子draw仅借它判空，不重复乘coverage。
    var deferredClips: MetalClipValues?
    /// 严格配对的组栈，不依赖只检查深度来区分两种end。
    var stack: [MetalGroupScope] = []

    /// 进入整体透明度作用域；半透明组裁剪延迟到合成时，只应用一次。
    mutating func enter(kind: MetalGroupKind, clip: FrameClip?, opacity: Double) throws {
        guard opacity.isFinite, (0...1).contains(opacity) else { throw PAGError.renderingFailure("metalGroupOpacity") }
        try budget.reserve(256 + clips.count * 128 + (deferredClips?.count ?? 0) * 128)
        var compositeClips = clips
        if let clip { try compositeClips.append(clip) }
        stack.append(MetalGroupScope(kind: kind, previous: clips, previousDeferred: deferredClips, previousLimit: limit,
                                     compositeClips: compositeClips, opacity: opacity, start: draws.count))
        if opacity == 0 || compositeClips.isEmpty { limit = nil }
        else if let bounds = compositeClips.bounds { limit = limit?.intersection(bounds) }
        // 将祖先裁剪移到组结果，防止未来抗锯齿覆盖在子内容和组结果各乘一次。
        if opacity < 1 {
            deferredClips = try (deferredClips ?? MetalClipValues()).merging(compositeClips)
        }
        clips = opacity < 1 ? MetalClipValues() : compositeClips
    }

    /// 关闭匹配的组；多个内容的alpha只在组结果上应用，不能分摊到各个子图元。
    mutating func leave(kind: MetalGroupKind) throws {
        guard let scope = stack.popLast(), scope.kind == kind else {
            throw PAGError.renderingFailure("metalUnbalancedGroups")
        }
        let groupLimit = limit
        clips = scope.previous
        deferredClips = scope.previousDeferred
        limit = scope.previousLimit
        guard scope.opacity < 1 else { return }
        let children = Array(draws[scope.start...])
        draws.removeSubrange(scope.start...)
        guard scope.opacity > 0, let groupLimit, let first = children.first else { return }
        if children.count == 1 {
            // 一次SrcOver可直接折入组alpha；嵌套组也已经化为一个组结果图元。
            let combined = try first.clips.merging(scope.compositeClips)
            try append(mesh: first.mesh, texture: first.texture, matrix: first.matrix,
                       color: first.color * Float(scope.opacity), clips: combined, video: first.video, gradient: first.gradient)
            return
        }
        var bound = first.bounds
        for child in children.dropFirst() {
            try Task.checkCancellation()
            bound = bound.union(child.bounds)
        }
        guard let rect = try bound.pixelRect(clippedTo: groupLimit) else { return }
        let loan = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &budget)
        loans.append(loan)
        try addPass(children, rect: rect, attachment: loan)
        let mesh = try resources.rectangle(budget: &budget)
        let matrix = try SceneAffine.scale(x: Double(rect.width), y: Double(rect.height))
            .following(.translation(x: Double(rect.x), y: Double(rect.y)))
        try append(mesh: mesh, texture: loan.texture, matrix: matrix,
                   color: SIMD4(repeating: Float(scope.opacity)), clips: scope.compositeClips)
    }

    /// 最终pass始终直接指向drawable，普通图元没有固定中间拷贝。
    mutating func finishRoot(_ rect: RenderPixelRect) throws {
        try addPass(draws, rect: rect, attachment: nil)
    }

    /// 目标范围确定后以Double准备NDC与全局裁剪原点；取得drawable后不再求值。
    private mutating func addPass(_ children: [MetalPendingDraw], rect: RenderPixelRect,
                                 attachment: MetalGroupAttachment?) throws {
        try budget.reserve(128)
        var encoded: [MetalDraw] = []
        for child in children {
            guard let raster = try child.bounds.pixelRect(clippedTo: rect.bounds) else { continue }
            guard let clipRange = try prepareClips(child.clips, in: rect.bounds) else { continue }
            try budget.reserve(256)
            var color = child.color
            var gradient: MetalGradientUniforms?
            // 真实空裁剪和空几何先跳过，不让不可见材料的解析限制中止整帧。
            if let source = child.gradient {
                switch try MetalGradientInput.make(source, origin: child.mesh.source.origin, budget: &budget) {
                case .solid(let rgba): color *= rgba
                case .analytic(let input): gradient = input
                }
            }
            let uniforms = try MetalDrawUniforms(transform: child.transform,
                                                 color: color, clipCount: clipRange.count, clipStart: clipRange.start,
                                                 nodeCount: child.mesh.nodeCount, width: rect.width, height: rect.height,
                                                 targetOrigin: rect.origin, raster: raster)
            encoded.append(MetalDraw(mesh: child.mesh, texture: child.texture, video: child.video,
                                     gradient: gradient, uniforms: uniforms, clips: child.clips))
        }
        passes.append(MetalFramePass(rect: rect, attachment: attachment, draws: encoded))
    }

    /// 完整凸交集按值去重；nil为真实空区域，零边数仅表示无额外裁剪。
    private mutating func prepareClips(_ clips: MetalClipValues, in bounds: RenderBounds) throws -> (start: Int, count: Int)? {
        guard clips.count > 0 else { return (0, 0) }
        let polygon = try clips.polygon(in: bounds)
        guard !polygon.vertices.isEmpty else { return nil }
        var geometryBudget = try GeometryBudget()
        let edges = try polygon.packedEdges(budget: &geometryBudget)
        if let start = clipRanges[edges] { return (start, edges.count) }
        try budget.reserve(256 + edges.count * 32)
        let start = clipEdges.count
        clipEdges += edges
        clipRanges[edges] = start
        return (start, edges.count)
    }

    /// 单位矩形的尺寸通过矩阵表达，不为相同纯色图元重复上传顶点。
    mutating func solid(_ value: FrameSolid) throws {
        let mesh = try resources.rectangle(budget: &budget)
        let matrix = try SceneAffine.scale(x: value.size.width, y: value.size.height).following(value.matrix)
        try append(mesh: mesh, texture: nil, matrix: matrix, color: color(value.color, opacity: value.opacity), clips: clips)
    }

    /// 输入纹理方向保持顶行在前，替换素材的附加裁剪只作用于本次绘制。
    mutating func image(_ value: FrameImage) throws {
        guard let image = frame.images[value.resourceID], image.size == value.pixelSize else {
            throw PAGError.renderingFailure("metalImageResource")
        }
        let texture = try resources.image(image, budget: &budget)
        let mesh = try resources.rectangle(budget: &budget)
        let matrix = try SceneAffine.scale(x: image.size.width, y: image.size.height).following(value.matrix)
        var localClips = clips
        if let clip = value.clip { try localClips.append(clip) }
        let alpha = try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1, alpha: value.opacity)
        try append(mesh: mesh, texture: texture, matrix: matrix, color: alpha, clips: localClips)
    }

    /// 视频可见区域使用单位矩形；直接保活NV12与CV包装，颜色转换留给最终片元。
    mutating func video(_ value: FrameVideo) throws {
        guard let source = frame.videos[value.resourceID], source.size == value.pixelSize else {
            throw PAGError.renderingFailure("metalVideoResource")
        }
        let input = try resources.video(source, budget: &budget)
        let mesh = try resources.rectangle(budget: &budget)
        let matrix = try SceneAffine.scale(x: value.pixelSize.width, y: value.pixelSize.height).following(value.matrix)
        let alpha = try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1, alpha: value.opacity)
        try append(mesh: mesh, texture: nil, matrix: matrix, color: alpha, clips: clips, video: input)
    }

    /// 一个复合路径只有一次填充，不能将其轮廓分别SrcOver。
    mutating func shape(_ value: FrameShape) throws {
        guard let source = frame.shapes[value.geometryID] else { throw PAGError.renderingFailure("metalShapeResource") }
        guard let mesh = try resources.geometry(.shape(source), transform: value.matrix, budget: &budget) else { return }
        switch value.material {
        case .solid(let source):
            try append(mesh: mesh, texture: nil, matrix: value.matrix, color: color(source, opacity: value.opacity), clips: clips)
        case .gradient(let source):
            // 首边色透明不代表整条渐变不可见；此处只用paint opacity决定能否跳过。
            let alpha = try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1, alpha: value.opacity)
            try append(mesh: mesh, texture: nil, matrix: value.matrix, color: alpha, clips: clips, gradient: source)
        }
    }

    /// 执行完整fill或stroke轮次，每个glyph的局部矩阵与图层矩阵依次相乘。
    mutating func text(_ value: FrameText) throws {
        guard let source = frame.texts[value.resourceID], source.passes.indices.contains(value.passIndex) else {
            throw PAGError.renderingFailure("metalTextResource")
        }
        let pass = source.passes[value.passIndex]
        for glyph in source.glyphs {
            try Task.checkCancellation()
            let outline: GlyphOutline?
            let color: PAGColor
            switch pass {
            case .fill(let paint): outline = glyph.fill; color = paint
            case .stroke(let paint): outline = glyph.stroke; color = paint
            }
            // 没有描边资源的空glyph不产生像素；布局/推进量已由文本准备保留。
            guard let outline else { continue }
            let matrix = try glyph.matrix.following(value.matrix)
            guard let mesh = try resources.geometry(.glyph(outline), transform: matrix, budget: &budget) else { continue }
            let paint = try MetalDrawUniforms.premultiplied(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
            try append(mesh: mesh, texture: nil, matrix: matrix, color: paint, clips: clips)
        }
    }

    /// 为一个完整绘制预留常量/裁剪成本，使用CPU双精度补回网格原点。
    private mutating func append(mesh: MetalMesh, texture: (any MTLTexture)?, matrix: SceneAffine,
                                 color: SIMD4<Float>, clips: MetalClipValues, video: MetalVideoInput? = nil,
                                 gradient: PreparedGradient? = nil) throws {
        guard let limit, !clips.isEmpty, color.w > 0 else { return }
        let transform = try MetalDrawTransform(matrix: matrix, origin: mesh.source.origin)
        let rawBounds = try transform.bounds(mesh.bounds)
        guard var bounds = rawBounds.intersection(limit) else { return }
        if let clipBounds = clips.bounds {
            guard let visible = bounds.intersection(clipBounds) else { return }
            bounds = visible
        }
        if let deferredClips {
            // 祖先alpha组已经移走coverage；这里仍先排除真实不可见图元，避免先准备无效渐变。
            try budget.reserve(256 + (deferredClips.count + clips.count) * 128)
            let visibility = try deferredClips.merging(clips)
            guard try !visibility.polygon(in: bounds).vertices.isEmpty else { return }
        }
        try budget.reserve(384 + clips.count * 128 + (gradient == nil ? 0 : 256))
        draws.append(MetalPendingDraw(mesh: mesh, texture: texture, video: video, gradient: gradient, matrix: matrix, transform: transform,
                                      color: color, clips: clips, bounds: bounds))
    }

    /// 源RGB字节按统一数值域归一化，并且只预乘一次当前图元opacity。
    private func color(_ value: SceneColor, opacity: Double) throws -> SIMD4<Float> {
        try MetalDrawUniforms.premultiplied(red: Double(value.red) / 255, green: Double(value.green) / 255,
                                           blue: Double(value.blue) / 255, alpha: opacity)
    }
}

/// 两类组只能由自身的end关闭，避免损坏内部计划被悄悄接受。
private enum MetalGroupKind {
    /// 附带合成逻辑边界裁剪的预合成/根组。
    case composition
    /// 只控制整体opacity，没有新裁剪的内容组。
    case opacity
}

/// 退出组时需要恢复的值，不包含系统对象或另一套播放器状态。
private struct MetalGroupScope {
    /// 当前组的匹配种类。
    let kind: MetalGroupKind
    /// 进入之前的裁剪快照，Swift数组按COW共享。
    let previous: MetalClipValues
    /// 进入之前的仅可见性裁剪链；nil表示没有延迟coverage的祖先组。
    let previousDeferred: MetalClipValues?
    /// 父作用域的保守分配范围，nil表示父组已不可见。
    let previousLimit: RenderBounds?
    /// 只在组结果应用的祖先与自身裁剪。
    let compositeClips: MetalClipValues
    /// 经过范围验证的0...1整体alpha。
    let opacity: Double
    /// 子内容在当前绘制数组中的起点。
    let start: Int
}

/// 尚未确定当前pass原点的绘制，在附件范围确定后一次生成Metal常量。
private struct MetalPendingDraw {
    /// 已上传且保持不变的顶点。
    let mesh: MetalMesh
    /// 静图或子组结果，nil表示纯色。
    let texture: (any MTLTexture)?
    /// 两平面视频及其CV包装；与texture互斥，组透明度折叠时仍保留整个输入。
    let video: MetalVideoInput?
    /// 与图片/视频互斥的材料，真实非空pass确定后才检查映射和解析可用性。
    let gradient: PreparedGradient?
    /// 网格局部坐标到最终显示像素的Double变换。
    let matrix: SceneAffine
    /// 按实际GPU系数固定的正逆变换；分配范围和最终片元查询共用，不在各pass重复计算。
    let transform: MetalDrawTransform
    /// 预乘颜色或图片四通道alpha。
    let color: SIMD4<Float>
    /// 本图元实际需要执行的真实裁剪。
    let clips: MetalClipValues
    /// 用于局部附件分配的可见保守范围。
    let bounds: RenderBounds
}
