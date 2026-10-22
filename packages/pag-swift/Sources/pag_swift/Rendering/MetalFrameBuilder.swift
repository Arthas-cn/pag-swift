import Metal

/// 单帧局部构建器；GPU资源与可变栈只在调用的RenderOwner域内存在。
struct MetalFrameBuilder {
    /// 同一owner的输入缓存，不在当前帧创建另一份设备或队列。
    let resources: MetalResources
    /// 完整求值结果，保持来源和当前资源表一致。
    let frame: PreparedFrame
    /// 当前帧输入与暂存共享的计费。
    var budget: MetalFrameBudget
    /// nil只在局部pass或未启用Picture的单元测试中出现。
    let pictureStore: MetalPictureStore?
    /// 编辑代数进入Picture键，不能用文件身份替代。
    let revision: UInt64
    /// 内部测试强制DisableCache；资格和逐draw命令仍保持不变。
    let disablePictureCache: Bool
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
    /// 当前Shape或Text内容边界；源命令和原绘制同时保留供失败回退。
    var pictureScope: MetalPictureScope?
    /// 当前图层普通路径裁剪；即使网格零面积仍保留作用域以拒绝嵌套和恢复范围。
    var maskScope: MetalMaskScope?
    /// 两层普通非反向单路径的外层作用域；其它嵌套仍在进入处明确拒绝。
    var parentMaskScope: MetalMaskScope?
    /// 必要局部composite先组合颜色时，外层mask推迟到该组合结果的实际draw。
    var maskDeferred = false
    /// 本帧新生成的局部pass，按键记录供首帧多实例共享。
    var pictureWorks: [MetalPictureWork] = []
    /// 羽化的内容、逐项alpha和最终mask局部编码工作。
    var featherWorks: [MetalFeatherWork] = []
    /// 轨道遮罩源与拥有者的双局部批次；提交前全部完成准备。
    var trackMatteWorks: [MetalTrackMatteWork] = []
    /// 静态投影的局部内容批次；根pass只读取其alpha绘制下方颜色。
    var dropShadowWorks: [MetalDropShadowWork] = []
    /// GradientOverlay整层Shape内容与样式结果，根pass只读取有界结果纹理。
    var gradientOverlayWorks: [MetalGradientOverlayWork] = []
    /// Shape局部FastBlur工作；根pass仅以HardLight读取其最终纹理。
    var shapeBlurBlendWorks: [MetalShapeBlurBlendWork] = []
    /// Text Bulge的字形/背景有界局部批次；根pass仍直接画drawable。
    var textBulgeWorks: [MetalTextBulgeWork] = []
    /// 内容pass序号对应的两轴Glow工作，编码时必须插在该pass之后。
    var glowWorks: [Int: MetalGlowWork] = [:]
    /// 同一内容pass的Glow Merge和后续FastBlur，必须紧跟Glow两轴编码。
    var fastBlurWorks: [Int: MetalGlowFastBlurWork] = [:]
    /// 内容pass之后立即编码的局部MotionTile与Glow三段效果。
    var mappedTileGlowWorks: [Int: MetalMappedTileGlowWork] = [:]
    /// 首帧尚未GPU完成时同一键的唯一活动纹理。
    var pendingPictures: [MetalPictureKey: MetalPictureTexture] = [:]
    /// 所有实际回退原因，测试和内部渲染诊断可读取。
    var pictureMisses: [String] = []

    /// 将普通蒙版来源变成一份GPU覆盖输入；未知Boolean空结果在几何准备时显式失败。
    mutating func beginMask(_ value: FrameMask) throws {
        let outer = maskScope
        if let outer {
            guard parentMaskScope == nil, outer.simplePath, outer.input != nil,
                  !maskDeferred, !value.isInverted,
                  case .path = value.source else {
                throw PAGError.unsupportedFeature("nestedMaskPaths")
            }
        }
        guard pictureScope == nil else { throw PAGError.renderingFailure("metalMaskPictureScope") }
        try budget.reserve(256)
        let source: RenderGeometrySource
        switch value.source {
        case .path(let path): source = .mask(path)
        case .expression(let expression):
            // 计划中的补集位必须与不可变有序来源一致；否则同网格会被静默反向显示。
            guard value.isInverted == expression.isInverted else {
                throw PAGError.renderingFailure("metalMaskInverseMismatch")
            }
            source = .maskExpression(expression)
        case .feather:
            // 帧计划已保留完整羽化来源；局部颜色和alpha附件尚未接通时不得按普通逐draw裁剪。
            guard !value.isInverted else { throw PAGError.renderingFailure("metalFeatherInverseMismatch") }
            throw PAGError.unsupportedFeature("featherMask")
        }
        let mesh = try resources.geometry(source, transform: value.matrix, budget: &budget)
        let input: MetalMaskInput?
        if let mesh {
            let transform = try MetalDrawTransform(matrix: value.matrix, origin: mesh.source.origin)
            let uniforms = try MetalMaskUniforms(transform: transform, nodeCount: mesh.nodeCount,
                                                 inverted: value.isInverted)
            input = MetalMaskInput(mesh: mesh, uniforms: uniforms)
        } else {
            input = nil
        }
        let simplePath: Bool
        if case .path = value.source { simplePath = !value.isInverted }
        else { simplePath = false }
        parentMaskScope = outer
        maskScope = MetalMaskScope(input: input, previousLimit: limit, groupDepth: stack.count,
                                   drawStart: draws.count, simplePath: simplePath)
        if input == nil, !value.isInverted { limit = nil }
    }

    /// 羽化层只把已组合内容与最终mask各绘一次，准备失败后原帧不能退回无裁剪内容。
    mutating func feather(_ mask: FrameMask, commands: ArraySlice<FrameCommand>) throws {
        guard maskScope == nil, parentMaskScope == nil, pictureScope == nil else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        var trial = budget
        guard let prepared = try MetalFeatherPreparation.prepare(mask, commands: commands,
            frame: frame, resources: resources, budget: &trial, visible: limit != nil) else {
            budget = trial
            return
        }
        var committed = false
        defer {
            if !committed {
                prepared.work.releaseTransients()
                for loan in prepared.loans { resources.groups.release(loan) }
            }
        }
        var replacement = self
        replacement.budget = trial
        let rectangle = try resources.rectangle(budget: &replacement.budget)
        try replacement.append(mesh: rectangle, texture: prepared.contentTexture,
            matrix: prepared.contentToDisplay, color: SIMD4(repeating: 1), clips: replacement.clips,
            featherMaskTexture: prepared.maskTexture)
        replacement.loans += prepared.loans
        replacement.featherWorks.append(prepared.work)
        self = replacement
        committed = true
    }

    /// 将源和拥有者组合成一次局部效果；失败后不留下根draw或活动附件。
    mutating func trackMatte(_ matte: FrameTrackMatte, source: ArraySlice<FrameCommand>,
                             content: ArraySlice<FrameCommand>) throws {
        guard pictureScope == nil else {
            throw PAGError.unsupportedFeature("nestedTrackMatte")
        }
        var trial = budget
        guard let prepared = try MetalTrackMattePreparation.prepare(matte, source: source,
            content: content, frame: frame, resources: resources, budget: &trial, visible: limit) else {
            budget = trial
            return
        }
        var committed = false
        defer {
            if !committed {
                prepared.work.releaseTransients()
                for loan in prepared.loans { resources.groups.release(loan) }
            }
        }
        var replacement = self
        replacement.budget = trial
        guard matte.ownerOpacity.isFinite, (0...1).contains(matte.ownerOpacity),
              matte.ownerBlendMode == .normal || matte.ownerBlendMode == .hardLight else {
            throw PAGError.unsupportedFeature("trackMatteOwnerBlend")
        }
        let rectangle = try resources.rectangle(budget: &replacement.budget)
        try replacement.append(mesh: rectangle, texture: prepared.work.contentLoan.texture,
            matrix: prepared.toDisplay,
            color: SIMD4(repeating: Float(matte.ownerOpacity)), clips: replacement.clips,
            featherMaskTexture: prepared.work.sourceLoan.texture, trackMatteMode: matte.mode,
            hardLightBlend: matte.ownerBlendMode == .hardLight)
        replacement.loans += prepared.loans
        replacement.trackMatteWorks.append(prepared.work)
        self = replacement
        committed = true
    }

    /// 先准备完整内容局部附件，再按编码顺序绘制投影和原内容；失败不留下半层绘制。
    mutating func dropShadow(_ shadow: FrameDropShadow, content: ArraySlice<FrameCommand>) throws {
        guard pictureScope == nil, maskScope == nil else {
            throw PAGError.unsupportedFeature("dropShadowInMaskOrPictureScope")
        }
        var trial = budget
        guard let prepared = try MetalDropShadowPreparation.prepare(shadow, commands: content,
            frame: frame, resources: resources, budget: &trial, visible: limit) else {
            budget = trial
            return
        }
        var committed = false
        defer {
            if !committed {
                prepared.work.releaseTransients()
                for loan in prepared.loans { resources.groups.release(loan) }
            }
        }
        var replacement = self
        replacement.budget = trial
        try replacement.enter(kind: .opacity, clip: nil, opacity: shadow.opacity, application: .composite)
        let rectangle = try resources.rectangle(budget: &replacement.budget)
        for (style, result) in zip(shadow.styles, prepared.work.styles) where style.distance > 0 || style.size > 0 {
            try Task.checkCancellation()
            let offset = try DropShadowOffset.display(style: style, shadow: shadow)
            let matrix = try result.toDisplay.following(.translation(x: offset.x, y: offset.y))
            let color = try MetalDrawUniforms.premultiplied(red: Double(style.color.red) / 255,
                green: Double(style.color.green) / 255, blue: Double(style.color.blue) / 255,
                alpha: Double(style.opacity) / 255)
            try replacement.append(mesh: rectangle, texture: result.texture,
                matrix: matrix, color: color, clips: replacement.clips, isShadow: true)
        }
        try replacement.append(mesh: rectangle, texture: prepared.work.contentLoan.texture,
            matrix: prepared.toDisplay, color: SIMD4(repeating: 1), clips: replacement.clips)
        try replacement.leave(kind: .opacity)
        replacement.loans += prepared.loans
        replacement.dropShadowWorks.append(prepared.work)
        self = replacement
        committed = true
    }

    /// 只在安装处的组深度恢复祖先范围，防止蒙版泄漏到兄弟层或过早退出子树。
    mutating func endMask() throws {
        guard let scope = maskScope, scope.groupDepth == stack.count, pictureScope == nil else {
            throw PAGError.renderingFailure("metalUnbalancedMask")
        }
        if parentMaskScope != nil {
            // 两层路径只证明了单张Image的覆盖相乘；多draw先合成再裁剪的alpha顺序不同。
            guard draws.count >= scope.drawStart, draws.count - scope.drawStart <= 1,
                  draws.count == scope.drawStart || draws.last?.parentMask != nil else {
                throw PAGError.unsupportedFeature("nestedMaskPaths")
            }
        }
        maskScope = parentMaskScope
        parentMaskScope = nil
        maskDeferred = false
        limit = scope.previousLimit
    }

    /// 保存透明度作用域；只有composite将裁剪延迟到内容结果，perDraw保留每次实际绘制的裁剪。
    mutating func enter(kind: MetalGroupKind, clip: FrameClip?, opacity: Double,
                        application: FrameOpacityApplication = .composite,
                        blendMode: SourceLayerBlendMode = .normal,
                        levelsGreenOnly: Bool = false,
                        motionTile: FrameMotionTile? = nil,
                        motionBlur: MotionBlurSampling? = nil,
                        glow: SampledGlow? = nil,
                        fastBlur: SampledFastBlur? = nil,
                        tileGlowBulge: SampledBulge? = nil) throws {
        guard opacity.isFinite, (0...1).contains(opacity) else { throw PAGError.renderingFailure("metalGroupOpacity") }
        guard blendMode == .normal || application == .composite else {
            throw PAGError.renderingFailure("metalBlendRequiresComposite")
        }
        guard !levelsGreenOnly || (blendMode == .screen && application == .composite) else {
            throw PAGError.renderingFailure("metalLevelsBlendOrder")
        }
        let mappedTileGlow = motionTile != nil && glow != nil && kind == .composition &&
            blendMode == .normal && !levelsGreenOnly && motionBlur == nil && fastBlur == nil
        guard motionTile == nil || (clip != nil && maskScope == nil && deferredClips == nil &&
            ((blendMode == .screen && levelsGreenOnly) || mappedTileGlow)) else {
            throw PAGError.unsupportedFeature("motionTilePrecompositionScope")
        }
        let plainMotionBlur = motionBlur?.shouldSkip == false && kind == .composition && clip != nil &&
            motionTile == nil && glow == nil && fastBlur == nil && blendMode == .normal &&
            !levelsGreenOnly && application == .composite && maskScope == nil &&
            parentMaskScope == nil
        guard motionBlur == nil || plainMotionBlur || (motionTile != nil &&
            blendMode == .screen && levelsGreenOnly && application == .composite &&
            maskScope == nil && motionBlur?.shouldSkip == false) else {
            throw PAGError.unsupportedFeature("motionBlurPrecompositionScope")
        }
        guard glow == nil || (kind == .composition && clip != nil && blendMode == .normal &&
            application == .composite && !levelsGreenOnly &&
            (motionTile == nil || mappedTileGlow) && motionBlur == nil &&
            maskScope == nil && parentMaskScope == nil) else {
            throw PAGError.unsupportedFeature("glowPrecompositionScope")
        }
        if let fastBlur {
            guard glow != nil, kind == .composition, application == .composite,
                  maskScope == nil, parentMaskScope == nil,
                  fastBlur.blurriness.isFinite, fastBlur.blurriness >= 0 else {
                throw PAGError.unsupportedFeature("fastBlurPrecompositionScope")
            }
        }
        guard tileGlowBulge == nil || (mappedTileGlow && tileGlowBulge?.pinning == true) else {
            throw PAGError.unsupportedFeature("tileGlowBulgeScope")
        }
        // 双mask目前只等价于单图像片元交集，额外alpha组须先独立证明后才能接入。
        guard parentMaskScope == nil || (opacity == 1 && blendMode == .normal) else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        try budget.reserve(256 + clips.count * 128 + (deferredClips?.count ?? 0) * 128)
        var compositeClips = clips
        if let clip { try compositeClips.append(clip) }
        stack.append(MetalGroupScope(kind: kind, previous: clips, previousDeferred: deferredClips, previousLimit: limit,
                                     previousMaskDeferred: maskDeferred,
                                     compositeClips: compositeClips, opacity: opacity, application: application,
                                     blendMode: blendMode, levelsGreenOnly: levelsGreenOnly,
                                     motionTile: motionTile, motionBlur: motionBlur, glow: glow,
                                     tileGlowBulge: tileGlowBulge, fastBlur: fastBlur,
                                     compositionClip: clip,
                                     start: draws.count))
        if opacity == 0 || compositeClips.isEmpty { limit = nil }
        else if let bounds = compositeClips.bounds { limit = limit?.intersection(bounds) }
        // 将祖先裁剪移到组结果，防止未来抗锯齿覆盖在子内容和组结果各乘一次。
        if (opacity < 1 || blendMode == .screen || glow != nil || motionBlur != nil),
           application == .composite {
            deferredClips = try (deferredClips ?? MetalClipValues()).merging(compositeClips)
            // 普通clip属于外层DrawOp；必要颜色组内的子draw不先乘它。
            if maskScope != nil { maskDeferred = true }
        }
        clips = (opacity < 1 || blendMode == .screen || glow != nil || motionBlur != nil) &&
            application == .composite ?
            MetalClipValues() : compositeClips
        if let clip, opacity > 0,
           motionTile != nil || motionBlur != nil ||
               ((fastBlur?.blurriness ?? 0) > 0 && fastBlur?.repeatEdgePixels == false) {
            // 平铺或透明边缘Blur会把视口外源内容带入画面；输入先保留完整预合成域。
            var sourceClip = MetalClipValues()
            try sourceClip.append(clip)
            limit = sourceClip.bounds
            deferredClips = nil
            clips = sourceClip
        }
    }

    /// 关闭匹配作用域；perDraw继承给当前实际draw，composite保持其独立内容合成边界。
    mutating func leave(kind: MetalGroupKind) throws {
        guard let scope = stack.popLast(), scope.kind == kind else {
            throw PAGError.renderingFailure("metalUnbalancedGroups")
        }
        let groupLimit = limit
        clips = scope.previous
        deferredClips = scope.previousDeferred
        maskDeferred = scope.previousMaskDeferred
        limit = scope.previousLimit
        guard scope.opacity < 1 || scope.blendMode == .screen || scope.glow != nil ||
            scope.fastBlur != nil || scope.motionBlur != nil else { return }
        if scope.application == .perDraw {
            // 内部composite已只留下一个结果draw；原位乘色既不复制数组，也不重复修改其已编码子pass。
            for index in scope.start..<draws.count {
                try Task.checkCancellation()
                try budget.reserve(32)
                draws[index].color *= Float(scope.opacity)
            }
            return
        }
        let children = Array(draws[scope.start...])
        draws.removeSubrange(scope.start...)
        guard scope.opacity > 0, let groupLimit, let first = children.first else { return }
        if children.count == 1 && scope.blendMode == .normal && scope.glow == nil &&
           scope.motionBlur == nil {
            // 一次SrcOver可直接折入组alpha；嵌套组也已经化为一个组结果图元。
            let combined = try first.clips.merging(scope.compositeClips)
            try append(mesh: first.mesh, texture: first.texture, matrix: first.matrix,
                       color: first.color * Float(scope.opacity), clips: combined, video: first.video,
                       gradient: first.gradient, inheritedMask: first.mask,
                       featherMaskTexture: first.featherMaskTexture, trackMatteMode: first.trackMatteMode,
                       isShadow: first.isShadow, motionTile: first.motionTile, bulge: first.bulge,
                       cornerPin: first.cornerPin, textBulgeMap: first.textBulgeMap)
            return
        }
        var bound = first.bounds
        for child in children.dropFirst() {
            try Task.checkCancellation()
            bound = bound.union(child.bounds)
        }
        if scope.motionTile != nil {
            // 内容紧边界外留透明采样halo，空间重复不能把紧纹理边缘钳成实色。
            bound = try RenderBounds(left: bound.left - 1, top: bound.top - 1,
                right: bound.right + 1, bottom: bound.bottom + 1)
        }
        let mappedBlur: MappedMotionBlurLayout?
        let rect: RenderPixelRect
        if let blur = scope.motionBlur, scope.motionTile == nil,
           let clip = scope.compositionClip {
            guard let layout = try MappedMotionBlurLayout(displayBounds: bound,
                sourceLimit: groupLimit, clip: clip, sampling: blur) else { return }
            mappedBlur = layout
            rect = layout.contentRect
        } else {
            mappedBlur = nil
            guard let ordinary = try bound.pixelRect(clippedTo: groupLimit) else { return }
            rect = ordinary
        }
        let loan = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &budget)
        loans.append(loan)
        try addPass(children, rect: rect, attachment: loan)
        let contentPassIndex = passes.count - 1
        if let mappedBlur {
            try attachPlainMotionBlur(mappedBlur, content: loan, scope: scope)
            return
        }
        if let tile = scope.motionTile, let glow = scope.glow,
           let clip = scope.compositionClip {
            guard let prepared = try attachTileGlowBulge(tile: tile, glow: glow,
                bulge: scope.tileGlowBulge, clip: clip, content: loan,
                contentRect: rect, contentPassIndex: contentPassIndex) else { return }
            let mesh = try resources.rectangle(budget: &budget)
            // 前一效果已向原合成边界之外平铺；最终只保留祖先裁剪，避免裁掉扩出的像素。
            try append(mesh: mesh, texture: prepared.texture, matrix: prepared.matrix,
                color: SIMD4(repeating: Float(scope.opacity)), clips: scope.previous,
                tileGlowBulge: prepared.input)
            return
        }
        var glowInput: MetalGlowInput?
        if let glow = scope.glow {
            // 两轴尺寸按已roundOut的完整内容输入计算；三张附件依次借用且统一由根批次保活。
            let sampling = try GlowSampling(glow, inputWidth: rect.width, inputHeight: rect.height)
            let horizontal = try resources.groups.acquire(width: Int(sampling.blurWidth),
                height: Int(sampling.blurHeight), budget: &budget)
            loans.append(horizontal)
            let vertical = try resources.groups.acquire(width: Int(sampling.blurWidth),
                height: Int(sampling.blurHeight), budget: &budget)
            loans.append(vertical)
            glowWorks[contentPassIndex] = MetalGlowWork(source: loan, horizontal: horizontal,
                vertical: vertical, sampling: sampling)
            glowInput = MetalGlowInput(texture: vertical.texture, threshold: sampling.threshold)
        } else {
            glowInput = nil
        }
        var resultTexture: any MTLTexture = loan.texture
        var resultRect = rect
        if let blur = scope.fastBlur, blur.blurriness > 0 {
            guard let originalGlow = glowInput else {
                throw PAGError.renderingFailure("fastBlurMissingGlow")
            }
            // Glow先完整合并到局部BGRA8，FastBlur只能读取顺序在前的已量化结果。
            let result = try attachFastBlur(blur, clip: scope.compositionClip,
                original: loan, glow: originalGlow, rect: rect, contentPassIndex: contentPassIndex)
            resultTexture = result.texture
            resultRect = result.rect
            glowInput = nil
        }
        let mesh = try resources.rectangle(budget: &budget)
        var matrix: SceneAffine
        let tileUniforms: MetalMotionTileUniforms?
        let contentMap: MetalTextBulgeMap?
        let blurUniforms: MetalMotionBlurUniforms?
        if let tile = scope.motionTile, let clip = scope.compositionClip {
            let sx = tile.outputWidth / 100, sy = tile.outputHeight / 100
            matrix = try SceneAffine.scale(x: clip.size.width * sx, y: clip.size.height * sy)
                .following(.translation(x: clip.size.width * (1 - sx) / 2,
                                        y: clip.size.height * (1 - sy) / 2))
                .following(clip.matrix)
            tileUniforms = try MetalMotionTileUniforms(tile)
            contentMap = try MetalTextBulgeMap(compositionSize: clip.size,
                compositionMatrix: clip.matrix, rect: rect)
            if let blur = scope.motionBlur {
                // 速度域是MotionTile扩大的完整层域，绝不能使用紧致附件的rect宽高。
                let left = clip.size.width * (1 - sx) / 2
                let top = clip.size.height * (1 - sy) / 2
                let input = try RenderBounds(left: left, top: top,
                    right: left + clip.size.width * sx, bottom: top + clip.size.height * sy)
                blurUniforms = try MetalMotionBlurUniforms(blur, inputBounds: input)
                matrix = try SceneAffine.scale(x: 1.2, y: 1.2)
                    .following(.translation(x: -0.1, y: -0.1)).following(matrix)
            } else {
                blurUniforms = nil
            }
        } else {
            matrix = try SceneAffine.scale(x: Double(resultRect.width), y: Double(resultRect.height))
                .following(.translation(x: Double(resultRect.x), y: Double(resultRect.y)))
            tileUniforms = nil
            contentMap = nil
            blurUniforms = nil
        }
        // 平铺及透明边缘Blur扩出的输出不能再被原输入预合成边界截掉。
        let extendsSource = scope.motionTile != nil ||
            (scope.fastBlur?.blurriness ?? 0) > 0 && scope.fastBlur?.repeatEdgePixels == false
        let outputClips = extendsSource ? scope.previous : scope.compositeClips
        try append(mesh: mesh, texture: resultTexture, matrix: matrix,
                   color: SIMD4(repeating: Float(scope.opacity)), clips: outputClips,
                   motionTile: tileUniforms, textBulgeMap: contentMap,
                   screenBlend: scope.blendMode == .screen,
                   levelsGreenOnly: scope.levelsGreenOnly, motionBlur: blurUniforms,
                   glow: glowInput)
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
            var texture = child.texture
            // 真实空裁剪和空几何先跳过，不让不可见材料的解析限制中止整帧。
            if let source = child.gradient {
                switch try MetalGradientInput.make(source, origin: child.mesh.source.origin,
                                                    budget: &budget, resources: resources) {
                case .solid(let rgba): color *= rgba
                case .analytic(let input): gradient = input
                case .texture(let input, let lookup): gradient = input; texture = lookup
                }
            }
            let uniforms = try MetalDrawUniforms(transform: child.transform,
                                                 color: color, clipCount: clipRange.count, clipStart: clipRange.start,
                                                 nodeCount: child.mesh.nodeCount, width: rect.width, height: rect.height,
                                                 targetOrigin: rect.origin, raster: raster)
            encoded.append(MetalDraw(mesh: child.mesh, mask: child.mask, texture: texture,
                                     featherMaskTexture: child.featherMaskTexture, video: child.video,
                                     gradient: gradient, motionTile: child.motionTile, bulge: child.bulge,
                                     cornerPin: child.cornerPin, textBulgeMap: child.textBulgeMap,
                                     parentMask: child.parentMask,
                                     uniforms: uniforms, clips: child.clips,
                                     trackMatteMode: child.trackMatteMode, isShadow: child.isShadow,
                                     screenBlend: child.screenBlend, hardLightBlend: child.hardLightBlend,
                                     levelsGreenOnly: child.levelsGreenOnly,
                                     motionBlur: child.motionBlur, glow: child.glow,
                                     tileGlowBulge: child.tileGlowBulge))
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

    /// Text的完整轮次先合成为真实字形有界纹理，Bulge在根drawable按父合成输入域反采样。
    mutating func textBulge(_ value: FrameTextBulge) throws {
        guard limit != nil else { return }
        guard maskScope == nil, parentMaskScope == nil, pictureScope == nil, !maskDeferred else {
            throw PAGError.unsupportedFeature("nestedTextBulge")
        }
        guard let prepared = try MetalTextBulgePreparation.prepare(value, frame: frame,
            resources: resources, budget: &budget) else { return }
        var committed = false
        defer {
            if !committed {
                prepared.work.releaseTransients()
                resources.groups.release(prepared.work.loan)
            }
        }
        let mesh = try resources.rectangle(budget: &budget)
        let alpha = try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1,
            alpha: value.opacity)
        try append(mesh: mesh, texture: prepared.work.loan.texture, matrix: prepared.toDisplay,
            color: alpha, clips: clips, bulge: MetalBulgeUniforms(value.bulge),
            textBulgeMap: prepared.map)
        loans.append(prepared.work.loan)
        textBulgeWorks.append(prepared.work)
        committed = true
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
        var localClips = clips
        if let clip = value.clip { try localClips.append(clip) }
        try append(mesh: mesh, texture: nil, matrix: matrix, color: alpha, clips: localClips, video: input)
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
            let paint = try MetalDrawUniforms.premultiplied(red: color.red, green: color.green, blue: color.blue,
                                                           alpha: color.alpha * glyph.alpha)
            try append(mesh: mesh, texture: nil, matrix: matrix, color: paint, clips: clips)
        }
    }

    /// 为一个完整绘制预留常量/裁剪成本，使用CPU双精度补回网格原点。
    mutating func append(mesh: MetalMesh, texture: (any MTLTexture)?, matrix: SceneAffine,
                                 color: SIMD4<Float>, clips: MetalClipValues, video: MetalVideoInput? = nil,
                                 gradient: PreparedGradient? = nil,
                                 inheritedMask: MetalMaskInput? = nil,
                                 featherMaskTexture: (any MTLTexture)? = nil,
                                 trackMatteMode: SourceTrackMatteType? = nil,
                                 isShadow: Bool = false,
                                 motionTile: MetalMotionTileUniforms? = nil,
                                 bulge: MetalBulgeUniforms? = nil,
                                 cornerPin: MetalCornerPinUniforms? = nil,
                                 textBulgeMap: MetalTextBulgeMap? = nil,
                                 screenBlend: Bool = false, levelsGreenOnly: Bool = false,
                                 hardLightBlend: Bool = false,
                                 motionBlur: MetalMotionBlurUniforms? = nil,
                                 glow: MetalGlowInput? = nil,
                                 tileGlowBulge: MetalTileGlowBulgeInput? = nil) throws {
        guard let limit, !clips.isEmpty, color.w > 0 else { return }
        let currentMask = maskDeferred ? nil : maskScope?.input
        let parentMask = maskDeferred ? nil : parentMaskScope?.input
        guard currentMask == nil || inheritedMask == nil else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        let mask = inheritedMask ?? currentMask
        guard parentMask == nil || (mask != nil && inheritedMask == nil &&
            texture != nil && video == nil && gradient == nil &&
            featherMaskTexture == nil && trackMatteMode == nil && !isShadow && motionTile == nil &&
            bulge == nil && cornerPin == nil && textBulgeMap == nil && tileGlowBulge == nil) else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        guard mask == nil || featherMaskTexture == nil || trackMatteMode != nil,
              trackMatteMode == nil || featherMaskTexture != nil else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
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
        try budget.reserve(384 + clips.count * 128 + (gradient == nil ? 0 : 256) + (mask == nil ? 0 : 128))
        draws.append(MetalPendingDraw(mesh: mesh, texture: texture, featherMaskTexture: featherMaskTexture,
                                      video: video, gradient: gradient, matrix: matrix, transform: transform,
                                      color: color, clips: clips, mask: mask, bounds: bounds,
                                      trackMatteMode: trackMatteMode, isShadow: isShadow,
                                      motionTile: motionTile, bulge: bulge, cornerPin: cornerPin,
                                      textBulgeMap: textBulgeMap,
                                      parentMask: parentMask, screenBlend: screenBlend,
                                      hardLightBlend: hardLightBlend,
                                      levelsGreenOnly: levelsGreenOnly, motionBlur: motionBlur,
                                      glow: glow, tileGlowBulge: tileGlowBulge))
    }

    /// 源RGB字节按统一数值域归一化，并且只预乘一次当前图元opacity。
    private func color(_ value: SceneColor, opacity: Double) throws -> SIMD4<Float> {
        try MetalDrawUniforms.premultiplied(red: Double(value.red) / 255, green: Double(value.green) / 255,
                                           blue: Double(value.blue) / 255, alpha: opacity)
    }
}
