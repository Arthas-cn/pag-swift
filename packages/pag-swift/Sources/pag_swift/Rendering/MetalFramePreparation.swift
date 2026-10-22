import Metal

/// 在取得drawable之前完成输入上传、必要组附件和所有pass常量准备。
enum MetalFramePreparation {
    /// 验证整份计划并准备顺序绘制；取消、资源缺失和未实现语义不会返回部分帧。
    static func prepare(_ frame: PreparedFrame, width: Int, height: Int, resources: MetalResources,
                        maximumBytes: Int = 64 * 1024 * 1024,
                        revision: UInt64 = 0, disablePictureCache: Bool = false,
                        pictures: MetalPictureStore? = nil) throws -> MetalFrameBatch {
        var budget = try MetalFrameBudget(maximumBytes: maximumBytes)
        return try prepare(frame, width: width, height: height, resources: resources, budget: &budget,
                           revision: revision, disablePictureCache: disablePictureCache, pictures: pictures)
    }

    /// 与父帧共用单帧预算准备内容局部pass；失败时调用方丢弃复制的预算即可回退。
    static func prepare(_ frame: PreparedFrame, width: Int, height: Int, resources: MetalResources,
                        budget: inout MetalFrameBudget, revision: UInt64 = 0,
                        disablePictureCache: Bool = false,
                        pictures: MetalPictureStore? = nil) throws -> MetalFrameBatch {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt128(width) * UInt128(height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("metalFrameDimensions")
        }
        let target = RenderPixelRect(x: 0, y: 0, width: width, height: height)
        let vectorPlan = try MetalVectorPlan.validate(frame)
        var builder = MetalFrameBuilder(resources: resources, frame: frame,
                                        budget: budget, pictureStore: pictures, revision: revision,
                                        disablePictureCache: disablePictureCache, limit: target.bounds)
        var succeeded = false
        defer {
            // 任何取消、非法栈或管线失败都必须回收此前已借出的局部附件。
            if !succeeded {
                for loan in builder.loans { resources.groups.release(loan) }
                for work in builder.pictureWorks {
                    work.batch.releaseTransients()
                    pictures?.discard(work.lease)
                }
                for work in builder.featherWorks { work.releaseTransients() }
                for work in builder.trackMatteWorks { work.releaseTransients() }
                for work in builder.dropShadowWorks { work.releaseTransients() }
                for work in builder.textBulgeWorks { work.releaseTransients() }
            }
        }
        var index = 0
        while index < frame.plan.commands.count {
            try Task.checkCancellation()
            let command = frame.plan.commands[index]
            switch command {
            case .beginGroup(let group):
                try builder.enter(kind: .composition, clip: group.clip, opacity: group.opacity,
                                  application: group.application, blendMode: group.blendMode,
                                  levelsGreenOnly: group.levelsGreenOnly, motionTile: group.motionTile,
                                  motionBlur: group.motionBlur)
            case .endGroup: try builder.leave(kind: .composition)
            case .beginMask(let mask):
                if case .feather = mask.source {
                    let end = try featherEnd(in: frame.plan.commands, after: index)
                    try builder.feather(mask, commands: frame.plan.commands[(index + 1)..<end])
                    index = end + 1
                    continue
                }
                try builder.beginMask(mask)
            case .endMask: try builder.endMask()
            case .beginTrackMatte(let matte):
                let range = try trackMatteRange(in: frame.plan.commands, after: index)
                try builder.trackMatte(matte,
                    source: frame.plan.commands[(index + 1)..<range.separator],
                    content: frame.plan.commands[(range.separator + 1)..<range.end])
                index = range.end + 1
                continue
            case .endTrackMatteSource, .endTrackMatte:
                throw PAGError.renderingFailure("metalUnbalancedTrackMatte")
            case .beginDropShadow(let shadow):
                let end = try dropShadowEnd(in: frame.plan.commands, after: index)
                try builder.dropShadow(shadow, content: frame.plan.commands[(index + 1)..<end])
                index = end + 1
                continue
            case .endDropShadow:
                throw PAGError.renderingFailure("metalUnbalancedDropShadow")
            case .beginOpacityGroup(let group):
                try builder.enter(kind: .opacity, clip: nil, opacity: group.opacity, application: group.application)
            case .endOpacityGroup: try builder.leave(kind: .opacity)
            case .solid(let solid): if builder.limit != nil { try builder.solid(solid) }
            case .image(let image): if builder.limit != nil { try builder.image(image) }
            case .video(let video): if builder.limit != nil { try builder.video(video) }
            case .shape(let shape): if builder.limit != nil { try builder.shape(shape) }
            case .text(let text): if builder.limit != nil { try builder.text(text) }
            case .textBulge(let effect): if builder.limit != nil { try builder.textBulge(effect) }
            case .beginPicture(let picture): try builder.beginPicture(picture, at: index)
            case .endPicture: try builder.endPicture(at: index)
            case .beginVectorPicture(let marker):
                guard let end = vectorPlan.endByBegin[index] else {
                    throw PAGError.renderingFailure("metalUnbalancedVector")
                }
                if try builder.resolveVector(marker, plan: vectorPlan, begin: index,
                                             target: target.bounds) {
                    // 父快照已生成/命中时子Picture绝不可再分配、编码或发布。
                    index = end + 1
                    continue
                }
            case .endVectorPicture: break
            }
            index += 1
        }
        guard builder.stack.isEmpty, builder.pictureScope == nil,
              builder.maskScope == nil, builder.parentMaskScope == nil else {
            throw PAGError.renderingFailure("metalUnbalancedGroups")
        }
        let pipelines = try resources.pipelines()
        try Task.checkCancellation()
        try builder.finishRoot(target)
        let clipBuffer = try resources.clipBuffer(builder.clipEdges, budget: &builder.budget)
        budget = builder.budget
        succeeded = true
        return MetalFrameBatch(passes: builder.passes, pool: resources.groups, loans: builder.loans,
                               pipelines: pipelines, clipBuffer: clipBuffer,
                               pictureWorks: builder.pictureWorks, featherWorks: builder.featherWorks,
                               trackMatteWorks: builder.trackMatteWorks,
                               dropShadowWorks: builder.dropShadowWorks,
                               textBulgeWorks: builder.textBulgeWorks,
                               pictureStore: pictures,
                               pictureMisses: builder.pictureMisses)
    }

    /// 跳过完整羽化子树前找到与当前图层匹配的结束命令，嵌套由效果准备单独验证。
    private static func featherEnd(in commands: [FrameCommand], after begin: Int) throws -> Int {
        var depth = 1
        for index in (begin + 1)..<commands.count {
            try Task.checkCancellation()
            switch commands[index] {
            case .beginMask: depth += 1
            case .endMask:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        throw PAGError.renderingFailure("metalUnbalancedMask")
    }

    /// 找到唯一源/拥有者分界与作用域终点；未实现嵌套不能漏画成普通根命令。
    private static func trackMatteRange(in commands: [FrameCommand], after begin: Int)
        throws -> (separator: Int, end: Int) {
        var separator: Int?
        for index in (begin + 1)..<commands.count {
            try Task.checkCancellation()
            switch commands[index] {
            case .beginTrackMatte:
                throw PAGError.unsupportedFeature("nestedTrackMatte")
            case .endTrackMatteSource:
                guard separator == nil else { throw PAGError.renderingFailure("metalUnbalancedTrackMatte") }
                separator = index
            case .endTrackMatte:
                guard let separator else { throw PAGError.renderingFailure("metalUnbalancedTrackMatte") }
                return (separator, index)
            default: break
            }
        }
        throw PAGError.renderingFailure("metalUnbalancedTrackMatte")
    }

    /// 定位当前图层唯一投影终点；嵌套投影须由独立局部效果合同明确接通后才能接受。
    private static func dropShadowEnd(in commands: [FrameCommand], after begin: Int) throws -> Int {
        var depth = 1
        for index in (begin + 1)..<commands.count {
            try Task.checkCancellation()
            switch commands[index] {
            case .beginDropShadow: depth += 1
            case .endDropShadow:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        throw PAGError.renderingFailure("metalUnbalancedDropShadow")
    }
}
