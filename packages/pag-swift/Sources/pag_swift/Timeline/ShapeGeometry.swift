/// 已准备形状几何的稳定身份；源实例共享，同文档的不同源层不混用序号。
struct ShapeGeometryID: Sendable, Hashable {
    /// 完整 PAG 内容身份，不能仅用文件名区分。
    let document: DocumentIdentity
    /// 源合成和源层的下标，不使用展开后的实例路径。
    let source: SourceLayerReference
    /// 此源层的几何数组下标，从零开始。
    let index: Int
    /// 动态源层的合成采样帧；静态为nil，不同实例帧不能共用同一个输入表键。
    let sampleFrame: Int64?

    /// 组成文档内几何身份，静态调用不需要提供采样帧。
    init(document: DocumentIdentity, source: SourceLayerReference, index: Int, sampleFrame: Int64? = nil) {
        self.document = document
        self.source = source
        self.index = index
        self.sampleFrame = sampleFrame
    }
}

/// 同一复合填充按源顺序累计的几何；保持解析生成器和完整路径，均未生成网格。
enum ShapeContour: Sendable {
    /// 已校验的矩形或圆角矩形，带累计组矩阵及绕序。
    case rectangle(RoundedRectangleContour)
    /// 未排序的Float椭圆边界，生成Conic之前仍可直接比较和复用。
    case ellipse(EllipseContour)
    /// 完整PolyStar求值参数，颜色帧不逐次展开大量顶点。
    case polyStar(PolyStarContour)
    /// 当前时刻的路径与累计组矩阵；点未预先变换，不重复复制源数组。
    case path(SourcePath, matrix: SceneAffine)

    /// 从该轮廓局部坐标到形状图层坐标的累计组变换。
    var matrix: SceneAffine {
        switch self {
        case .rectangle(let value): value.matrix
        case .ellipse(let value): value.matrix
        case .polyStar(let value): value.matrix
        case .path(_, let matrix): matrix
        }
    }
}

/// 同一次paint的复合中心线；填充或描边outline都只生成一次nonzero绘制。
final class ShapeGeometry: Sendable {
    /// 已保存全部形状组矩阵的复合轮廓，顺序保持源路径累计顺序。
    let contours: [ShapeContour]
    /// nil表示普通fill；非nil在渲染后台对当前累计中心线生成描边outline。
    let stroke: ShapeStroke?
    /// 包括引用路径点数组的保守留存成本；共享输入重复计量可以高估，但不能漏计大路径。
    let estimatedBytes: Int

    /// 保存完整轮廓并校验留存成本；取消或整数溢出不发布资源，分配预算由准备器负责。
    init(contours: [ShapeContour], stroke: ShapeStroke? = nil) throws {
        var budget = FramePlanBudget(limit: Int.max, resourceName: "maximumShapeGeometryBytes")
        try budget.reserve(stride: 128)
        try budget.reserve(count: contours.count, stride: 192)
        for contour in contours {
            try Task.checkCancellation()
            if case .path(let path, _) = contour { try budget.reserve(stride: path.estimatedBytes) }
        }
        if let stroke {
            try budget.reserve(stride: 256)
            try budget.reserve(count: stroke.style.dashes?.intervals.count ?? 0, stride: 16)
        }
        self.contours = contours
        self.stroke = stroke
        estimatedBytes = budget.used
    }

    /// 同源paint只在路径身份、轮廓顺序、全部矩阵和完整样式相同时复用；逐轮廓计费并检查取消。
    func matches(contours: [ShapeContour], stroke: ShapeStroke?, budget: inout FramePlanBudget) throws -> Bool {
        try Task.checkCancellation()
        guard self.stroke == stroke, self.contours.count == contours.count else { return false }
        for (previous, current) in zip(self.contours, contours) {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            switch (previous, current) {
            case let (.rectangle(first), .rectangle(second)):
                guard first == second else { return false }
            case let (.ellipse(first), .ellipse(second)):
                guard first == second else { return false }
            case let (.polyStar(first), .polyStar(second)):
                guard first == second else { return false }
            case let (.path(first, firstMatrix), .path(second, secondMatrix)):
                // 源路径不可变；新形变对象即使点值相同也不遍历比较，避免颜色帧重扫大路径。
                guard first === second, firstMatrix == secondMatrix else { return false }
            default: return false
            }
        }
        return true
    }
}

/// 与几何身份分离的不可变材料，不携带GPU对象。
enum ShapeMaterial: Sendable {
    /// 未预乘RGB，透明度由paint独立提供。
    case solid(SceneColor)
    /// 已编译颜色程序及paint映射，退化也保留完整RGBA。
    case gradient(PreparedGradient)
}

/// 某个源层采样结果中的一次填充；绘制范围由geometryIndex对应的复合几何确定。
struct ShapePaint: Sendable {
    /// 当前 PreparedShapeLayer.geometries 中的下标。
    let geometryIndex: Int
    /// 与复合路径独立的纯色或渐变；不影响几何缓存身份。
    let material: ShapeMaterial
    /// 此次 fill 自身透明度，不包含组和图层 alpha。
    let opacity: Double
}

/// 已按真实覆盖顺序排列的单次形状采样指令；只保留影响画面的组边界。
enum ShapeInstruction: Sendable {
    /// 进入不带裁剪的整体透明度组，关联值范围为 0..<1。
    case beginOpacityGroup(Double)
    /// 结束最近一次形状透明度组。
    case endOpacityGroup
    /// 使用准备好的复合路径和颜色填充一次。
    case fill(ShapePaint)
}

/// 一份源形状图层的不可变采样结果；静态时刻共享，动态时按源帧缓存。
final class PreparedShapeLayer: Sendable {
    /// 真实绘制顺序，已经处理Below/Above以及子组整体alpha边界。
    let instructions: [ShapeInstruction]
    /// 被 fill 引用的几何快照，每个对象只在后台准备阶段构造一次。
    let geometries: [ShapeGeometry]
    /// 源深度优先paint序号到紧凑几何下标；不可见paint不入表，连续fill可以共享下标。
    let geometryIndicesByPaint: [Int: Int]
    /// 同源paint序号对应的完整颜色程序；不可见paint不入表，命中仍计保活成本。
    let gradientColorizersByPaint: [Int: PreparedGradientColorizer]
    /// 本次完整准备的保守累计计费，包含暂存与路径保活，缓存命中仍须接受新调用预算检查。
    let estimatedBytes: Int

    /// 由完整准备器发布，不接受外部构造的任意几何下标。
    init(instructions: [ShapeInstruction], geometries: [ShapeGeometry], geometryIndicesByPaint: [Int: Int],
         gradientColorizersByPaint: [Int: PreparedGradientColorizer], estimatedBytes: Int) {
        self.instructions = instructions
        self.geometries = geometries
        self.gradientColorizersByPaint = gradientColorizersByPaint
        self.geometryIndicesByPaint = geometryIndicesByPaint
        self.estimatedBytes = estimatedBytes
    }
}
