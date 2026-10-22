/// Vector父快照的配对索引与完整结构验证结果；扫描一次后父优先解析可跳过整段子命令。
struct MetalVectorPlan {
    /// 每个Vector起点对应的严格匹配终点，供成功快照直接跳过内部子Picture。
    let endByBegin: [Int: Int]

    /// 对整份计划执行一次范围/资源验证；禁用缓存或父命中也不能掩盖非法子命令。
    static func validate(_ frame: PreparedFrame) throws -> Self {
        let commands = frame.plan.commands
        guard commands.contains(where: {
            switch $0 {
            case .beginVectorPicture, .endVectorPicture: true
            default: false
            }
        }) else {
            return Self(endByBegin: [:])
        }
        var scopes: [Scope] = []
        var groupDefinitions: [Int?] = []
        var lastClosedGroup: (begin: Int, end: Int)?
        var vectorEnds: [Int: Int] = [:]
        var vectors: [FrameVectorPicture] = []
        for (index, command) in commands.enumerated() {
            try Task.checkCancellation()
            switch command {
            case .beginVectorPicture(let marker):
                guard marker.definitionIndex >= 0,
                      marker.layerID == nil || marker.layerID?.document == marker.document,
                      marker.cacheVariant == nil || marker.cacheVariant == marker.layerID,
                      commands.indices.contains(index + 1),
                      case .beginGroup(let group) = commands[index + 1],
                      group.definitionIndex == marker.definitionIndex,
                      group.layerID == marker.layerID,
                      group.clip.matrix == marker.matrix,
                      group.opacity == 1,
                      group.application == .perDraw else {
                    throw PAGError.renderingFailure("metalVectorIdentity")
                }
                scopes.append(.vector(index))
                vectors.append(marker)
            case .endVectorPicture:
                guard case .vector(let begin)? = scopes.popLast(),
                      case .endGroup? = commands[safe: index - 1],
                      lastClosedGroup?.begin == begin + 1,
                      lastClosedGroup?.end == index - 1,
                      let marker = vectors.popLast(),
                      marker.definitionIndex >= 0 else {
                    throw PAGError.renderingFailure("metalUnbalancedVector")
                }
                vectorEnds[begin] = index
            case .beginGroup(let group):
                scopes.append(.group(index))
                groupDefinitions.append(group.definitionIndex)
                if let marker = vectors.last, group.layerID?.document != nil,
                   group.layerID?.document != marker.document {
                    throw PAGError.renderingFailure("metalVectorGroupIdentity")
                }
                if !vectors.isEmpty, group.definitionIndex == nil {
                    throw PAGError.renderingFailure("metalVectorGroupIdentity")
                }
            case .endGroup:
                guard case .group(let begin)? = scopes.popLast() else {
                    throw PAGError.renderingFailure("metalUnbalancedGroups")
                }
                groupDefinitions.removeLast()
                lastClosedGroup = (begin, index)
            case .beginMask:
                // 含mask的定义目前已关闭父Vector资格；手写非法计划不可绕过局部重映射门禁。
                if !vectors.isEmpty { throw PAGError.renderingFailure("metalVectorMask") }
                scopes.append(.mask)
            case .endMask:
                guard case .mask? = scopes.popLast() else {
                    throw PAGError.renderingFailure("metalUnbalancedMask")
                }
            case .beginTrackMatte, .endTrackMatteSource, .endTrackMatte:
                // 定义级Picture候选已排除带真实引用的轨道遮罩，手写计划不可绕过该资格。
                if !vectors.isEmpty { throw PAGError.renderingFailure("metalVectorTrackMatte") }
            case .beginDropShadow:
                // 局部滤镜不能被父Vector快照当成普通图元；投影自己持有内容边界。
                if !vectors.isEmpty { throw PAGError.renderingFailure("metalVectorDropShadow") }
                scopes.append(.shadow)
            case .endDropShadow:
                guard case .shadow? = scopes.popLast() else {
                    throw PAGError.renderingFailure("metalUnbalancedDropShadow")
                }
            case .beginOpacityGroup:
                scopes.append(.opacity)
            case .endOpacityGroup:
                guard case .opacity? = scopes.popLast() else {
                    throw PAGError.renderingFailure("metalUnbalancedGroups")
                }
            case .beginPicture(let picture):
                if let marker = vectors.last,
                   (picture.document != marker.document
                    || picture.source.composition != (groupDefinitions.last ?? nil)) {
                    throw PAGError.renderingFailure("metalVectorPictureIdentity")
                }
                scopes.append(.picture(index, picture))
            case .endPicture:
                guard case .picture(let begin, let picture)? = scopes.popLast() else {
                    throw PAGError.renderingFailure("metalUnbalancedPicture")
                }
                try MetalPictureRangeValidator.validate(commands[(begin + 1)..<index],
                                                        picture: picture, frame: frame)
            case .solid(let solid):
                if let marker = vectors.last, solid.layerID.document != marker.document {
                    throw PAGError.renderingFailure("metalVectorSolidIdentity")
                }
            case .shape(let shape):
                if let marker = vectors.last,
                   (shape.layerID.document != marker.document || shape.geometryID.document != marker.document
                    || shape.geometryID.source.composition != (groupDefinitions.last ?? nil)
                    || frame.shapes[shape.geometryID] == nil) {
                    throw PAGError.renderingFailure("metalVectorShapeIdentity")
                }
            case .text(let pass):
                if let marker = vectors.last,
                   (pass.layerID.document != marker.document
                    || frame.texts[pass.resourceID]?.source.composition != (groupDefinitions.last ?? nil)
                    || frame.texts[pass.resourceID]?.identity != pass.resourceID
                    || frame.texts[pass.resourceID]?.passes.indices.contains(pass.passIndex) != true) {
                    throw PAGError.renderingFailure("metalVectorTextIdentity")
                }
            case .textBulge(let effect):
                guard !effect.passes.isEmpty || effect.background != nil,
                      effect.passes.allSatisfy({ frame.texts[$0.resourceID]?.passes.indices.contains($0.passIndex) == true }),
                      effect.background.map({ frame.shapes[$0.geometryID] != nil }) ?? true else {
                    throw PAGError.renderingFailure("metalVectorTextBulgeIdentity")
                }
            case .image, .video:
                // PictureCandidates已排除递归图片和媒体；内部出现媒体说明计划与源资格冲突。
                if !vectors.isEmpty { throw PAGError.renderingFailure("metalVectorMedia") }
            }
        }
        guard scopes.isEmpty, vectors.isEmpty, groupDefinitions.isEmpty else {
            throw PAGError.renderingFailure("metalUnbalancedVector")
        }
        return Self(endByBegin: vectorEnds)
    }

    /// 保留全部原绘制/clip/alpha命令，仅移除可选快照标记以生成父局部DisableCache计划。
    func expandedCommands(_ commands: [FrameCommand], begin: Int) throws -> [FrameCommand] {
        guard let end = endByBegin[begin] else { throw PAGError.renderingFailure("metalUnbalancedVector") }
        var result: [FrameCommand] = []
        result.reserveCapacity(end - begin - 1)
        for command in commands[(begin + 1)..<end] {
            try Task.checkCancellation()
            switch command {
            case .beginPicture, .endPicture, .beginVectorPicture, .endVectorPicture:
                break
            default:
                result.append(command)
            }
        }
        return result
    }
}

/// 计划扫描时的严格配对种类；跨种类错位关闭必须在缓存查找前失败。
private enum Scope {
    /// 合成定义clip，关联值是起点命令下标。
    case group(Int)
    /// 外部图层蒙版；父Vector范围内不允许出现尚未实现的局部重映射。
    case mask
    /// 图层投影的独立源内容边界，不属于父Vector缓存范围。
    case shadow
    /// 不带clip的外层或内部alpha。
    case opacity
    /// Shape/Text内容范围的起点与源身份。
    case picture(Int, FramePicture)
    /// Vector定义范围的起点命令下标。
    case vector(Int)
}

/// 索引容错只用于前一条结束命令验证；正式范围仍必须通过配对栈。
private extension Collection where Index == Int {
    /// 索引越界返回nil，避免损坏计划触发数组前置条件崩溃。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
