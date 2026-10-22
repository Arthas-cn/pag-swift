import Foundation

/// 一条已折线化的普通蒙版路径；轮廓内部单独按nonzero判断，不与相邻路径混合绕数。
struct MaskBooleanOperand {
    /// 同一源路径的全部有限闭合轮廓，允许自交、孔洞或零面积。
    let contours: [[ScenePoint]]
    /// 当前项描边扩张后的有限轮廓；与原路径分别计绕数，不能先拼接。
    let strokeContours: [[ScenePoint]]
    /// Float采样的有符号扩张；正值合并描边，负值从原路径扣去描边。
    let expansion: Float
    /// 编码模式；首项除Subtract的反向规则外直接成为布尔基底。
    let mode: SourceMaskMode
    /// 此路径自身的inverse fill，不包含首项Subtract的额外翻转。
    let isInverted: Bool

    /// 保存单项内部描边与源路径的独立填充；准备时检查非法扩张，零值沿原路径。
    init(contours: [[ScenePoint]], strokeContours: [[ScenePoint]] = [], expansion: Float = 0,
         mode: SourceMaskMode, isInverted: Bool) {
        self.contours = contours
        self.strokeContours = strokeContours
        self.expansion = expansion
        self.mode = mode
        self.isInverted = isInverted
    }
}

/// 有限网格表示与远场状态相反的区域；远场为真时Metal对该网格取补集。
struct MaskBooleanResult {
    /// 内部不重叠的有限三角形；空网格不能推断PathKit结果是否零verb。
    let mesh: RenderMesh
    /// 所有有限边界之外的布尔真值，作为最终路径的inverse标记。
    let isInverted: Bool
}

/// 在全部路径的边交点间按各自绕数折叠有序Boolean，不把各路径AA覆盖率直接相乘。
enum MaskBooleanTessellation {
    /// 准备一个普通多路径蒙版的有限区域；输入必须已完成源项过滤和各自曲线细分。
    static func prepare(_ operands: [MaskBooleanOperand], budget: inout GeometryBudget) throws -> MaskBooleanResult {
        try budget.consume()
        guard !operands.isEmpty else { throw PAGError.invalidArgument("maskBooleanOperands") }
        guard operands.count <= Int.max / 2 else { throw PAGError.resourceLimitExceeded("maximumRenderGeometryBytes") }
        try budget.consume(operands.count)
        guard operands.allSatisfy({ $0.mode != .none }) else {
            throw PAGError.invalidArgument("maskBooleanMode")
        }
        guard operands.allSatisfy({ $0.expansion.isFinite }) else {
            throw PAGError.invalidArgument("maskExpansion")
        }
        guard let origin = try origin(of: operands, budget: &budget) else {
            let empty = RenderMesh(origin: .zero, vertices: [])
            return MaskBooleanResult(mesh: empty, isInverted: try evaluate(operands, windings: [], budget: &budget))
        }
        var edges: [ScanBoundary] = []
        var owners: [Int] = []
        var levels: [Double] = []
        for (owner, operand) in operands.enumerated() {
            try budget.consume()
            // 两种轮廓在同一扫描带求值，但各自绕数必须隔离到独立槽位。
            // 源扩张恰为零时PathUtil直接返回，传入的描边候选不得影响原点或预算。
            for channel in 0..<(operand.expansion == 0 ? 1 : 2) {
                try budget.consume()
                let contours = channel == 0 ? operand.contours : operand.strokeContours
                for contour in contours {
                    try budget.consume()
                    guard contour.count >= 3 else { continue }
                    for index in contour.indices {
                        try budget.consume()
                        let first = try NonzeroTessellation.local(contour[index], origin: origin)
                        let second = try NonzeroTessellation.local(contour[(index + 1) % contour.count], origin: origin)
                        guard first.y != second.y else { continue }
                        try budget.reserve(stride: 112)
                        try budget.reserve(2, stride: 16)
                        let edge = ScanBoundary(first, second)
                        edges.append(edge)
                        owners.append(owner * 2 + channel)
                        levels.append(edge.lower.y)
                        levels.append(edge.upper.y)
                    }
                }
            }
        }
        try budget.reserve(operands.count, stride: 32)
        var windings = [Int](repeating: 0, count: operands.count * 2)
        let outside = try evaluate(operands, windings: windings, budget: &budget)
        guard !edges.isEmpty else {
            return MaskBooleanResult(mesh: RenderMesh(origin: origin, vertices: []), isInverted: outside)
        }
        try NonzeroTessellation.addIntersections(edges, to: &levels, budget: &budget)
        try budget.sorting(levels.count)
        levels.sort()
        try Task.checkCancellation()
        // 重复高度不形成扫描带；原地压缩避免交点数量大时再分配一个等长数组。
        var count = 0
        for index in levels.indices {
            try budget.consume()
            let level = levels[index]
            if count == 0 || levels[count - 1] != level {
                levels[count] = level
                count += 1
            }
        }
        levels.removeLast(levels.count - count)
        try budget.reserve(edges.count, stride: 16)
        var sorted = Array(edges.indices)
        try budget.sorting(sorted.count)
        sorted.sort { edges[$0].lower.y < edges[$1].lower.y }
        try Task.checkCancellation()
        try budget.reserve(edges.count, stride: 16)
        var eligible: [Int] = []
        eligible.reserveCapacity(edges.count)
        try budget.reserve(edges.count, stride: 64)
        var active: [ScanCrossing] = []
        active.reserveCapacity(edges.count)
        var vertices: [ScenePoint] = []
        var nextEdge = 0
        for index in 1..<levels.count {
            try budget.consume()
            let lower = levels[index - 1], upper = levels[index]
            active.removeAll(keepingCapacity: true)
            while nextEdge < sorted.count, edges[sorted[nextEdge]].lower.y <= lower {
                try budget.consume()
                eligible.append(sorted[nextEdge])
                nextEdge += 1
            }
            var remaining = 0
            for slot in eligible.indices {
                try budget.consume()
                let edgeIndex = eligible[slot]
                let edge = edges[edgeIndex]
                guard edge.upper.y >= upper else { continue }
                eligible[remaining] = edgeIndex
                remaining += 1
                active.append(ScanCrossing(lowerX: edge.x(at: lower), upperX: edge.x(at: upper), edge: edgeIndex))
            }
            eligible.removeLast(eligible.count - remaining)
            try budget.sorting(active.count)
            active.sort(by: ScanCrossing.precedes)
            try Task.checkCancellation()
            try fillBand(lower: lower, upper: upper, crossings: active, edges: edges, owners: owners,
                         operands: operands, windings: &windings, outside: outside,
                         vertices: &vertices, budget: &budget)
        }
        try Task.checkCancellation()
        return MaskBooleanResult(mesh: RenderMesh(origin: origin, vertices: vertices), isInverted: outside)
    }

    /// 以全部路径的共同局部原点抵消大平移，逐点验证非有限输入。
    private static func origin(of operands: [MaskBooleanOperand], budget: inout GeometryBudget) throws -> ScenePoint? {
        var minimum: ScenePoint?
        for operand in operands {
            try budget.consume()
            for channel in 0..<(operand.expansion == 0 ? 1 : 2) {
                try budget.consume()
                let contours = channel == 0 ? operand.contours : operand.strokeContours
                for contour in contours {
                    try budget.consume()
                    for point in contour {
                        try budget.consume()
                        _ = try GeometryMath.checked(point)
                        if let previous = minimum {
                            minimum = ScenePoint(x: min(previous.x, point.x), y: min(previous.y, point.y))
                        } else { minimum = point }
                    }
                }
            }
        }
        return minimum
    }

    /// 远场和每个边界右侧使用同一折叠，首项Subtract只翻转首项自身。
    private static func evaluate(_ operands: [MaskBooleanOperand], windings: [Int],
                                 budget: inout GeometryBudget) throws -> Bool {
        try budget.consume(operands.count)
        let first = operands[0]
        var value = filled(first, at: 0, windings: windings) != (first.isInverted != (first.mode == .subtract))
        for index in 1..<operands.count {
            let operand = operands[index]
            let next = filled(operand, at: index, windings: windings) != operand.isInverted
            switch operand.mode {
            case .subtract: value = value && !next
            case .intersect, .darken: value = value && next
            case .difference: value = value != next
            case .none:
                // None应由采样层跳过；若传入，不能把它误当作Union。
                throw PAGError.invalidArgument("maskBooleanMode")
            case .add, .lighten, .accumulate: value = value || next
            }
        }
        return value
    }

    /// 单项扩张必须先合并或扣除其描边，再应用该项inverse和外层Boolean。
    private static func filled(_ operand: MaskBooleanOperand, at index: Int, windings: [Int]) -> Bool {
        let original = !windings.isEmpty && windings[index * 2] != 0
        guard operand.expansion != 0 else { return original }
        let stroke = !windings.isEmpty && windings[index * 2 + 1] != 0
        return operand.expansion > 0 ? original || stroke : original && !stroke
    }

    /// 同坐标的重合边必须一起更新所有路径绕数，只在最终有限状态进出时吐三角形。
    private static func fillBand(lower: Double, upper: Double, crossings: [ScanCrossing],
                                 edges: [ScanBoundary], owners: [Int], operands: [MaskBooleanOperand],
                                 windings: inout [Int], outside: Bool, vertices: inout [ScenePoint],
                                 budget: inout GeometryBudget) throws {
        var left: Int?
        var index = 0
        while index < crossings.count {
            try budget.consume()
            let start = index
            let before = try evaluate(operands, windings: windings, budget: &budget) != outside
            repeat {
                // 多条完全重合的边也要逐条计费和检查取消，不能只为整组收费一次。
                try budget.consume()
                let edgeIndex = crossings[index].edge
                windings[owners[edgeIndex]] += edges[edgeIndex].winding
                index += 1
            } while index < crossings.count && crossings[index].lowerX == crossings[start].lowerX
                && crossings[index].upperX == crossings[start].upperX
            let after = try evaluate(operands, windings: windings, budget: &budget) != outside
            if !before && after { left = crossings[start].edge }
            else if before && !after {
                guard let boundary = left else { throw PAGError.renderingFailure("maskBooleanWinding") }
                try NonzeroTessellation.trapezoid(left: edges[boundary], right: edges[crossings[start].edge],
                                                  lower: lower, upper: upper, vertices: &vertices, budget: &budget)
                left = nil
            }
        }
        try budget.consume(windings.count)
        guard left == nil, windings.allSatisfy({ $0 == 0 }) else {
            throw PAGError.renderingFailure("maskBooleanWinding")
        }
    }

}
