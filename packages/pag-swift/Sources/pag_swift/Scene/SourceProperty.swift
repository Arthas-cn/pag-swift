/// 一个已验证的连续关键帧段，帧区间右开；值与预计算曲线都是不可变资源。
struct SourceKeyframe<Value: Sendable>: Sendable {
    /// 当前段在所属合成坐标中的起始帧。
    let startFrame: Int64
    /// 当前段右开终点，允许等于起点作为端点记录，差值不能为负或溢出。
    let endFrame: Int64
    /// 起点值，Hold 在整个右开区间返回它。
    let startValue: Value
    /// 右端值，也作为下一连续段的起点值。
    let endValue: Value
    /// 时间进度如何变为插值比例；二维属性可分别缓动。
    let easing: SourceEasing
    /// 仅空间 Point 属性拥有的累计长度曲线；nil 表示直接插值值分量。
    let spatialCurve: SampledCurve?
}

/// 关键帧的时间插值模式，与空间路径几何分别保存。
enum SourceEasing: Sendable {
    /// 整个区间保持起点值，在端点由下一段或末值接管。
    case hold
    /// 时间比例直接作为所有分量的插值比例。
    case linear
    /// first 是第一分量/共享曲线，second 非 nil 时仅用于二维属性的 y 分量。
    case bezier(first: SampledCurve, second: SampledCurve?)
}

/// 常量或不可变动画轨道；无跨线程可变的“上次关键帧下标”。
struct SourceProperty<Value: Sendable>: Sendable {
    /// 常量值，或首关键帧的起点值；初始化后始终有效。
    let initialValue: Value
    /// 空表示常量，否则按起始帧不降且连续；零跨度仍保留原始两个端值。
    let keyframes: [SourceKeyframe<Value>]
    /// 是否有显式关键帧；值相同的轨道仍属于动画。
    var isAnimated: Bool { !keyframes.isEmpty }

    /// 构造常量；值的有限性/类型范围由对应读取器校验。
    init(constant: Value) {
        initialValue = constant
        keyframes = []
    }

    /// 构造动画并校验时间拓扑；空列表、倒序/溢出区间或不连续时间抛invalidFile，允许零跨度。
    init(keyframes: [SourceKeyframe<Value>]) throws {
        guard let first = keyframes.first else { throw SceneValidator.invalid("emptyKeyframes") }
        for (index, frame) in keyframes.enumerated() {
            try Task.checkCancellation()
            guard frame.endFrame >= frame.startFrame,
                  !frame.endFrame.subtractingReportingOverflow(frame.startFrame).overflow,
                  index == 0 || keyframes[index - 1].endFrame == frame.startFrame else {
                throw SceneValidator.invalid("invalidKeyframeTimes")
            }
        }
        initialValue = first.startValue
        self.keyframes = keyframes
    }

    /// 二分查找右侧有效段，连续零跨度取最后一个；轨道外选择首末段，常量返回nil。
    func keyframe(at frame: Int64) -> SourceKeyframe<Value>? {
        guard !keyframes.isEmpty else { return nil }
        var low = 0
        var high = keyframes.count - 1
        while low < high {
            let middle = low + (high - low) / 2
            // 同一端点可有零跨度段；一直向右跳过它们，保证seek结果不依赖共享历史游标。
            if frame >= keyframes[middle].endFrame { low = middle + 1 }
            else { high = middle }
        }
        return keyframes[low]
    }
}
