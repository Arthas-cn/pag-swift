/// 快照范围的纯值身份门禁；缓存命中、禁用缓存和资源不足都不能绕过原计划验证。
enum MetalPictureRangeValidator {
    /// 核对Shape源几何或Text完整轮次及实例；非法计划抛渲染错误，不作为可选缓存miss。
    static func validate(_ commands: ArraySlice<FrameCommand>, picture: FramePicture,
                         frame: PreparedFrame) throws {
        var opacityDepth = 0
        var nextTextPass = 0
        let expectedTextPasses: Int
        switch picture.content {
        case .shape:
            expectedTextPasses = 0
        case .text(let resourceID, let layerID):
            guard picture.document == layerID.document,
                  let prepared = frame.texts[resourceID], prepared.identity == resourceID,
                  prepared.source == picture.source,
                  !prepared.passes.isEmpty else {
                throw PAGError.renderingFailure("metalPictureTextIdentity")
            }
            expectedTextPasses = prepared.passes.count
        }
        for command in commands {
            try Task.checkCancellation()
            switch command {
            case .beginOpacityGroup:
                guard case .shape = picture.content else {
                    throw PAGError.renderingFailure("metalPictureUnexpectedCommand")
                }
                opacityDepth += 1
            case .endOpacityGroup:
                opacityDepth -= 1
                guard opacityDepth >= 0 else { throw PAGError.renderingFailure("metalPictureOpacityScope") }
            case .shape(let paint):
                guard case .shape = picture.content,
                      paint.geometryID.document == picture.document,
                      paint.geometryID.source == picture.source,
                      paint.geometryID.sampleFrame == nil,
                      paint.matrix == picture.matrix,
                      frame.shapes[paint.geometryID] != nil else {
                    throw PAGError.renderingFailure("metalPictureShapeIdentity")
                }
            case .text(let pass):
                guard case .text(let resourceID, let layerID) = picture.content,
                      pass.resourceID == resourceID, pass.layerID == layerID,
                      pass.matrix == picture.matrix, pass.passIndex == nextTextPass,
                      nextTextPass < expectedTextPasses else {
                    throw PAGError.renderingFailure("metalPictureTextIdentity")
                }
                nextTextPass += 1
            default:
                throw PAGError.renderingFailure("metalPictureUnexpectedCommand")
            }
        }
        guard opacityDepth == 0 else { throw PAGError.renderingFailure("metalPictureOpacityScope") }
        guard nextTextPass == expectedTextPasses else {
            throw PAGError.renderingFailure("metalPictureTextIdentity")
        }
    }
}
