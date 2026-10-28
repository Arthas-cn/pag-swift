/// 基础图层和属性解析；二维变换支持有证据的常量与动画，其他语义逐项扩充。
extension PAGSceneDecoder {
    /// 按 LayerTag.cpp 读取类型、ID 和内部标签；缺失或冲突属性均失败。
    mutating func readLayer(reader: inout PAGByteReader) throws -> SourceLayer {
        try Task.checkCancellation()
        guard sourceLayerCount < limits.maximumLayerCount else {
            throw PAGError.resourceLimitExceeded("maximumLayerCount")
        }
        sourceLayerCount += 1
        try budget.reserve(1024)
        let type = try reader.readUInt8()
        guard (1...6).contains(type) else { throw PAGError.unsupportedFeature("layerType:\(type)") }
        let id = try reader.readEncodedUInt32()
        var attributes: LayerAttributes?
        var attributesExtra: (name: String?, motionBlur: Bool)?
        var transform: SourceTransformProperties?
        var content: SourceLayerContent?
        var shapes: [SourceShape] = []
        var masks: [SourceMask] = []
        var markers: [SourceMarker] = []
        var imageFillRule: SourceImageFillRule?
        var textPath: SourceTextPathOption?
        var textAnimators: [SourceTextAnimator] = []
        var dropShadows: [SourceDropShadow] = []
        var gradientOverlay: SourceGradientOverlay?
        var motionTile: SourceMotionTile?
        var bulge: SourceBulge?
        var cornerPin: SourceCornerPin?
        var glow: SourceGlow?
        var fastBlur: SourceFastBlur?
        var levelsGreenOnly = false
        var imageEffectOrder: [UInt16] = []
        var precompositionEffectOrder: [UInt16] = []
        while var block = try nextBlock(from: &reader) {
            switch block.code {
            case 6, 52, 62:
                guard attributes == nil else { throw PAGError.invalidFile(reason: "duplicateLayerAttributes", offset: nil) }
                attributes = try readLayerAttributes(code: block.code, reader: &block.reader)
            case 63:
                guard attributesExtra == nil else { throw PAGError.invalidFile(reason: "duplicateLayerAttributesExtra", offset: nil) }
                attributesExtra = try readLayerAttributesExtra(reader: &block.reader)
            case 13:
                guard transform == nil else { throw PAGError.invalidFile(reason: "duplicateTransform", offset: nil) }
                transform = try readTransform(reader: &block.reader)
            case 14, 84:
                // LayerTag按编码顺序追加，不按ID去重；未知模式和未完成属性由读取/求值门禁负责。
                try budget.reserve(32)
                masks.append(try readMask(code: block.code, reader: &block.reader))
            case 7 where type == 2:
                guard content == nil else { throw PAGError.invalidFile(reason: "duplicateLayerContent", offset: nil) }
                content = try readSolid(reader: &block.reader)
            case 8, 64, 68:
                guard type == 3 else { throw SceneValidator.invalid("textInNonTextLayer") }
                guard content == nil else { throw SceneValidator.invalid("duplicateLayerContent") }
                content = .text(try readText(code: block.code, reader: &block.reader))
            case 11 where type == 5:
                guard content == nil else { throw SceneValidator.invalid("duplicateLayerContent") }
                content = .image(try block.reader.readEncodedUInt32())
            case 12 where type == 6:
                guard content == nil else { throw PAGError.invalidFile(reason: "duplicateLayerContent", offset: nil) }
                content = .precomposition(id: try block.reader.readEncodedUInt32(),
                                         startFrame: try StaticAttributes.frame(from: &block.reader))
            case 15...26:
                // LayerTag.cpp与ShapeGroup共用ReadShape；已实现内容可直接位于层内，不能只允许在组内出现。
                guard type == 4 else { throw PAGError.invalidFile(reason: "shapeInNonShapeLayer", offset: nil) }
                shapes.append(try readShape(code: block.code, reader: &block.reader, depth: 1))
            case 53:
                markers += try readMarkers(reader: &block.reader)
            case 54, 67:
                guard type == 5 else { throw SceneValidator.invalid("imageFillRuleInNonImageLayer") }
                guard imageFillRule == nil else { throw SceneValidator.invalid("duplicateImageFillRule") }
                imageFillRule = try readImageFillRule(code: block.code, reader: &block.reader)
            case 69:
                guard type == 3 else { throw SceneValidator.invalid("textPathInNonTextLayer") }
                guard textPath == nil else { throw SceneValidator.invalid("duplicateTextPath") }
                textPath = try readTextPathOption(reader: &block.reader)
            case 70:
                guard type == 3 else { throw SceneValidator.invalid("textAnimatorInNonTextLayer") }
                try budget.reserve(64)
                textAnimators.append(try readTextAnimator(reader: &block.reader))
            case 29, 65:
                // 同一图层可以有多条样式，原编码顺序决定投影彼此的覆盖顺序。
                dropShadows.append(try readDropShadow(code: block.code, reader: &block.reader))
            case 85:
                guard gradientOverlay == nil else { throw PAGError.unsupportedFeature("multipleGradientOverlay") }
                gradientOverlay = try readGradientOverlay(reader: &block.reader)
            case 56:
                guard type == 5 || type == 6 else { throw PAGError.unsupportedFeature("motionTileNonImage") }
                guard motionTile == nil else { throw PAGError.unsupportedFeature("multipleMotionTile") }
                motionTile = try readMotionTile(reader: &block.reader)
                imageEffectOrder.append(56)
                if type == 6 { precompositionEffectOrder.append(56) }
            case 57:
                guard type == 6, !levelsGreenOnly else {
                    throw PAGError.unsupportedFeature("levelsIndividualLayer")
                }
                try readGreenOnlyLevels(reader: &block.reader)
                levelsGreenOnly = true
                precompositionEffectOrder.append(57)
            case 58:
                guard type == 5 else { throw PAGError.unsupportedFeature("cornerPinNonImage") }
                guard cornerPin == nil else { throw PAGError.unsupportedFeature("multipleCornerPin") }
                cornerPin = try readCornerPin(reader: &block.reader)
                imageEffectOrder.append(58)
            case 59:
                guard type == 3 || type == 5 || type == 6 else {
                    throw PAGError.unsupportedFeature("bulgeNonImageOrText")
                }
                guard bulge == nil else { throw PAGError.unsupportedFeature("multipleBulge") }
                bulge = try readBulge(reader: &block.reader)
                imageEffectOrder.append(59)
                if type == 6 { precompositionEffectOrder.append(59) }
            case 60:
                guard type == 6 || type == 4 else { throw PAGError.unsupportedFeature("fastBlurNonPrecomposition") }
                guard fastBlur == nil else { throw PAGError.unsupportedFeature("multipleFastBlur") }
                fastBlur = try readFastBlur(reader: &block.reader)
                if type == 6 { precompositionEffectOrder.append(60) }
            case 61:
                guard type == 6 else { throw PAGError.unsupportedFeature("glowNonPrecomposition") }
                guard glow == nil else { throw PAGError.unsupportedFeature("multipleGlow") }
                glow = try readGlow(reader: &block.reader)
                precompositionEffectOrder.append(61)
            default:
                throw PAGError.unsupportedFeature("layerTag:\(block.code)")
            }
            try StaticAttributes.requireEnd(of: block.reader)
        }
        guard let attributes, let transform else {
            throw PAGError.invalidFile(reason: "missingLayerAttributesOrTransform", offset: nil)
        }
        if let gradientOverlay {
            // 当前GPU材质只证明了LOGO的单一Shape Angle样式；其它组合先保持明确门禁。
            guard type == 4, !shapes.isEmpty, gradientOverlay.supportsAngleWhiteBlack,
                  attributes.blendMode == .normal, masks.isEmpty, dropShadows.isEmpty,
                  motionTile == nil, bulge == nil, cornerPin == nil,
                  glow == nil, fastBlur == nil, imageEffectOrder.isEmpty,
                  precompositionEffectOrder.isEmpty, attributesExtra?.motionBlur != true else {
                throw PAGError.unsupportedFeature("gradientOverlay")
            }
        }
        if attributesExtra?.motionBlur == true {
            // 上游只比较本层及父层的相邻帧矩阵；仅严格静态且无父层时可证明滤镜每帧跳过。
            let staticSkip = canSkipMotionBlur(transform: transform, parentID: attributes.parentID)
            // Screen平铺、无Effects预合成与图像平铺各有不同输入域，不能共用采样映射。
            let supportedDynamic = type == 6 && attributes.blendMode == .screen &&
                levelsGreenOnly && motionTile != nil && attributes.parentID == nil
            let plainPrecomposition = type == 6 && attributes.blendMode == .normal &&
                attributes.parentID == nil && precompositionEffectOrder.isEmpty &&
                masks.isEmpty && dropShadows.isEmpty
            let tiledImage = type == 5 && attributes.blendMode == .normal &&
                attributes.parentID == nil && imageEffectOrder == [56] &&
                masks.isEmpty && dropShadows.isEmpty &&
                motionTile?.center.isAnimated == false &&
                motionTile?.tileWidth.isAnimated == false &&
                motionTile?.tileHeight.isAnimated == false &&
                motionTile?.outputWidth.isAnimated == false &&
                motionTile?.outputHeight.isAnimated == false &&
                motionTile?.mirrorEdges.isAnimated == false &&
                motionTile?.phase.isAnimated == false &&
                motionTile?.horizontalPhaseShift.isAnimated == false
            guard staticSkip || supportedDynamic || plainPrecomposition || tiledImage else {
                throw PAGError.unsupportedFeature("motionBlur")
            }
        }
        // 上游仅定义0...1的扩散份额；中间值由扩散后Gaussian的局部批次处理。
        guard dropShadows.allSatisfy({ $0.spread.isFinite && (0...1).contains($0.spread) }) else {
            throw PAGError.unsupportedFeature("dropShadowSpread")
        }
        guard dropShadows.allSatisfy({ $0.size.isFinite && $0.size >= 0 }) else {
            throw PAGError.unsupportedFeature("dropShadowNegativeSize")
        }
        if motionTile != nil {
            // 源图层mask必须先作用于输入再重复像素；单图像直采路径暂不偷换为输出裁剪。
            guard masks.isEmpty else { throw PAGError.unsupportedFeature("motionTileLayerMasks") }
            guard dropShadows.isEmpty else { throw PAGError.unsupportedFeature("motionTileLayerStyle") }
        }
        let tileGlowBulge = type == 6 && precompositionEffectOrder == [56, 61, 59] &&
            attributes.blendMode == .normal && attributes.parentID == nil &&
            masks.isEmpty && dropShadows.isEmpty && glow != nil && fastBlur == nil &&
            levelsGreenOnly == false &&
            (attributesExtra?.motionBlur != true ||
             canSkipMotionBlur(transform: transform, parentID: attributes.parentID))
        if type == 6, let bulge {
            // 仅开放有完整局部采样与GPU效果顺序验证的三段组合；非pinning输出范围尚无保守证明。
            guard tileGlowBulge, !bulge.pinning.isAnimated, bulge.pinning.initialValue else {
                throw PAGError.unsupportedFeature("bulgePrecomposition")
            }
        }
        if type == 6, let tile = motionTile {
            // 静态Screen路径与动态三段效果路径有各自的材质和采样域合同。
            let screenTile = levelsGreenOnly && attributes.blendMode == .screen &&
                  tile.center.isAnimated == false && tile.tileWidth.isAnimated == false &&
                  tile.tileHeight.isAnimated == false && tile.outputWidth.isAnimated == false &&
                  tile.outputHeight.isAnimated == false && tile.mirrorEdges.isAnimated == false &&
                  tile.phase.isAnimated == false && tile.horizontalPhaseShift.isAnimated == false &&
                  tile.tileWidth.initialValue == 100 && tile.tileHeight.initialValue == 100 &&
                  tile.outputWidth.initialValue == 300 && tile.outputHeight.initialValue == 300 &&
                  tile.mirrorEdges.initialValue && tile.phase.initialValue == 0 &&
                  !tile.horizontalPhaseShift.initialValue &&
                  precompositionEffectOrder == [57, 56]
            let mappedTile = tileGlowBulge && !tile.outputWidth.isAnimated &&
                !tile.outputHeight.isAnimated && tile.outputWidth.initialValue == 300 &&
                tile.outputHeight.initialValue == 300 &&
                !tile.phase.isAnimated && tile.phase.initialValue == 0 &&
                !tile.horizontalPhaseShift.isAnimated && !tile.horizontalPhaseShift.initialValue
            guard screenTile || mappedTile else {
                throw PAGError.unsupportedFeature("motionTilePrecomposition")
            }
        }
        if bulge != nil {
            // Image直采与Text先合成再取样均不允许图层mask；Text投影在Bulge后由已有外层处理。
            guard motionTile == nil || tileGlowBulge else {
                throw PAGError.unsupportedFeature("bulgeMultipleEffects")
            }
            guard masks.isEmpty else { throw PAGError.unsupportedFeature("bulgeLayerMasks") }
            guard type == 3 || dropShadows.isEmpty else { throw PAGError.unsupportedFeature("bulgeLayerStyle") }
        }
        if cornerPin != nil {
            // 上游逐项按编码顺序作用；目前只有两份真实双效果顺序有可直采等价式。
            guard imageEffectOrder == [58] || imageEffectOrder == [56, 58] ||
                  imageEffectOrder == [58, 59] else {
                throw PAGError.unsupportedFeature("cornerPinEffectOrder")
            }
            guard masks.isEmpty else { throw PAGError.unsupportedFeature("cornerPinLayerMasks") }
            guard dropShadows.isEmpty else { throw PAGError.unsupportedFeature("cornerPinLayerStyle") }
        }
        let shapeBlurBlend = type == 4 && fastBlur != nil && attributes.blendMode == .hardLight
        if shapeBlurBlend {
            // 当前真实层仅含All/Decal FastBlur；其它效果、蒙版或样式会改变源图域与混合顺序。
            guard let fastBlur, !shapes.isEmpty, glow == nil, gradientOverlay == nil,
                  masks.isEmpty, dropShadows.isEmpty, motionTile == nil, bulge == nil,
                  cornerPin == nil, imageEffectOrder.isEmpty, precompositionEffectOrder.isEmpty,
                  attributesExtra?.motionBlur != true,
                  fastBlur.direction.initialValue == 0,
                  fastBlur.repeatEdgePixels.initialValue == false,
                  !fastBlur.direction.isAnimated, !fastBlur.repeatEdgePixels.isAnimated else {
                throw PAGError.unsupportedFeature("shapeFastBlurBlend")
            }
        } else if glow != nil || fastBlur != nil {
            // 当前只开放单Glow或真实Glow→FastBlur；其它排列需要独立合成域与顺序验证。
            let priorGlow = precompositionEffectOrder == [61] ||
                precompositionEffectOrder == [61, 60]
            guard priorGlow || tileGlowBulge,
                  tileGlowBulge || (fastBlur == nil) == (precompositionEffectOrder == [61]),
                  attributes.blendMode == .normal,
                  masks.isEmpty, dropShadows.isEmpty,
                  bulge == nil || tileGlowBulge else {
                throw PAGError.unsupportedFeature("glowEffectOrder")
            }
        }
        if type == 1 { content = .null }
        if type == 4 { content = .shape(shapes) }
        guard let content else { throw PAGError.invalidFile(reason: "missingLayerContent", offset: nil) }
        guard attributes.blendMode == .normal ||
              (attributes.blendMode == .screen && type == 6) || shapeBlurBlend else {
            throw PAGError.unsupportedFeature("layerBlendMode")
        }
        guard !levelsGreenOnly || attributes.blendMode == .screen else {
            throw PAGError.unsupportedFeature("levelsIndividualBlend")
        }
        return SourceLayer(id: id, name: attributesExtra?.name ?? attributes.name, parentID: attributes.parentID,
                           startFrame: attributes.start, durationFrames: attributes.duration,
                           isActive: attributes.isActive, trackMatte: attributes.trackMatte,
                           blendMode: attributes.blendMode, levelsGreenOnly: levelsGreenOnly,
                           motionBlur: attributesExtra?.motionBlur == true,
                           transform: transform, content: content,
                           masks: masks, textPath: textPath, textAnimators: textAnimators,
                           dropShadows: dropShadows, gradientOverlay: gradientOverlay,
                           motionTile: motionTile, bulge: bulge,
                           cornerPin: cornerPin, glow: glow, fastBlur: fastBlur, markers: markers,
                           timing: attributes.timing, imageFillRule: imageFillRule)
    }

    /// 读取LayerAttributes三个版本，保留完整层时间元数据；尚未支持的画面语义仍拒绝。
    mutating func readLayerAttributes(code: UInt16, reader: inout PAGByteReader) throws -> LayerAttributes {
        try Task.checkCancellation()
        var encodings: [AttributeEncoding] = [.flag, .flag]
        if code == 62 { encodings.append(.flag) }
        encodings += [.flag, .flag, .flag, .flag, .flag, .property, .fixed]
        if code != 6 { encodings.append(.flag) }
        let f = try PropertyFlags.read(encodings, from: &reader)
        guard !f[1].exists else { throw PAGError.unsupportedFeature("autoOrientation") }
        if code == 62, f[2].exists { throw PAGError.unsupportedFeature("motionBlur") }
        let p = code == 62 ? 3 : 2
        let parent = try f[p].exists ? reader.readEncodedUInt32() : 0
        let numerator = try f[p + 1].exists ? reader.readEncodedInt32() : 1
        let denominator = try f[p + 1].exists ? reader.readEncodedUInt32() : 1
        guard denominator > 0 else {
            throw SceneValidator.invalid("zeroLayerStretchDenominator")
        }
        let start = try f[p + 2].exists ? StaticAttributes.frame(from: &reader) : 0
        let rawBlendMode = try f[p + 3].exists ? reader.readUInt8() : 0
        guard let blendMode = SourceLayerBlendMode(rawValue: rawBlendMode) else {
            throw PAGError.unsupportedFeature("layerBlendMode")
        }
        let rawTrackMatte = try f[p + 4].exists ? reader.readUInt8() : 0
        // 上游枚举仅有0...4；未知字节不是一个可按Alpha或None降级的合法模式。
        guard let trackMatte = SourceTrackMatteType(rawValue: rawTrackMatte) else {
            throw PAGError.invalidFile(reason: "unknownTrackMatteType", offset: reader.position - 1)
        }
        // Layer::excludeVaryingRanges只用此轨道阻止静态复用；不能拿它代替预合成或图片素材的时钟。
        let timeRemap = try readScalarProperty(f[p + 5], defaultValue: 0, reader: &reader)
        let duration = try StaticAttributes.frame(from: &reader)
        let name = try code != 6 && f[p + 7].exists ? reader.readUTF8String() : ""
        guard duration > 0 else { throw PAGError.invalidFile(reason: "nonpositiveLayerDuration", offset: nil) }
        return LayerAttributes(isActive: f[0].exists, parentID: parent == 0 ? nil : parent,
            start: start, duration: duration, name: name,
            timing: SourceLayerTiming(stretchNumerator: numerator, stretchDenominator: denominator, timeRemap: timeRemap),
            trackMatte: trackMatte, blendMode: blendMode)
    }

    /// 读取tag63的可选名称与运动模糊标记；是否可播放由完整图层变换决定。
    private func readLayerAttributesExtra(reader: inout PAGByteReader) throws -> (name: String?, motionBlur: Bool) {
        let flags = try PropertyFlags.read([.flag, .flag], from: &reader)
        let name = try flags[0].exists ? reader.readUTF8String() : nil
        return (name, flags[1].exists)
    }

    /// 仅在上游相邻帧矩阵必然相等时接受已编码但无实际效果的运动模糊。
    private func canSkipMotionBlur(transform: SourceTransformProperties, parentID: UInt32?) -> Bool {
        guard parentID == nil, !transform.anchor.isAnimated, !transform.scale.isAnimated,
              !transform.rotation.isAnimated else { return false }
        switch transform.position {
        case .combined(let value): return !value.isAnimated
        case .separated(let x, let y): return !x.isAnimated && !y.isAnimated
        }
    }

    /// SolidColor.cpp 先读 RGB，再读编码 Int32 尺寸；单色层必须具有正尺寸。
    private func readSolid(reader: inout PAGByteReader) throws -> SourceLayerContent {
        let color = try StaticAttributes.color(from: &reader)
        let width = try reader.readEncodedInt32()
        let height = try reader.readEncodedInt32()
        guard width > 0, height > 0 else { throw PAGError.invalidFile(reason: "invalidSolidSize", offset: nil) }
        return .solid(size: try PAGSize(width: Double(width), height: Double(height)), color: color)
    }
}

/// 基础图层属性暂存，默认行为已在读取时显式建立。
struct LayerAttributes {
    /// BitFlag 直接表示显示开关，零不能改成默认 true。
    let isActive: Bool
    /// 同级父变换源 ID；零编码转为 nil。
    let parentID: UInt32?
    /// 允许为负的起始帧。
    let start: Int64
    /// 正帧区间长度。
    let duration: Int64
    /// V2/V3 可选名称；旧版为空。
    let name: String
    /// 已完整读取的层时间元数据；完整层失败时随暂存值丢弃。
    let timing: SourceLayerTiming
    /// 已校验的轨道遮罩文件值；非None尚不能作为可播放图层发布。
    let trackMatte: SourceTrackMatteType
    /// 经原始单字节值验证的整层混合模式。
    let blendMode: SourceLayerBlendMode
}
