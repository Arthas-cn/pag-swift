import Foundation

/// 羽化层原始内容在该图层局部坐标中的范围；不以屏幕可见draw范围截断模糊输入。
enum FeatherMaskContentBounds {
    /// 测量一对羽化蒙版内的内容；子层普通矩形蒙版先裁其作用域范围，未接通的效果明确失败。
    static func measure(_ commands: ArraySlice<FrameCommand>, frame: PreparedFrame,
                        layerMatrix: SceneAffine, resources: MetalResources,
                        budget: inout MetalFrameBudget,
                        allowDropShadow: Bool = false,
                        allowTrackMatte: Bool = false,
                        allowConservativeMasks: Bool = false,
                        allowTextBulge: Bool = false) throws -> RenderBounds? {
        try Task.checkCancellation()
        let inverse = try layerMatrix.inverted()
        var groupClips: [RenderBounds?] = []
        var maskScopes: [(previous: RenderBounds?, clip: RenderBounds?)] = []
        var shadowScopes: [(previous: RenderBounds?, shadow: FrameDropShadow)] = []
        var shapeBlurScopes: [(previous: RenderBounds?, effect: FrameShapeBlurBlend)] = []
        var trackMatteSourcesEnded: [Bool] = []
        var opacityDepth = 0
        var bounds: RenderBounds?
        for command in commands {
            try Task.checkCancellation()
            try budget.reserve(64)
            switch command {
            case .beginGroup(let group):
                let clip = try localBounds(size: group.clip.size, matrix: group.clip.matrix, inverse: inverse)
                // graphic bounds先受子合成逻辑边界裁剪；祖先屏幕裁剪要留给效果结果。
                groupClips.append(groupClips.last.map { $0?.intersection(clip) } ?? clip)
            case .endGroup:
                guard !groupClips.isEmpty else { throw PAGError.renderingFailure("featherContentGroupScope") }
                groupClips.removeLast()
            case .beginOpacityGroup:
                opacityDepth += 1
            case .endOpacityGroup:
                guard opacityDepth > 0 else { throw PAGError.renderingFailure("featherContentOpacityScope") }
                opacityDepth -= 1
            case .solid(let solid):
                let rect = try localBounds(size: solid.size, matrix: solid.matrix, inverse: inverse)
                bounds = union(rect, clippedBy: groupClips.last, into: bounds)
            case .image(let image):
                let matrix: SceneAffine
                if image.cornerPin != nil {
                    matrix = try image.bulge == nil ? MetalCornerPinGeometry.outputMatrix(for: image) :
                        MetalBulgeGeometry.outputMatrix(for: image)
                } else if image.motionTile != nil { matrix = try MetalMotionTileGeometry.outputMatrix(for: image) }
                else if image.bulge != nil { matrix = try MetalBulgeGeometry.outputMatrix(for: image) }
                else { matrix = image.matrix }
                let size = try image.motionTile == nil && image.bulge == nil && image.cornerPin == nil
                    ? image.pixelSize : PAGSize(width: 1, height: 1)
                var rect: RenderBounds? = try localBounds(size: size, matrix: matrix, inverse: inverse)
                if let clip = image.clip {
                    let localClip = try localBounds(size: clip.size, matrix: clip.matrix, inverse: inverse)
                    rect = rect?.intersection(localClip)
                }
                if let rect { bounds = union(rect, clippedBy: groupClips.last, into: bounds) }
            case .video(let video):
                let rect = try localBounds(size: video.pixelSize, matrix: video.matrix, inverse: inverse)
                bounds = union(rect, clippedBy: groupClips.last, into: bounds)
            case .shape(let shape):
                guard let geometry = frame.shapes[shape.geometryID] else {
                    throw PAGError.renderingFailure("featherContentShapeIdentity")
                }
                let local = try shape.matrix.following(inverse)
                // 网格细分仍按真实显示倍率准备；仅量边界时才逆映到所属图层。
                guard let mesh = try resources.geometry(.shape(geometry), transform: shape.matrix, budget: &budget) else { continue }
                let rect = try MetalDrawTransform(matrix: local, origin: mesh.source.origin).bounds(mesh.bounds)
                bounds = union(rect, clippedBy: groupClips.last, into: bounds)
            case .text(let text):
                guard let prepared = frame.texts[text.resourceID], prepared.passes.indices.contains(text.passIndex) else {
                    throw PAGError.renderingFailure("featherContentTextIdentity")
                }
                for glyph in prepared.glyphs {
                    try Task.checkCancellation()
                    try budget.reserve(48)
                    let outline: GlyphOutline?
                    switch prepared.passes[text.passIndex] {
                    case .fill: outline = glyph.fill
                    case .stroke: outline = glyph.stroke
                    }
                    guard let outline else { continue }
                    let display = try glyph.matrix.following(text.matrix)
                    let local = try display.following(inverse)
                    guard let mesh = try resources.geometry(.glyph(outline), transform: display, budget: &budget) else { continue }
                    let rect = try MetalDrawTransform(matrix: local, origin: mesh.source.origin).bounds(mesh.bounds)
                    bounds = union(rect, clippedBy: groupClips.last, into: bounds)
                }
            case .textBulge(let effect):
                guard allowTextBulge else { throw PAGError.unsupportedFeature("nestedTextBulge") }
                let clip = FrameClip(size: effect.compositionSize, matrix: effect.compositionMatrix)
                let group = FrameGroup(layerID: nil, frame: effect.frame, clip: clip, opacity: 1)
                var source: [FrameCommand] = [.beginGroup(group)]
                if let background = effect.background { source.append(.shape(background)) }
                source += effect.passes.map(FrameCommand.text)
                source.append(.endGroup)
                guard let ink = try Self.measure(source[...], frame: frame,
                    layerMatrix: layerMatrix, resources: resources, budget: &budget) else { continue }
                // Bulge仅在半径椭圆内移动采样；外侧保留原字形，二者并集是保守非透明范围。
                let width = effect.compositionSize.width, height = effect.compositionSize.height
                let ellipse = try RenderBounds(
                    left: (effect.bulge.center.x - effect.bulge.radiusX) * width,
                    top: (effect.bulge.center.y - effect.bulge.radiusY) * height,
                    right: (effect.bulge.center.x + effect.bulge.radiusX) * width,
                    bottom: (effect.bulge.center.y + effect.bulge.radiusY) * height)
                    .transformed(by: effect.compositionMatrix.following(inverse))
                bounds = union(ink.union(ellipse), clippedBy: groupClips.last, into: bounds)
            case .beginMask(let mask):
                // 子Graphic先独立合并其draw，再与普通矩形clip求交；不能逐draw裁掉后和兄弟混算。
                guard maskScopes.isEmpty else { throw PAGError.unsupportedFeature("nestedMaskPaths") }
                // 轨道遮罩只用此范围分配局部附件；羽化父层仍须执行原来的严格矩形门禁。
                let clip = try allowConservativeMasks
                    ? conservativeClip(mask, inverse: inverse, budget: &budget)
                    : rectangleClip(mask, inverse: inverse, budget: &budget)
                maskScopes.append((previous: bounds, clip: clip))
                bounds = nil
            case .endMask:
                guard let scope = maskScopes.popLast() else {
                    throw PAGError.renderingFailure("featherContentMaskScope")
                }
                let clipped: RenderBounds? = if let clip = scope.clip { bounds?.intersection(clip) } else { nil }
                bounds = if let clipped { scope.previous.map { $0.union(clipped) } ?? clipped }
                         else { scope.previous }
            case .beginPicture, .endPicture, .beginVectorPicture, .endVectorPicture,
                 .beginGradientOverlay, .endGradientOverlay:
                // Picture只是可选缓存标记，真实原命令仍在范围内，不能把标记计成内容。
                break
            case .beginShapeBlurBlend(let effect):
                shapeBlurScopes.append((previous: bounds, effect: effect))
                bounds = nil
            case .endShapeBlurBlend:
                guard let scope = shapeBlurScopes.popLast() else {
                    throw PAGError.renderingFailure("unbalancedShapeBlurBounds")
                }
                let filtered: RenderBounds?
                if let content = bounds {
                    let mapped = try scope.effect.matrix.following(inverse)
                    let local = try content.transformed(by: mapped.inverted())
                    // Decal边缘的Gaussian必须扩大轨道遮罩等祖先局部附件，不能只量原Shape紧界。
                    let halo = scope.effect.blur.repeatEdgePixels ? 0 :
                        max(0, scope.effect.blur.blurriness) + 1
                    let expanded = try RenderBounds(left: floor(local.left) - halo,
                        top: floor(local.top) - halo, right: ceil(local.right) + halo,
                        bottom: ceil(local.bottom) + halo)
                    filtered = try expanded.transformed(by: mapped)
                } else { filtered = nil }
                bounds = scope.previous
                if let filtered { bounds = union(filtered, clippedBy: groupClips.last, into: bounds) }
            case .beginTrackMatte:
                guard allowTrackMatte, trackMatteSourcesEnded.count < 32 else {
                    throw PAGError.unsupportedFeature("nestedTrackMatte")
                }
                trackMatteSourcesEnded.append(false)
            case .endTrackMatteSource:
                guard trackMatteSourcesEnded.last == false else {
                    throw PAGError.renderingFailure("unbalancedTrackMatteBounds")
                }
                trackMatteSourcesEnded[trackMatteSourcesEnded.count - 1] = true
            case .endTrackMatte:
                guard trackMatteSourcesEnded.last == true else {
                    throw PAGError.renderingFailure("unbalancedTrackMatteBounds")
                }
                // 这里只取源与拥有者的保守并集；实际Alpha相乘仍在双输入GPU批次完成。
                trackMatteSourcesEnded.removeLast()
            case .beginDropShadow(let shadow):
                guard allowDropShadow else { throw PAGError.unsupportedFeature("dropShadowInOtherEffectBounds") }
                guard shadow.styles.allSatisfy({ $0.spread.isFinite && (0...1).contains($0.spread) }) else {
                    throw PAGError.unsupportedFeature("nestedDropShadowSpread")
                }
                guard shadow.styles.allSatisfy({ $0.size.isFinite && $0.size >= 0 }) else {
                    throw PAGError.unsupportedFeature("dropShadowNegativeSize")
                }
                shadowScopes.append((previous: bounds, shadow: shadow))
                bounds = nil
            case .endDropShadow:
                guard let scope = shadowScopes.popLast() else {
                    throw PAGError.renderingFailure("unbalancedDropShadowBounds")
                }
                var combined = bounds
                if let source = bounds {
                    for style in scope.shadow.styles where style.distance > 0 || style.size > 0 {
                        try Task.checkCancellation()
                        let offset = try DropShadowOffset.display(style: style, shadow: scope.shadow)
                        let size = try DropShadowOffset.displayEffectSize(style: style, shadow: scope.shadow)
                        // 上游先扩散后模糊；两次独立roundOut的halo须相加，不能把份额相消成原size。
                        let haloX = (size.x * style.spread).rounded(.up)
                            + (size.x * (1 - style.spread)).rounded(.up)
                        let haloY = (size.y * style.spread).rounded(.up)
                            + (size.y * (1 - style.spread)).rounded(.up)
                        let expanded = try RenderBounds(left: source.left - haloX,
                            top: source.top - haloY, right: source.right + haloX,
                            bottom: source.bottom + haloY)
                        let shifted = try expanded.transformed(by: .translation(x: offset.x, y: offset.y))
                        combined = combined.map { $0.union(shifted) } ?? shifted
                    }
                }
                bounds = scope.previous
                if let combined { bounds = union(combined, clippedBy: groupClips.last, into: bounds) }
            }
        }
        guard groupClips.isEmpty, maskScopes.isEmpty, shadowScopes.isEmpty,
              shapeBlurScopes.isEmpty,
              trackMatteSourcesEnded.isEmpty, opacityDepth == 0 else {
            throw PAGError.renderingFailure("featherContentUnbalancedScope")
        }
        try Task.checkCancellation()
        return bounds
    }

    /// 将图元矩形逆映到蒙版所属图层，父变换不得参与局部表面尺寸。
    private static func localBounds(size: PAGSize, matrix: SceneAffine,
                                    inverse: SceneAffine) throws -> RenderBounds {
        let local = try matrix.following(inverse)
        return try RenderBounds(left: 0, top: 0, right: size.width, bottom: size.height).transformed(by: local)
    }

    /// 只为轨道遮罩量非反向路径的保守范围；真实Boolean和覆盖仍由后续GPU网格完成。
    private static func conservativeClip(_ mask: FrameMask, inverse: SceneAffine,
                                         budget: inout MetalFrameBudget) throws -> RenderBounds? {
        guard !mask.isInverted else { throw PAGError.unsupportedFeature("nestedMaskPaths") }
        let terms: [(SourcePath, Float)]
        switch mask.source {
        case .path(let path): terms = [(path, 0)]
        case .expression(let expression):
            guard !expression.isInverted, expression.terms.allSatisfy({ !$0.isInverted }) else {
                throw PAGError.unsupportedFeature("nestedMaskPaths")
            }
            terms = expression.terms.map { ($0.path, $0.expansion) }
        case .feather: throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        var bounds: RenderBounds?
        for (path, expansion) in terms {
            try Task.checkCancellation()
            try budget.reserve(64)
            guard !path.points.isEmpty else { continue }
            let charge = path.points.count.multipliedReportingOverflow(by: 16)
            guard !charge.overflow else { throw PAGError.resourceLimitExceeded("maximumMetalFrameBytes") }
            try budget.reserve(charge.partialValue)
            let halo = Double(max(0, expansion))
            let rect = try RenderBounds(left: path.points.map(\.x).min()! - halo,
                top: path.points.map(\.y).min()! - halo,
                right: path.points.map(\.x).max()! + halo,
                bottom: path.points.map(\.y).max()! + halo)
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        guard let bounds else { return nil }
        return try bounds.transformed(by: mask.matrix.following(inverse))
    }

    /// 仅将非反向严格闭合轴对齐四角路径映入父羽化局部；其它子效果须保留明确门禁。
    private static func rectangleClip(_ mask: FrameMask, inverse: SceneAffine,
                                      budget: inout MetalFrameBudget) throws -> RenderBounds {
        guard case .path(let path) = mask.source, !mask.isInverted,
              path.verbs == [.move, .line, .line, .line, .close], path.points.count == 4 else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        try budget.reserve(128)
        let points = path.points.map { (x: Float($0.x), y: Float($0.y)) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        let left = points.map { $0.x }.min()!, right = points.map { $0.x }.max()!
        let top = points.map { $0.y }.min()!, bottom = points.map { $0.y }.max()!
        guard left < right, top < bottom else { throw PAGError.unsupportedFeature("nestedMaskPaths") }
        var corners: UInt8 = 0
        for index in 0..<4 {
            try Task.checkCancellation()
            let point = points[index], next = points[(index + 1) % 4]
            guard (point.x == left || point.x == right), (point.y == top || point.y == bottom),
                  (point.x == next.x) != (point.y == next.y) else {
                throw PAGError.unsupportedFeature("nestedMaskPaths")
            }
            let bit = UInt8(1 << ((point.x == right ? 2 : 0) + (point.y == bottom ? 1 : 0)))
            guard corners & bit == 0 else { throw PAGError.unsupportedFeature("nestedMaskPaths") }
            corners |= bit
        }
        guard corners == 0b1111 else { throw PAGError.unsupportedFeature("nestedMaskPaths") }
        let local = try mask.matrix.following(inverse)
        // 旋转或翻转时矩形AABB不能代替PathOp的真实交集，此子范围只接受正向轴对齐矩阵。
        guard local.a > 0, local.d > 0, local.b == 0, local.c == 0 else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        return try RenderBounds(left: Double(left), top: Double(top),
                                right: Double(right), bottom: Double(bottom)).transformed(by: local)
    }

    /// 组裁剪为空时保持空结果；其它情况只用AABB缩小分配，真正旋转边仍留给Metal。
    private static func union(_ candidate: RenderBounds, clippedBy clip: RenderBounds??,
                              into current: RenderBounds?) -> RenderBounds? {
        let visible: RenderBounds
        if let clip {
            guard let clip, let intersection = candidate.intersection(clip) else { return current }
            visible = intersection
        } else {
            visible = candidate
        }
        return current.map { $0.union(visible) } ?? visible
    }
}
