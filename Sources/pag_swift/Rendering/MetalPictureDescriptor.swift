import Foundation

/// Shape或Text内容局部纹理的尺寸和双向映射；不把祖先裁剪或图层alpha烘进快照。
struct MetalPictureDescriptor {
    /// 完整源内容、编辑代数及实际像素网格身份。
    let key: MetalPictureKey
    /// 从内容局部坐标到内容纹理像素的矩阵。
    let localToTexture: SceneAffine
    /// 从单位纹理矩形到当前实例显示像素的矩阵。
    let textureToDisplay: SceneAffine
    /// 仅含内部Shape paint或Text pass及内部透明组的局部绘制，不含Picture标记及外层alpha。
    let commands: [FrameCommand]

    /// 从Shape/Text真实Metal网格取得局部紧边界；过小尺度或空内容返回nil供原命令展开。
    static func make(_ picture: FramePicture, commands: ArraySlice<FrameCommand>,
                     frame: PreparedFrame, resources: MetalResources,
                     revision: UInt64, budget: inout MetalFrameBudget) throws -> Self? {
        let matrix = picture.matrix
        guard let scale = textureScale(for: matrix) else { return nil }
        let scaleMatrix = try SceneAffine.scale(x: scale, y: scale)
        var bounds: RenderBounds?
        for command in commands {
            try Task.checkCancellation()
            switch command {
            case .shape(let paint):
                guard case .shape = picture.content,
                      paint.geometryID.document == picture.document, paint.geometryID.source == picture.source,
                      paint.geometryID.sampleFrame == nil, let geometry = frame.shapes[paint.geometryID] else {
                    throw PAGError.renderingFailure("metalPictureShapeIdentity")
                }
                guard let mesh = try resources.geometry(.shape(geometry), transform: scaleMatrix,
                                                        budget: &budget) else { continue }
                let local = try mesh.bounds.transformed(by: .identity, origin: mesh.source.origin)
                bounds = bounds.map { $0.union(local) } ?? local
            case .text(let pass):
                guard case .text(let resourceID, let layerID) = picture.content,
                      pass.resourceID == resourceID, pass.layerID == layerID,
                      let prepared = frame.texts[resourceID], prepared.identity == resourceID,
                      prepared.source == picture.source,
                      prepared.passes.indices.contains(pass.passIndex) else {
                    throw PAGError.renderingFailure("metalPictureTextIdentity")
                }
                for glyph in prepared.glyphs {
                    try Task.checkCancellation()
                    let outline: GlyphOutline?
                    switch prepared.passes[pass.passIndex] {
                    case .fill: outline = glyph.fill
                    case .stroke: outline = glyph.stroke
                    }
                    guard let outline else { continue }
                    let glyphScale = try glyph.matrix.following(scaleMatrix)
                    guard let mesh = try resources.geometry(.glyph(outline), transform: glyphScale,
                                                            budget: &budget) else { continue }
                    let local = try MetalDrawTransform(matrix: glyph.matrix,
                                                       origin: mesh.source.origin).bounds(mesh.bounds)
                    bounds = bounds.map { $0.union(local) } ?? local
                }
            default:
                break
            }
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
        let textureToDisplay = try textureToLocal.following(matrix)
        let textResource: TextResourceID?
        switch picture.content {
        case .shape: textResource = nil
        case .text(let identity, _): textResource = identity
        }
        let key = MetalPictureKey(document: picture.document, source: picture.source, textResource: textResource,
                                  revision: revision,
                                  scaleBits: scale.bitPattern, originX: x, originY: y,
                                  width: width.partialValue, height: height.partialValue)
        var localCommands: [FrameCommand] = []
        localCommands.reserveCapacity(commands.count)
        for command in commands {
            try Task.checkCancellation()
            switch command {
            case .shape(let paint):
                localCommands.append(.shape(FrameShape(layerID: paint.layerID, geometryID: paint.geometryID,
                                                        matrix: localToTexture, material: paint.material,
                                                        opacity: paint.opacity)))
            case .text(let pass):
                localCommands.append(.text(FrameText(layerID: pass.layerID, resourceID: pass.resourceID,
                                                      passIndex: pass.passIndex, matrix: localToTexture)))
            case .beginOpacityGroup, .endOpacityGroup:
                localCommands.append(command)
            default:
                throw PAGError.renderingFailure("metalPictureUnexpectedCommand")
            }
        }
        return Self(key: key, localToTexture: localToTexture,
                    textureToDisplay: textureToDisplay, commands: localCommands)
    }

    /// 取最大奇异值的上八分档并保证真实分辨率不低于本次实例所需；极小或非有限返回nil。
    static func textureScale(for matrix: SceneAffine) -> Double? {
        let firstColumn = hypot(matrix.a, matrix.b)
        let secondColumn = hypot(matrix.c, matrix.d)
        let dot = matrix.a * matrix.c + matrix.b * matrix.d
        let squared = (firstColumn * firstColumn + secondColumn * secondColumn
                       + hypot(firstColumn * firstColumn - secondColumn * secondColumn, 2 * dot)) / 2
        let required = sqrt(squared)
        guard required.isFinite, required >= 0.001 else { return nil }
        let exponent = ceil(log2(required) * 8) / 8
        let bucket = exp2(exponent)
        guard bucket.isFinite, bucket > 0 else { return nil }
        // 同档浮点舍入不能使缓存纹理低于本次显示所需的真实分辨率。
        let scale = max(required, bucket.nextUp)
        guard scale.isFinite, scale > 0 else { return nil }
        return scale
    }
}
