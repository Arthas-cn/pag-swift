/// 文件时间设置的读取；字节规则来自TimeStretchMode.cpp，不借用图层属性编码。
extension PAGSceneDecoder {
    /// 保留单个tag32的模式与可选原始帧范围；重复、未知模式、截断、预算或取消均失败。
    mutating func readFileTiming(reader: inout PAGByteReader) throws {
        try Task.checkCancellation()
        guard fileTiming == nil else { throw SceneValidator.invalid("duplicateTimeStretchMode") }
        try budget.reserve(64)
        let rawMode = try reader.readUInt8()
        guard let mode = SourceTimeStretchMode(rawValue: rawMode) else {
            throw PAGError.unsupportedFeature("timeStretchMode:\(rawMode)")
        }
        // 源码readBoolean消费完整字节且以非零为true，不能把它和后面的ReadTime拼成位流。
        let hasRange = try reader.readUInt8() != 0
        var range: SourceTimeRange?
        if hasRange {
            range = SourceTimeRange(start: try StaticAttributes.frame(from: &reader),
                                    end: try StaticAttributes.frame(from: &reader))
        }
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        // 原始总时长未修改时，上游gotoTime直接委托合成；保留设置不触发额外循环或伸缩。
        fileTiming = SourceFileTiming(mode: mode, scaledRange: range)
    }
}
