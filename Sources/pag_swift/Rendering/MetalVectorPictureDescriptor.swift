import Foundation

/// Vector定义的紧边界局部纹理计划；只含原绘制与真实clip，不包含任何子Picture工作。
struct MetalVectorPictureDescriptor {
    /// 定义身份、编辑代数和实际局部纹理网格。
    let key: MetalPictureKey
    /// 单位纹理矩形直接绘回当前目标的矩阵。
    let textureToDisplay: SceneAffine
    /// 已映入局部纹理的原始图元/组命令，供同一command buffer先编码。
    let commands: [FrameCommand]

    /// 从已验证展开范围求实际Metal网格的保守紧边界；空、极小或覆盖整屏时返回nil。
    static func make(_ marker: FrameVectorPicture, commands: [FrameCommand], frame: PreparedFrame,
                     resources: MetalResources, revision: UInt64, target: RenderBounds,
                     budget: inout MetalFrameBudget) throws -> Self? {
        guard let scale = MetalPictureDescriptor.textureScale(for: marker.matrix) else { return nil }
        let inverse = try marker.matrix.inverted()
        let scaleMatrix = try SceneAffine.scale(x: scale, y: scale)
        var clipStack: [RenderBounds?] = []
        var visibilityStack: [Bool] = []
        var bounds: RenderBounds?
        for command in commands {
            try Task.checkCancellation()
            switch command {
            case .beginGroup(let group):
                visibilityStack.append((visibilityStack.last ?? true) && group.opacity > 0)
                let localClip = try clipBounds(group.clip, inverse: inverse)
                if let parent = clipStack.last {
                    clipStack.append(parent?.intersection(localClip))
                } else {
                    clipStack.append(localClip)
                }
            case .endGroup:
                guard clipStack.popLast() != nil, visibilityStack.popLast() != nil else {
                    throw PAGError.renderingFailure("metalUnbalancedVector")
                }
            case .solid(let solid):
                guard visibilityStack.last != false, solid.opacity > 0 else { continue }
                let localMatrix = try solid.matrix.following(inverse)
                let rect = try RenderBounds(left: 0, top: 0, right: solid.size.width,
                                            bottom: solid.size.height).transformed(by: localMatrix)
                bounds = clippedUnion(rect, clips: clipStack, current: bounds)
            case .shape(let shape):
                guard visibilityStack.last != false, shape.opacity > 0 else { continue }
                guard let geometry = frame.shapes[shape.geometryID] else {
                    throw PAGError.renderingFailure("metalVectorShapeIdentity")
                }
                let localMatrix = try shape.matrix.following(inverse)
                let meshMatrix = try localMatrix.following(scaleMatrix)
                guard let mesh = try resources.geometry(.shape(geometry), transform: meshMatrix,
                                                        budget: &budget) else { continue }
                let rect = try MetalDrawTransform(matrix: localMatrix,
                                                  origin: mesh.source.origin).bounds(mesh.bounds)
                bounds = clippedUnion(rect, clips: clipStack, current: bounds)
            case .text(let text):
                guard visibilityStack.last != false else { continue }
                guard let prepared = frame.texts[text.resourceID],
                      prepared.passes.indices.contains(text.passIndex) else {
                    throw PAGError.renderingFailure("metalVectorTextIdentity")
                }
                for glyph in prepared.glyphs {
                    try Task.checkCancellation()
                    let outline: GlyphOutline?
                    let alpha: Double
                    switch prepared.passes[text.passIndex] {
                    case .fill(let color): outline = glyph.fill; alpha = color.alpha
                    case .stroke(let color): outline = glyph.stroke; alpha = color.alpha
                    }
                    guard alpha * glyph.alpha > 0, let outline else { continue }
                    let display = try glyph.matrix.following(text.matrix)
                    let localMatrix = try display.following(inverse)
                    let meshMatrix = try localMatrix.following(scaleMatrix)
                    guard let mesh = try resources.geometry(.glyph(outline), transform: meshMatrix,
                                                            budget: &budget) else { continue }
                    let rect = try MetalDrawTransform(matrix: localMatrix,
                                                      origin: mesh.source.origin).bounds(mesh.bounds)
                    bounds = clippedUnion(rect, clips: clipStack, current: bounds)
                }
            case .beginOpacityGroup(let group):
                // 透明作用域里的网格不会产生像素，不能据此建立空父纹理。
                visibilityStack.append((visibilityStack.last ?? true) && group.opacity > 0)
            case .endOpacityGroup:
                guard visibilityStack.popLast() != nil else {
                    throw PAGError.renderingFailure("metalUnbalancedVector")
                }
            case .beginPicture, .endPicture, .beginVectorPicture, .endVectorPicture:
                throw PAGError.renderingFailure("metalVectorUnexpandedPicture")
            case .beginMask, .endMask, .beginTrackMatte, .endTrackMatteSource, .endTrackMatte,
                 .beginDropShadow, .endDropShadow, .beginGradientOverlay, .endGradientOverlay,
                 .beginShapeBlurBlend, .endShapeBlurBlend:
                // 双输入效果不能被父Vector局部纹理的单图元范围测量吞掉。
                throw PAGError.renderingFailure("metalVectorMask")
            case .image, .video:
                throw PAGError.renderingFailure("metalVectorMedia")
            case .textBulge:
                // 文字滤镜有独立局部内容附件；父Vector快照回退原命令，不复制整份画面。
                return nil
            }
        }
        guard clipStack.isEmpty, visibilityStack.isEmpty else {
            throw PAGError.renderingFailure("metalUnbalancedVector")
        }
        guard let bounds else { return nil }
        let left = floor(bounds.left * scale) - 2
        let top = floor(bounds.top * scale) - 2
        let right = ceil(bounds.right * scale) + 2
        let bottom = ceil(bounds.bottom * scale) + 2
        guard [left, top, right, bottom].allSatisfy(\.isFinite),
              let x = Int(exactly: left), let y = Int(exactly: top),
              let r = Int(exactly: right), let b = Int(exactly: bottom) else {
            throw PAGError.resourceLimitExceeded("metalPictureDimensions")
        }
        let width = r.subtractingReportingOverflow(x)
        let height = b.subtractingReportingOverflow(y)
        guard !width.overflow, !height.overflow, width.partialValue > 0, height.partialValue > 0,
              width.partialValue <= 16_384, height.partialValue <= 16_384,
              UInt128(width.partialValue) * UInt128(height.partialValue) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("metalPictureDimensions")
        }
        let localToTexture = try scaleMatrix.following(.translation(x: -Double(x), y: -Double(y)))
        let textureToLocal = try SceneAffine.scale(x: Double(width.partialValue) / scale,
                                                   y: Double(height.partialValue) / scale)
            .following(.translation(x: Double(x) / scale, y: Double(y) / scale))
        let textureToDisplay = try textureToLocal.following(marker.matrix)
        let allocationBounds = try RenderBounds(left: 0, top: 0, right: 1, bottom: 1)
            .transformed(by: textureToDisplay)
        // 绘回矩阵映射单位quad；以含AA余量的真实纹理范围判断整屏，不能把像素尺寸再乘一次。
        guard allocationBounds.left > target.left || allocationBounds.top > target.top
                || allocationBounds.right < target.right || allocationBounds.bottom < target.bottom else {
            return nil
        }
        let key = MetalPictureKey(document: marker.document, source: nil, textResource: nil,
                                  vectorIndex: marker.definitionIndex, vectorInstance: marker.cacheVariant,
                                  revision: revision,
                                  scaleBits: scale.bitPattern, originX: x, originY: y,
                                  width: width.partialValue, height: height.partialValue)
        let localCommands = try commands.map { try localized($0, inverse: inverse, texture: localToTexture) }
        return Self(key: key, textureToDisplay: textureToDisplay, commands: localCommands)
    }

    /// 以矩形四角取得定义clip在父局部坐标的保守范围；真实旋转多边形仍由Metal组裁剪保留。
    private static func clipBounds(_ clip: FrameClip, inverse: SceneAffine) throws -> RenderBounds {
        let matrix = try clip.matrix.following(inverse)
        return try RenderBounds(left: 0, top: 0, right: clip.size.width,
                                bottom: clip.size.height).transformed(by: matrix)
    }

    /// 只用clip的包围盒收窄分配，不用它替代局部批次的真实抗锯齿裁剪。
    private static func clippedUnion(_ candidate: RenderBounds, clips: [RenderBounds?],
                                     current: RenderBounds?) -> RenderBounds? {
        guard let clip = clips.last else { return current.map { $0.union(candidate) } ?? candidate }
        guard let clip, let visible = candidate.intersection(clip) else { return current }
        return current.map { $0.union(visible) } ?? visible
    }

    /// 每个显示矩阵先逆映到定义，再映入局部纹理；组clip与文字glyph也走同一路径。
    private static func localized(_ command: FrameCommand, inverse: SceneAffine,
                                  texture: SceneAffine) throws -> FrameCommand {
        switch command {
        case .beginGroup(let group):
            let matrix = try group.clip.matrix.following(inverse).following(texture)
            return .beginGroup(FrameGroup(layerID: group.layerID, frame: group.frame,
                                          clip: FrameClip(size: group.clip.size, matrix: matrix),
                                          opacity: group.opacity, application: group.application,
                                          definitionIndex: group.definitionIndex))
        case .endGroup, .beginOpacityGroup, .endOpacityGroup:
            return command
        case .solid(let solid):
            let matrix = try solid.matrix.following(inverse).following(texture)
            return .solid(FrameSolid(layerID: solid.layerID, size: solid.size, color: solid.color,
                                     matrix: matrix, opacity: solid.opacity))
        case .shape(let shape):
            let matrix = try shape.matrix.following(inverse).following(texture)
            return .shape(FrameShape(layerID: shape.layerID, geometryID: shape.geometryID,
                                     matrix: matrix, material: shape.material, opacity: shape.opacity))
        case .text(let text):
            let matrix = try text.matrix.following(inverse).following(texture)
            return .text(FrameText(layerID: text.layerID, resourceID: text.resourceID,
                                   passIndex: text.passIndex, matrix: matrix))
            case .beginPicture, .endPicture, .beginVectorPicture, .endVectorPicture, .image, .video, .textBulge,
             .beginMask, .endMask, .beginTrackMatte, .endTrackMatteSource, .endTrackMatte,
             .beginDropShadow, .endDropShadow, .beginGradientOverlay, .endGradientOverlay,
             .beginShapeBlurBlend, .endShapeBlurBlend:
            throw PAGError.renderingFailure("metalVectorUnexpandedPicture")
        }
    }
}
