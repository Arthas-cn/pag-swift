import Foundation

/// PAG 内嵌视频的只读合成内容；不代表独立 MP4，也不创建可编辑图片层。
struct SourceVideoComposition: Sendable {
    /// 编码顺序的全部视频分辨率；实际显示使用最后一条。
    let sequences: [SourceVideoSequence]
    /// 最高帧率序列的静态区间转换到合成帧后的闭区间。
    let staticRanges: [ClosedRange<Int64>]
    /// 可选容器优化头与序列一一对应；原生 NAL 路径不使用它，nil 表示未提供。
    let mp4Headers: [Data?]

    /// 按 VideoComposition::updateStaticTimeRanges 建立时间映射，非法比率或时间溢出失败。
    init(sequences: [SourceVideoSequence], mp4Headers: [Data?], frameRate: Double) throws {
        guard var highest = sequences.first, sequences.count == mp4Headers.count else {
            throw SceneValidator.invalid("missingVideoSequence")
        }
        for sequence in sequences.dropFirst() where sequence.frameRate > highest.frameRate { highest = sequence }
        let ratio = Float(frameRate) / Float(highest.frameRate)
        guard ratio.isFinite, ratio > 0 else { throw SceneValidator.invalid("videoTimeScale") }
        var ranges: [ClosedRange<Int64>] = []
        for range in highest.staticRanges {
            try Task.checkCancellation()
            guard let start = Int64(exactly: (Float(range.lowerBound) * ratio).rounded()),
                  let end = Int64(exactly: (Float(range.upperBound) * ratio).rounded()), start <= end else {
                throw SceneValidator.invalid("videoStaticRange")
            }
            ranges.append(start...end)
        }
        self.sequences = sequences
        self.mp4Headers = mp4Headers
        staticRanges = ranges
    }

    /// 将合法合成帧折叠/换算到逻辑序列帧；PTS空洞由序列样本选择单独处理。
    func frame(at frame: Int64, frameRate: Double) throws -> Int64 {
        guard let sequence = sequences.last, frame >= 0 else { throw SceneValidator.invalid("videoFrame") }
        var mapped = frame
        var lower = 0
        var upper = staticRanges.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let range = staticRanges[middle]
            if range.lowerBound > frame { upper = middle - 1 }
            else if range.upperBound < frame { lower = middle + 1 }
            else {
                mapped = range.lowerBound
                break
            }
        }
        // 源码先执行 Float32 除法，再以 Double 乘帧并四舍五入，不能提前合并运算。
        let value = (Double(mapped) * Double(Float(sequence.frameRate) / Float(frameRate))).rounded()
        guard value.isFinite, value >= 0 else { throw SceneValidator.invalid("videoTimeScale") }
        if value >= Double(sequence.samples.count - 1) { return Int64(sequence.samples.count - 1) }
        return Int64(value)
    }
}

/// 已验证布局和索引的 H.264 序列；仅保存压缩输入与可发送元数据。
struct SourceVideoSequence: Sendable {
    /// 完整序列载荷的内容摘要，不受所在文件路径或合成编号影响。
    let identity: DocumentIdentity
    /// 正可见像素宽度，不包含 alpha 区域和偶数补齐。
    let width: Int
    /// 正可见像素高度，不包含 alpha 区域和偶数补齐。
    let height: Int
    /// alpha 区域的非负横向偏移；两个偏移均为0时为不透明视频。
    let alphaStartX: Int
    /// alpha 区域的非负纵向偏移，可与横向偏移同时存在。
    let alphaStartY: Int
    /// 源 Float32 帧率，逻辑帧到微秒仍由共同时间工具换算。
    let frameRate: Double
    /// 不带额外4字节前缀的原始SPS NAL，CoreMedia负责解释H.264位流。
    let sps: Data
    /// 不带额外4字节前缀的原始PPS NAL。
    let pps: Data
    /// 严格编码顺序，不能为方便显示直接排序此数组。
    let samples: [SourceVideoSample]
    /// 按PTS升序排列的样本索引，与samples共用资源，不复制NAL。
    let presentationOrder: [Int]
    /// 编码索引按升序保存；读取时验证关键帧PTS等于该索引。
    let keyframes: [Int]
    /// 原始序列帧坐标中的静态闭区间，不是微秒。
    let staticRanges: [ClosedRange<Int64>]
    /// CoreMedia从SPS解析出的输出尺寸，与PAG声明的颜色/alpha区域已核对。
    let decodedSize: PAGSize

    /// 对齐到偶数的声明解码宽度；PAG保留独立的奇数可见尺寸。
    var videoWidth: Int { (width + alphaStartX + 1) / 2 * 2 }
    /// 对齐到偶数的声明解码高度，不能以可见高度代替平面高度。
    var videoHeight: Int { (height + alphaStartY + 1) / 2 * 2 }
    /// 是否使用PAG自身的透明度区域，不依赖VAP布局。
    var hasAlpha: Bool { alphaStartX != 0 || alphaStartY != 0 }

    /// 返回PTS不早于目标的首个编码索引；目标晚于所有样本时使用最后输出帧。
    func sampleIndex(at frame: Int64) -> Int {
        var lower = 0
        var upper = presentationOrder.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[presentationOrder[middle]].frame < frame { lower = middle + 1 }
            else { upper = middle }
        }
        return presentationOrder[min(lower, presentationOrder.count - 1)]
    }

    /// 返回目标逻辑帧之前最近关键帧的编码索引；首关键帧在0，负输入也落到0。
    func keyframeIndex(before frame: Int64) -> Int {
        var lower = 0
        var upper = keyframes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Int64(keyframes[middle]) <= frame { lower = middle + 1 }
            else { upper = middle }
        }
        return keyframes[max(0, lower - 1)]
    }
}

/// 一帧原始H.264压缩输入；显示时间与编码顺序分别保存。
struct SourceVideoSample: Sendable {
    /// 文件中的非负PTS帧号，不要求连续或小于samples.count。
    let frame: Int64
    /// 是否是可独立开始解码的关键帧，与上游seek假定一起校验。
    let isKeyframe: Bool
    /// 未添加AVCC长度的原始单个NAL，文件长度前缀已移除。
    let data: Data
}

/// 同一个完整序列中的实际呈现帧身份，跨实例可共享只读GPU输入。
struct VideoFrameID: Sendable, Hashable {
    /// 编码序列摘要，包括尺寸、alpha布局和全部NAL。
    let sequence: DocumentIdentity
    /// 实际样本PTS；缺失目标PTS时不能把请求帧号冒充此值。
    let frame: Int64
}
