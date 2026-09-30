import Foundation

/// 上游 BezierPath 规则生成的不可变折线，用于时间缓动或空间弧长采样。
struct SampledCurve: Sendable {
    /// 按参数从小到大排列的端点与累计长度，至少有两项。
    private let samples: [CurveSample]
    /// 折线总长度；首末退化重合时可以为零。
    private let length: Float
    /// 内部诊断使用的实际段点数，资源成本以此计费。
    var sampleCount: Int { samples.count }

    /// 仅构建器能发布非空且长度有限的采样结果。
    private init(samples: [CurveSample], length: Float) {
        self.samples = samples
        self.length = length
    }

    /// 按源码精度细分三次曲线，检查取消和预算；坐标不可表示时抛 invalidFile。
    static func make(start: ScenePoint, control1: ScenePoint, control2: ScenePoint, end: ScenePoint,
                     precision: Float, budget: inout DecodeBudget) throws -> SampledCurve {
        let cubic = try CurvePiece(start: start, control1: control1, control2: control2, end: end)
        guard precision.isFinite, precision > 0 else { throw SceneValidator.invalid("invalidCurvePrecision") }
        // 参数最多二十余次二分；预留有界 DFS 工作栈，结果点则逐个计费，不能先无界生成。
        try budget.reserve(2048)
        try budget.reserve(32)
        var samples = [CurveSample(point: cubic.start, distance: 0)]
        var length: Float = 0
        let collinear = cubic.isCollinear(precision: precision)
        var stack = [cubic]
        while let piece = stack.popLast() {
            try Task.checkCancellation()
            if !collinear, (piece.maximumT - piece.minimumT) >> 10 != 0, piece.isCurved(precision: precision) {
                let (left, right) = piece.split()
                // 栈先进右段，再处理左段，确保记录的空间点和累计长度维持源参数顺序。
                stack.append(right)
                stack.append(left)
            } else {
                let dx = piece.end.x - piece.start.x
                let dy = piece.end.y - piece.start.y
                length += sqrt(dx * dx + dy * dy)
                guard length.isFinite else { throw SceneValidator.invalid("unrepresentableCurve") }
                try budget.reserve(32)
                samples.append(CurveSample(point: piece.end, distance: length))
            }
        }
        return SampledCurve(samples: samples, length: length)
    }

    /// 按时间曲线的 x 查询 y；端点钳到 0/1，内部 y 保留 overshoot。
    func timing(at progress: Float) -> Float {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        let (start, end) = segment(at: progress, usesDistance: false)
        let width = end.point.x - start.point.x
        guard width != 0 else { return start.point.y }
        let fraction = (progress - start.point.x) / width
        return start.point.y + (end.point.y - start.point.y) * fraction
    }

    /// 按累计弧长比例采样空间点；缓动越过端点时遵循上游保持首末点。
    func position(at progress: Float) -> ScenePoint {
        if progress <= 0 { return samples[0].point.scenePoint }
        if progress >= 1 { return samples[samples.count - 1].point.scenePoint }
        let distance = length * progress
        let (start, end) = segment(at: distance, usesDistance: true)
        let span = end.distance - start.distance
        let fraction = span == 0 ? 0 : (distance - start.distance) / span
        return start.point.interpolated(to: end.point, fraction: fraction).scenePoint
    }

    /// 时间曲线按 x、空间曲线按累计长度二分；构建器保证有首末点。
    private func segment(at value: Float, usesDistance: Bool) -> (CurveSample, CurveSample) {
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            let coordinate = usesDistance ? samples[middle].distance : samples[middle].point.x
            if value < coordinate { high = middle } else { low = middle }
        }
        return (samples[low], samples[high])
    }
}

/// 保持上游 Float 插值次序的内部曲线坐标，不改变其他场景矩阵的 Double 表示。
private struct CurvePoint: Sendable {
    /// 有限横坐标。
    let x: Float
    /// 有限纵坐标。
    let y: Float
    /// 仅在发布求值结果时扩展为场景 Double 坐标。
    var scenePoint: ScenePoint { ScenePoint(x: Double(x), y: Double(y)) }

    /// 以 a + (b-a)*t 的上游次序插值；合法曲线输入的中间值不越过 Float 范围。
    func interpolated(to end: CurvePoint, fraction: Float) -> CurvePoint {
        CurvePoint(x: x + (end.x - x) * fraction, y: y + (end.y - y) * fraction)
    }
}

/// 折线采样的一点；累计距离允许与前一点相等，表示退化短段。
private struct CurveSample: Sendable {
    /// 三次曲线细分后的端点。
    let point: CurvePoint
    /// 从整条曲线起点累积的有限非负长度。
    let distance: Float
}

/// DFS 工作栈内的一段三次曲线；以整数参数跨度复现上游细分停止条件。
private struct CurvePiece {
    /// 当前段的起点。
    let start: CurvePoint
    /// 当前段的第一控制点。
    let control1: CurvePoint
    /// 当前段的第二控制点。
    let control2: CurvePoint
    /// 当前段的终点。
    let end: CurvePoint
    /// 当前段在 0...0x3fffffff 中的起始参数。
    let minimumT: UInt32
    /// 当前段的结束参数，大于 minimumT。
    let maximumT: UInt32

    /// 建立整条曲线；过大或非有限坐标不能进入 Float 细分。
    init(start: ScenePoint, control1: ScenePoint, control2: ScenePoint, end: ScenePoint) throws {
        let points = [start, control1, control2, end].map { CurvePoint(x: Float($0.x), y: Float($0.y)) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw SceneValidator.invalid("unrepresentableCurve")
        }
        self.init(start: points[0], control1: points[1], control2: points[2], end: points[3],
                  minimumT: 0, maximumT: 0x3fff_ffff)
    }

    /// 保存 De Casteljau 已计算出的子段；参数范围由 split 保证有效。
    private init(start: CurvePoint, control1: CurvePoint, control2: CurvePoint, end: CurvePoint,
                 minimumT: UInt32, maximumT: UInt32) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
        self.minimumT = minimumT
        self.maximumT = maximumT
    }

    /// 沿用 BezierPath::PointOnLine 面积判定，首末重合时也会选择退化直线。
    func isCollinear(precision: Float) -> Bool {
        [control1, control2].allSatisfy { point in
            let area = start.x * end.y + start.y * point.x + end.x * point.y
                - point.x * end.y - point.y * start.x - end.x * start.y
            return abs(area) < precision
        }
    }

    /// 比较控制点与首末连线三分点的最大轴向偏差，对应 CubicTooCurvy。
    func isCurved(precision: Float) -> Bool {
        let first = start.interpolated(to: end, fraction: 1.0 / 3)
        let second = start.interpolated(to: end, fraction: 2.0 / 3)
        return max(abs(control1.x - first.x), abs(control1.y - first.y)) > precision
            || max(abs(control2.x - second.x), abs(control2.y - second.y)) > precision
    }

    /// 在参数中点做 De Casteljau 分割，保持上游浮点运算顺序。
    func split() -> (CurvePiece, CurvePiece) {
        let first = start.interpolated(to: control1, fraction: 0.5)
        let middle = control1.interpolated(to: control2, fraction: 0.5)
        let fifth = control2.interpolated(to: end, fraction: 0.5)
        let second = first.interpolated(to: middle, fraction: 0.5)
        let fourth = middle.interpolated(to: fifth, fraction: 0.5)
        let center = second.interpolated(to: fourth, fraction: 0.5)
        let halfT = (minimumT + maximumT) >> 1
        return (CurvePiece(start: start, control1: first, control2: second, end: center,
                           minimumT: minimumT, maximumT: halfT),
                CurvePiece(start: center, control1: fourth, control2: fifth, end: end,
                           minimumT: halfT, maximumT: maximumT))
    }
}
