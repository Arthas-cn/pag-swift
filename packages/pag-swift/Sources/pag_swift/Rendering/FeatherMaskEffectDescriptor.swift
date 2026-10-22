/// 一项羽化蒙版的局部源图和回填位置；滤镜在GPU编码阶段单独处理。
struct FeatherMaskItemDescriptor {
    /// 只画一项白色alpha和普通路径补集的局部帧，不含其它蒙版项。
    let frame: PreparedFrame
    /// 此项局部贴图的正像素宽度。
    let width: Int
    /// 此项局部贴图的正像素高度。
    let height: Int
    /// 局部图像像素映到总体蒙版表面的矩阵。
    let toOverall: SceneAffine
    /// 正值两轴需要后续分轴模糊；nil或任一负轴按上游不滤镜。
    let feather: ScenePoint?
}

/// 完整羽化效果的有界局部计划；仅含纯值帧和尺寸，不借用GPU附件。
struct FeatherMaskEffectDescriptor {
    /// 内容和最终mask共用的局部表面参数；无可见交集时整个描述不存在。
    let layout: FeatherMaskSurfaceLayout
    /// 层内原始绘制顺序及混合透明度，目标是局部内容附件。
    let content: PreparedFrame
    /// 逐项SrcOver之前的总体mask表面宽度。
    let overallWidth: Int
    /// 逐项SrcOver之前的总体mask表面高度。
    let overallHeight: Int
    /// 每个非退化mask项各自的局部alpha图及其回填矩阵。
    let items: [FeatherMaskItemDescriptor]
    /// 总体mask图像像素到与内容相同的局部表面像素的矩阵。
    let overallToLocal: SceneAffine
    /// 单位局部内容纹理矩形映回最终drawable的矩阵。
    let contentToDisplay: SceneAffine
}

/// 在借GPU附件前锁定羽化层的源范围、局部尺寸和全部坐标映射。
enum FeatherMaskEffectPreparation {
    /// 测量完整mask及图层内容；取消、预算或不支持的嵌套失败不返回部分描述。
    static func make(_ mask: FrameMask, commands: ArraySlice<FrameCommand>,
                     frame: PreparedFrame, resources: MetalResources,
                     budget: inout MetalFrameBudget) throws -> FeatherMaskEffectDescriptor? {
        guard case .feather(let sampled) = mask.source, !mask.isInverted else {
            throw PAGError.renderingFailure("featherMaskSource")
        }
        var trial = budget
        var points = FramePlanBudget(limit: trial.remainingBytes, resourceName: "maximumMetalFrameBytes")
        let measured = try FeatherMaskBounds.measure(sampled, budget: &points)
        try trial.reserve(points.used)
        guard let contentBounds = try FeatherMaskContentBounds.measure(commands, frame: frame,
            layerMatrix: mask.matrix, resources: resources, budget: &trial),
              let layout = try FeatherMaskSurfacePreparation.layout(content: contentBounds,
                mask: measured.overall, parentMatrix: mask.matrix, budget: &trial) else {
            budget = trial
            return nil
        }
        let overallWidth = try surfaceDimension(Float(measured.overall.right) - Float(measured.overall.left))
        let overallHeight = try surfaceDimension(Float(measured.overall.bottom) - Float(measured.overall.top))
        try validateArea(width: overallWidth, height: overallHeight)
        let commandCost = commands.count.multipliedReportingOverflow(by: 64)
        let itemCost = sampled.items.count.multipliedReportingOverflow(by: 128)
        guard !commandCost.overflow, !itemCost.overflow else {
            throw PAGError.resourceLimitExceeded("maximumMetalFrameBytes")
        }
        try trial.reserve(256)
        try trial.reserve(commandCost.partialValue)
        try trial.reserve(itemCost.partialValue)
        let inverse = try mask.matrix.inverted()
        let localCommands = try commands.map {
            try localized($0, inverse: inverse, texture: layout.contentMatrix)
        }
        let localPlan = FramePlan(time: frame.plan.time,
            targetBounds: DisplayRect(x: 0, y: 0, width: Double(layout.width), height: Double(layout.height)),
            commands: localCommands)
        let localContent = PreparedFrame(plan: localPlan, images: frame.images,
            shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
        let white = SceneColor(red: 255, green: 255, blue: 255)
        var items: [FeatherMaskItemDescriptor] = []
        for (source, bounds) in zip(sampled.items, measured.items) {
            try Task.checkCancellation()
            guard let draw = source.draw, bounds.left < bounds.right, bounds.top < bounds.bottom else { continue }
            let width = try surfaceDimension(Float(bounds.right) - Float(bounds.left))
            let height = try surfaceDimension(Float(bounds.bottom) - Float(bounds.top))
            try validateArea(width: width, height: height)
            let toItem = try SceneAffine.translation(x: -bounds.left, y: -bounds.top)
            let maskSource: FrameMaskSource
            if source.expansion == 0 {
                maskSource = .path(source.path)
            } else {
                // 羽化各项先独立扩张；表达式仅含当前项，后续项仍由总体surface做SrcOver。
                let expression = try SampledMaskExpression(terms: [SampledMaskTerm(
                    path: source.path, mode: .add, isInverted: draw.isInverted,
                    expansion: source.expansion)])
                try trial.reserve(expression.estimatedBytes)
                maskSource = .expression(expression)
            }
            let path = FrameMask(layerID: mask.layerID, source: maskSource,
                                 isInverted: draw.isInverted, matrix: toItem)
            let quad = FrameSolid(layerID: mask.layerID, size: try PAGSize(width: Double(width), height: Double(height)),
                                  color: white, matrix: .identity, opacity: Double(draw.opacity) / 255)
            let itemPlan = FramePlan(time: frame.plan.time,
                targetBounds: DisplayRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                commands: [.beginMask(path), .solid(quad), .endMask])
            let itemFrame = PreparedFrame(plan: itemPlan, images: [:], shapes: [:], texts: [:])
            let toOverall = try SceneAffine.translation(x: bounds.left, y: bounds.top)
            items.append(FeatherMaskItemDescriptor(frame: itemFrame, width: width,
                                                   height: height, toOverall: toOverall, feather: draw.feather))
        }
        // parent Canvas先按内容表面的逆矩阵绘回，再重新消费所属层到drawable的矩阵。
        let contentToDisplay = try SceneAffine.scale(x: Double(layout.width), y: Double(layout.height))
            .following(layout.contentMatrix.inverted()).following(mask.matrix)
        budget = trial
        return FeatherMaskEffectDescriptor(layout: layout, content: localContent,
            overallWidth: overallWidth, overallHeight: overallHeight, items: items,
            overallToLocal: layout.contentMatrix, contentToDisplay: contentToDisplay)
    }

    /// FeatherMask::draw采用ceilf(bounds跨度)建立局部表面，尺寸和面积仍受GPU预算上限约束。
    private static func surfaceDimension(_ span: Float) throws -> Int {
        let pixels = span.rounded(.up)
        guard pixels.isFinite, let value = Int(exactly: pixels), value > 0, value <= 16_384 else {
            throw PAGError.resourceLimitExceeded("featherMaskDimensions")
        }
        return value
    }

    /// 任一局部alpha附件超过池允许的总像素数时，在GPU借用前失败。
    private static func validateArea(width: Int, height: Int) throws {
        guard UInt128(width) * UInt128(height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("featherMaskDimensions")
        }
    }

    /// 将已有源命令先逆映到指定坐标系，再映入效果局部表面；羽化与轨道遮罩共用此矩阵链。
    static func localized(_ command: FrameCommand, inverse: SceneAffine,
                          texture: SceneAffine) throws -> FrameCommand {
        switch command {
        case .beginGroup(let group):
            let clip = FrameClip(size: group.clip.size,
                matrix: try mapping(group.clip.matrix, inverse: inverse, texture: texture))
            return .beginGroup(FrameGroup(layerID: group.layerID, frame: group.frame,
                clip: clip, opacity: group.opacity, application: group.application,
                definitionIndex: group.definitionIndex))
        case .endGroup, .endOpacityGroup, .endMask, .endPicture, .endVectorPicture:
            return command
        case .beginMask(let mask):
            // 子普通矩形clip必须和内容走同一坐标链，局部批次才能保留逐draw覆盖。
            return .beginMask(FrameMask(layerID: mask.layerID, source: mask.source,
                isInverted: mask.isInverted,
                matrix: try mapping(mask.matrix, inverse: inverse, texture: texture)))
        case .beginOpacityGroup:
            return command
        case .beginTrackMatte, .endTrackMatteSource, .endTrackMatte:
            // 三个边界只携带源/拥有者身份；内部图元各自按同一坐标链重映。
            return command
        case .beginDropShadow(let shadow):
            return .beginDropShadow(FrameDropShadow(layerID: shadow.layerID,
                matrix: try mapping(shadow.matrix, inverse: inverse, texture: texture),
                layerMatrix: shadow.layerMatrix, styles: shadow.styles, opacity: shadow.opacity))
        case .endDropShadow:
            return .endDropShadow
        case .beginPicture(let picture):
            // 局部批次关闭可选缓存，但标记仍须与同步重映后的原图元通过范围验证。
            return .beginPicture(FramePicture(document: picture.document, source: picture.source,
                matrix: try mapping(picture.matrix, inverse: inverse, texture: texture), content: picture.content))
        case .beginVectorPicture(let marker):
            return .beginVectorPicture(FrameVectorPicture(document: marker.document,
                definitionIndex: marker.definitionIndex, layerID: marker.layerID,
                cacheVariant: marker.cacheVariant,
                matrix: try mapping(marker.matrix, inverse: inverse, texture: texture)))
        case .solid(let solid):
            return .solid(FrameSolid(layerID: solid.layerID, size: solid.size, color: solid.color,
                matrix: try mapping(solid.matrix, inverse: inverse, texture: texture), opacity: solid.opacity))
        case .image(let image):
            let clip = try image.clip.map { value in
                FrameClip(size: value.size, matrix: try mapping(value.matrix, inverse: inverse, texture: texture))
            }
            return .image(FrameImage(layerID: image.layerID, resourceID: image.resourceID,
                pixelSize: image.pixelSize, matrix: try mapping(image.matrix, inverse: inverse, texture: texture),
                clip: clip, opacity: image.opacity, contentTime: image.contentTime,
                motionTile: image.motionTile, bulge: image.bulge, cornerPin: image.cornerPin))
        case .video(let video):
            return .video(FrameVideo(layerID: video.layerID, resourceID: video.resourceID,
                pixelSize: video.pixelSize, matrix: try mapping(video.matrix, inverse: inverse, texture: texture),
                opacity: video.opacity))
        case .shape(let shape):
            return .shape(FrameShape(layerID: shape.layerID, geometryID: shape.geometryID,
                matrix: try mapping(shape.matrix, inverse: inverse, texture: texture),
                material: shape.material, opacity: shape.opacity))
        case .text(let text):
            return .text(FrameText(layerID: text.layerID, resourceID: text.resourceID,
                passIndex: text.passIndex, matrix: try mapping(text.matrix, inverse: inverse, texture: texture)))
        case .textBulge(let effect):
            // 投影局部批次移动整份Text Bulge输出与内部字形引用，不能只平移结果矩形。
            let background = try effect.background.map { shape in
                FrameShape(layerID: shape.layerID, geometryID: shape.geometryID,
                    matrix: try mapping(shape.matrix, inverse: inverse, texture: texture),
                    material: shape.material, opacity: shape.opacity)
            }
            let passes = try effect.passes.map { pass in
                FrameText(layerID: pass.layerID, resourceID: pass.resourceID, passIndex: pass.passIndex,
                    matrix: try mapping(pass.matrix, inverse: inverse, texture: texture))
            }
            return .textBulge(FrameTextBulge(layerID: effect.layerID, frame: effect.frame,
                compositionSize: effect.compositionSize,
                compositionMatrix: try mapping(effect.compositionMatrix, inverse: inverse, texture: texture),
                bulge: effect.bulge, opacity: effect.opacity, background: background, passes: passes))
        }
    }

    /// 所有图元与真实矩形clip使用同一后乘顺序，不能只平移颜色而漏掉裁剪。
    private static func mapping(_ matrix: SceneAffine, inverse: SceneAffine,
                                texture: SceneAffine) throws -> SceneAffine {
        try matrix.following(inverse).following(texture)
    }
}
