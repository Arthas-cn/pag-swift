/// ImageFillRule字段读取；只生成源规则，实例时钟在后台场景准备时建立。
extension PAGSceneDecoder {
    /// 按ImageFillRule.cpp完整读取54/67；未知模式、损坏、预算或取消均不返回部分规则。
    mutating func readImageFillRule(code: UInt16, reader: inout PAGByteReader) throws -> SourceImageFillRule {
        try Task.checkCancellation()
        guard code == 54 || code == 67 else { throw PAGError.unsupportedFeature("imageFillRuleVersion:\(code)") }
        try budget.reserve(128)
        let flags = try PropertyFlags.read([.flag, .property], from: &reader)
        let raw = try flags[0].exists ? reader.readUInt8() : 2
        let mode: PAGScaleMode
        switch raw {
        case 0: mode = .none
        case 1: mode = .stretch
        case 2: mode = .aspectFit
        case 3: mode = .aspectFill
        default: throw PAGError.unsupportedFeature("imageScaleMode:\(raw)")
        }
        var property = try readFrameProperty(flags[1], reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        if code == 54, property.isAnimated {
            // V1曾把Linear写为Hold；必须先消费原缓动载荷，再按源码整体修正，不影响V2。
            var frames: [SourceKeyframe<Int64>] = []
            for key in property.keyframes {
                try Task.checkCancellation()
                frames.append(SourceKeyframe(startFrame: key.startFrame, endFrame: key.endFrame,
                    startValue: key.startValue, endValue: key.endValue, easing: .linear, spatialCurve: nil))
            }
            property = try SourceProperty(keyframes: frames)
        }
        try Task.checkCancellation()
        return SourceImageFillRule(scaleMode: mode, timeRemap: property)
    }
}
