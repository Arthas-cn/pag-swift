/// 图片与视频输入规划；只组织既有媒体 owner、素材时钟和原 PAG 图层布局。
extension FramePlanBuilder {
    /// 先计输入预算再请求后台硬解；同PTS实例共享槽，不同时间不能互相覆盖输入。
    mutating func sampleVideo(_ video: SourceVideoComposition, source: SourceComposition, frame: Int64,
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
    mutating func image(resourceID: UInt32, instance: LayerInstance, matrix: SceneAffine,
                                opacity: Double, contentTime: PAGTime,
                                motionTile: SampledMotionTile?, motionBlur: MotionBlurSampling?,
                                bulge: SampledBulge?,
                                cornerPin: SampledCornerPin?) async throws {
        guard let source = composition.storage.resources.images[resourceID] else {
            throw SceneValidator.invalid("missingImageReference")
        }
        let replacement = composition.edits.images[instance.id]
        let input = replacement ?? source.image
        let local: SceneAffine
        let clip: FrameClip?
        var sampleTime: PAGTime
        if let replacement {
            let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
            let layer = composition.storage.compositions[reference.composition].layers[reference.layer]
            // 规则缺省的LetterBox也优先于文件表；不能按规则是否显式写了scale来决定优先级。
            let mode = composition.edits.imageScaleModes[instance.id] ?? layer.imageFillRule?.scaleMode ??
                composition.storage.catalog.imageScaleMode(for: reference)
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
        let pixelMatrix = try local.following(matrix)
        guard try pixelMatrix.hasArea() else { return }
        if replacement != nil, scene.optionalMediaFailures.failure(for: instance.id) != nil {
            try await optionalImageFallback(for: instance, source: source, matrix: matrix, opacity: opacity)
            return
        }
        if let video = input.video {
            // 视频直接复用NV12材质；未实现的图片效果不能丢掉后伪称替换画面正确。
            guard motionTile == nil, motionBlur == nil, bulge == nil, cornerPin == nil else {
                throw PAGError.unsupportedFeature("externalVideoImageEffects")
            }
            guard let owner = scene.externalVideos else {
                throw SceneValidator.invalid("missingExternalVideoOwner")
            }
            let frame: VideoFrameTransfer
            do {
                frame = try await owner.frame(for: video, at: sampleTime, isPlaying: isPlaying)
            } catch let error as PAGError {
                switch error {
                case .mediaFailure(let reason) where reason == "externalVideoNotReady" ||
                    reason == "externalVideoMissingFrame": break
                case .mediaFailure, .unsupportedFeature, .sourceChanged, .ioFailure:
                    scene.optionalMediaFailures.record(error, for: instance.id)
                default: throw error
                }
                // 暂不可用或终态失败都不能闪回原图；终态错误留在场景诊断表中。
                try await optionalImageFallback(for: instance, source: source, matrix: matrix, opacity: opacity)
                return
            }
            try Task.checkCancellation()
            if composition.edits.placeholders[instance.id] != nil {
                scene.placeholderClock?.deactivate(instance.id)
            }
            let identity = frame.identity
            if videos[identity] == nil {
                try budget.reserve(stride: frame.byteCount + 256)
                videos[identity] = frame
            }
            try append(.video(FrameVideo(layerID: instance.id, resourceID: identity,
                pixelSize: input.size, matrix: pixelMatrix, opacity: opacity, clip: clip)))
            return
        }
        let selected: PAGImage
        if input.animation != nil {
            guard let owner = scene.animatedImages else {
                throw SceneValidator.invalid("missingAnimatedImageOwner")
            }
            // GIF/WebP 只按素材自己的累计进度选帧；根循环、图层时间重映射和 seek 都不能回拨它。
            sampleTime = scene.imageAnimationTimeline.elapsed(for: instance.id, at: imageAnimationTime)
            do {
                if waitsForAnimatedImages {
                    selected = try await owner.frame(for: input, at: sampleTime)
                } else {
                    selected = try await owner.availableFrame(for: input, at: sampleTime,
                        instance: instance.id, isPlaying: isPlaying)
                }
            } catch let error as PAGError {
                switch error {
                case .mediaFailure, .unsupportedAnimatedImage:
                    // 首帧载入成功不保证后续所有帧可解；坏替换帧只停掉对应实例。
                    scene.optionalMediaFailures.record(error, for: instance.id)
                    try await optionalImageFallback(for: instance, source: source, matrix: matrix, opacity: opacity)
                    return
                default: throw error
                }
            }
            // 媒体owner暂停点后必须重新检查撤销，旧帧不得发布到新编辑版本。
            try Task.checkCancellation()
        } else { selected = input }
        let identity = selected.storage.identity
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
        if motionBlur != nil {
            // 当前直采融合只与未裁边、未缩放的完整逻辑图等价；替换输入需独立映射合同。
            guard motionTile != nil, bulge == nil, cornerPin == nil, clip == nil,
                  source.logicalSize == input.size, source.scaleFactor == 1,
                  source.anchor.x == 0, source.anchor.y == 0 else {
                throw PAGError.unsupportedFeature("motionBlurImagePlacement")
            }
        }
        let tile = try motionTile.map { try FrameMotionTile($0, placement: local, pixelSize: input.size) }
        let cornerFrame = try cornerPin.map { try FrameCornerPin($0, placement: local) }
        let bulgeFrame = try bulge.map { try FrameBulge($0, placement: local,
            pixelSize: input.size, cornerPin: cornerFrame) }
        if images[identity] == nil {
            try budget.reserve(stride: 256)
            images[identity] = selected
        }
        let slotMask: FrameImageMask?
        if let mask = composition.edits.imageMasks[instance.id] {
            let maskID = mask.image.storage.identity
            if images[maskID] == nil {
                try budget.reserve(stride: 256)
                images[maskID] = mask.image
            }
            slotMask = FrameImageMask(resourceID: maskID, pixelSize: mask.image.size,
                                     matrix: try mask.placement.following(matrix))
        } else { slotMask = nil }
        try append(.image(FrameImage(layerID: instance.id, resourceID: identity, pixelSize: input.size,
                                      matrix: pixelMatrix, clip: clip,
                                      opacity: opacity, contentTime: sampleTime,
                                      motionTile: tile, motionBlur: motionBlur,
                                      bulge: bulgeFrame, cornerPin: cornerFrame, slotMask: slotMask)))
    }

    /// 已选择替换但没有有效帧时使用占位；无占位保持透明，不恢复原始图。
    private mutating func optionalImageFallback(for instance: LayerInstance, source: SourceImage,
                                                matrix: SceneAffine, opacity: Double) async throws {
        if composition.edits.placeholders[instance.id] != nil {
            try await placeholder(for: instance, source: source, matrix: matrix, opacity: opacity)
        }
    }

    /// 可选替换素材尚无有效帧时画占位；占位按自身尺寸布局，不继承失败素材纹理尺寸。
    private mutating func placeholder(for instance: LayerInstance, source: SourceImage,
                                      matrix: SceneAffine, opacity: Double) async throws {
        guard let input = composition.edits.placeholders[instance.id],
              let clock = scene.placeholderClock else {
            throw SceneValidator.invalid("missingPlaceholder")
        }
        let elapsed = clock.elapsed(for: instance.id, at: auxiliaryTime)
        let selected: PAGImage
        if input.animation != nil {
            guard let owner = scene.animatedImages else {
                throw SceneValidator.invalid("missingAnimatedImageOwner")
            }
            if waitsForAnimatedImages {
                selected = try await owner.frame(for: input, at: elapsed)
            } else {
                selected = try await owner.availableFrame(for: input, at: elapsed,
                    instance: instance.id, isPlaying: isPlaying)
            }
        } else { selected = input }
        try Task.checkCancellation()
        let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
        let layer = composition.storage.compositions[reference.composition].layers[reference.layer]
        let mode = layer.imageFillRule?.scaleMode ?? composition.storage.catalog.imageScaleMode(for: reference)
        let placement = try ImagePlacement.replacement(input, source: source, mode: mode)
        let pixelMatrix = try placement.following(matrix)
        guard try pixelMatrix.hasArea() else { return }
        let identity = selected.storage.identity
        if images[identity] == nil {
            try budget.reserve(stride: 256)
            images[identity] = selected
        }
        try append(.image(FrameImage(layerID: instance.id, resourceID: identity,
            pixelSize: input.size, matrix: pixelMatrix,
            clip: FrameClip(size: source.logicalSize, matrix: matrix),
            opacity: opacity, contentTime: elapsed)))
        placeholderIDs.append(instance.id)
    }

}
