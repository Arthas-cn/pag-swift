/// 对不可变轨道做纯数值求值，二分定位关键帧；不维护共享的可变游标。
enum PropertyEvaluation {
    /// RGB使用同一时间缓动，逐通道Float插值后钳位并向零截断，与Interpolate<Color/uint8_t>一致。
    static func color(_ property: SourceProperty<SceneColor>, at frame: Int64) throws -> SceneColor {
        try Task.checkCancellation()
        return try value(property, at: frame) { keyframe, progress in
            let amount = eased(progress, by: keyframe.easing, secondDimension: false)
            return try SceneColor(red: colorChannel(keyframe.startValue.red, keyframe.endValue.red, progress: amount),
                                  green: colorChannel(keyframe.startValue.green, keyframe.endValue.green, progress: amount),
                                  blue: colorChannel(keyframe.startValue.blue, keyframe.endValue.blue, progress: amount))
        }
    }

    /// 颜色通道先采用与标量相同的Float次序；缓动overshoot可超界，但最终字节不能绕回。
    static func colorChannel(_ start: UInt8, _ end: UInt8, progress: Float) throws -> UInt8 {
        UInt8(min(max(try interpolate(Double(start), Double(end), progress: progress), 0), 255))
    }

    /// 路径端点/常量/Hold共享原值，仅严格段内的形变分配新路径；预算、损坏拓扑与取消均向上传播。
    static func path(_ property: SourceProperty<SourcePath>, at frame: Int64,
                     budget: inout FramePlanBudget) throws -> SourcePath {
        try Task.checkCancellation()
        return try value(property, at: frame) { keyframe, progress in
            try PathInterpolation.interpolate(keyframe.startValue, keyframe.endValue,
                progress: eased(progress, by: keyframe.easing, secondDimension: false), budget: &budget)
        }
    }

    /// 求值 Float32 来源标量，保持上游浮点插值次序；溢出抛 invalidFile。
    static func scalar(_ property: SourceProperty<Double>, at frame: Int64) throws -> Double {
        try value(property, at: frame) { keyframe, progress in
            try interpolate(keyframe.startValue, keyframe.endValue,
                            progress: eased(progress, by: keyframe.easing, secondDimension: false))
        }
    }

    /// 求值二维属性；空间属性沿弧长取点，普通二维属性允许 x/y 独立缓动。
    static func point(_ property: SourceProperty<ScenePoint>, at frame: Int64) throws -> ScenePoint {
        try value(property, at: frame) { keyframe, progress in
            let xProgress = eased(progress, by: keyframe.easing, secondDimension: false)
            if let path = keyframe.spatialCurve { return path.position(at: xProgress) }
            let yProgress = eased(progress, by: keyframe.easing, secondDimension: true)
            return try ScenePoint(x: interpolate(keyframe.startValue.x, keyframe.endValue.x, progress: xProgress),
                                  y: interpolate(keyframe.startValue.y, keyframe.endValue.y, progress: yProgress))
        }
    }

    /// UInt8 opacity 先浮点插值，再按 Interpolate<uint8_t> 钳位并向零截断。
    static func opacity(_ property: SourceProperty<UInt8>, at frame: Int64) throws -> UInt8 {
        try value(property, at: frame) { keyframe, progress in
            let result = try interpolate(Double(keyframe.startValue), Double(keyframe.endValue),
                                         progress: eased(progress, by: keyframe.easing, secondDimension: false))
            return UInt8(min(max(result, 0), 255))
        }
    }

    /// 常量与区间端点先处理，零跨度只选端值；只有严格位于非空段内的时间才计算比例。
    static func value<Value>(_ property: SourceProperty<Value>, at frame: Int64,
                                     interpolate: (SourceKeyframe<Value>, Float) throws -> Value) throws -> Value {
        guard let keyframe = property.keyframe(at: frame) else { return property.initialValue }
        // 次序不可交换：单独或尾部零跨度在唯一端点返回startValue，不进入后面的除法。
        if frame <= keyframe.startFrame { return keyframe.startValue }
        if frame >= keyframe.endFrame { return keyframe.endValue }
        if case .hold = keyframe.easing { return keyframe.startValue }
        // 前两个端点分支排除了零跨度；构造时已验证减法不溢出，段内分子也必然可表示。
        let progress = Float(frame - keyframe.startFrame) / Float(keyframe.endFrame - keyframe.startFrame)
        return try interpolate(keyframe, progress)
    }

    /// 二维第二分量可选独立曲线；单缓动 Point 的两个分量共用 first。
    static func eased(_ progress: Float, by easing: SourceEasing, secondDimension: Bool) -> Float {
        switch easing {
        case .hold: 0
        case .linear: progress
        case .bezier(let first, let second): (secondDimension ? (second ?? first) : first).timing(at: progress)
        }
    }

    /// 上游标量源值与中间计算均为 Float；完成后扩为 Double 供矩阵层使用。
    private static func interpolate(_ start: Double, _ end: Double, progress: Float) throws -> Double {
        let a = Float(start)
        let result = a + (Float(end) - a) * progress
        guard result.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
        return Double(result)
    }
}
