import Metal

/// Picture的可选快照只在局部准备完整时替换原命令，失败保留逐draw路径。
extension MetalFrameBuilder {
    /// 父优先尝试Vector局部纹理；可选资源失败不改变builder，随后原子命令可继续命中子Picture。
    mutating func resolveVector(_ marker: FrameVectorPicture, plan: MetalVectorPlan,
                                begin: Int, target: RenderBounds) throws -> Bool {
        guard limit != nil, let pictureStore else { return false }
        guard !disablePictureCache else {
            pictureMisses.append("vectorDisabled")
            return false
        }
        // 禁用或不可见时不复制子范围；深层Vector展开只在真实准备父纹理时发生。
        let expanded = try plan.expandedCommands(frame.plan.commands, begin: begin)
        var lease: MetalPictureLease?
        var localBatch: MetalFrameBatch?
        var committed = false
        defer {
            if !committed {
                localBatch?.releaseTransients()
                if let lease { pictureStore.discard(lease) }
            }
        }
        do {
            var trial = budget
            guard let descriptor = try MetalVectorPictureDescriptor.make(marker, commands: expanded,
                frame: frame, resources: resources, revision: revision, target: target,
                budget: &trial) else {
                pictureMisses.append("vectorEmptyOrFullTarget")
                return false
            }
            let picture: MetalPictureTexture
            if let pending = pendingPictures[descriptor.key] {
                picture = pending
            } else if let cached = try pictureStore.lookup(descriptor.key, budget: &trial) {
                picture = cached
            } else {
                let created = try pictureStore.allocate(descriptor.key, budget: &trial)
                lease = created
                let local = PreparedFrame(
                    plan: FramePlan(time: frame.plan.time,
                                    targetBounds: DisplayRect(x: 0, y: 0,
                                                              width: Double(descriptor.key.width),
                                                              height: Double(descriptor.key.height)),
                                    commands: descriptor.commands),
                    images: [:], shapes: frame.shapes, texts: frame.texts)
                localBatch = try MetalFramePreparation.prepare(local, width: descriptor.key.width,
                                                                height: descriptor.key.height,
                                                                resources: resources, budget: &trial)
                picture = created.picture
            }
            var replacement = self
            replacement.budget = trial
            let quad = try replacement.resources.rectangle(budget: &replacement.budget)
            try replacement.append(mesh: quad, texture: picture.texture,
                                   matrix: descriptor.textureToDisplay,
                                   color: SIMD4(repeating: 1), clips: replacement.clips)
            if let lease, let localBatch {
                replacement.pictureWorks.append(MetalPictureWork(lease: lease, batch: localBatch))
                replacement.pendingPictures[descriptor.key] = picture
            }
            self = replacement
            committed = true
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 仅资源/可选局部pass失败回退；源身份、结构和基础绘制错误必须向调用方传播。
            guard Self.isOptionalPictureFailure(error) else { throw error }
            pictureMisses.append("vector:\(error)")
            return false
        }
    }

    /// 保存原命令区间与回退绘制起点；Picture嵌套须先由父快照合同显式开放。
    mutating func beginPicture(_ picture: FramePicture, at commandIndex: Int) throws {
        guard pictureScope == nil else { throw PAGError.renderingFailure("metalNestedPicture") }
        pictureScope = MetalPictureScope(picture: picture, commandIndex: commandIndex,
                                         drawIndex: draws.count, wasVisible: limit != nil)
    }

    /// 仅在真实局部纹理准备完整后替换逐draw区间；任何可选快照失败保留原结果。
    mutating func endPicture(at commandIndex: Int) throws {
        guard let scope = pictureScope, commandIndex > scope.commandIndex else {
            throw PAGError.renderingFailure("metalUnbalancedPicture")
        }
        pictureScope = nil
        let slice = frame.plan.commands[(scope.commandIndex + 1)..<commandIndex]
        try MetalPictureRangeValidator.validate(slice, picture: scope.picture, frame: frame)
        guard scope.wasVisible, draws.count > scope.drawIndex else { return }
        guard let pictureStore else { return }
        guard !disablePictureCache else {
            pictureMisses.append("disabled")
            return
        }
        var lease: MetalPictureLease?
        var localBatch: MetalFrameBatch?
        var committed = false
        defer {
            if !committed {
                localBatch?.releaseTransients()
                if let lease { pictureStore.discard(lease) }
            }
        }
        do {
            var trial = budget
            guard let descriptor = try MetalPictureDescriptor.make(scope.picture, commands: slice,
                                                                    frame: frame, resources: resources,
                                                                    revision: revision, budget: &trial) else {
                pictureMisses.append("emptyOrSmallScale")
                return
            }
            let picture: MetalPictureTexture
            if let pending = pendingPictures[descriptor.key] {
                picture = pending
            } else if let cached = try pictureStore.lookup(descriptor.key, budget: &trial) {
                picture = cached
            } else {
                let created = try pictureStore.allocate(descriptor.key, budget: &trial)
                lease = created
                let local = PreparedFrame(
                    plan: FramePlan(time: frame.plan.time,
                                    targetBounds: DisplayRect(x: 0, y: 0,
                                                              width: Double(descriptor.key.width),
                                                              height: Double(descriptor.key.height)),
                                    commands: descriptor.commands),
                    images: [:], shapes: frame.shapes, texts: frame.texts)
                localBatch = try MetalFramePreparation.prepare(local, width: descriptor.key.width,
                                                                height: descriptor.key.height,
                                                                resources: resources, budget: &trial)
                picture = created.picture
            }
            var replacement = self
            replacement.budget = trial
            replacement.draws.removeSubrange(scope.drawIndex..<replacement.draws.count)
            let quad = try replacement.resources.rectangle(budget: &replacement.budget)
            try replacement.append(mesh: quad, texture: picture.texture,
                                   matrix: descriptor.textureToDisplay,
                                   color: SIMD4(repeating: 1), clips: replacement.clips)
            // 局部batch与借用同时转交根批次；同帧后续实例复用它，不能再编码第二次。
            if let lease, let localBatch {
                replacement.pictureWorks.append(MetalPictureWork(lease: lease, batch: localBatch))
                replacement.pendingPictures[descriptor.key] = picture
            }
            self = replacement
            committed = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 上游getSnapshot返回nil后展开Graphic；这里只吞可选快照路径的准备失败。
            // 外层原Shape或Text绘制已成功准备，仍由其原命令承担基础渲染错误。
            guard Self.isOptionalPictureFailure(error) else { throw error }
            pictureMisses.append(String(describing: error))
            return
        }
    }

    /// 原计划/源身份/材料错误必须传播；只有局部快照资源不足或建立失败能回退。
    private static func isOptionalPictureFailure(_ error: any Error) -> Bool {
        guard let failure = error as? PAGError else { return false }
        switch failure {
        case .resourceLimitExceeded:
            return true
        case .renderingFailure(let reason):
            return ["metalPictureTextureAllocation", "metalDrawTransform", "metalCoordinateNonFinite",
                    "metalBounds", "metalPassDimensions", "metalInputBufferAllocation",
                    "metalGroupTextureAllocation"].contains(reason)
        default:
            return false
        }
    }

}
