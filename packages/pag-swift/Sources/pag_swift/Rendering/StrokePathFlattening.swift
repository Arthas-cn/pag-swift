/// 描边接入共同网格准备的同步出口；不创建第二套缓存、渲染器或像素表面。
extension PathFlattening {
    /// stroke必须来自geometry.stroke；最终转换与折线化平分容差，预算或取消失败不返回部分边界。
    static func stroke(_ geometry: ShapeGeometry, stroke: ShapeStroke, tolerance: Double,
                       budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        try budget.consume()
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        let partialTolerance = tolerance * 0.5
        guard partialTolerance.isFinite, partialTolerance > 0 else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        let centerline = try StrokeCenterline.make(geometry, budget: &budget)
        let dashed = try StrokeDashing.make(centerline, style: stroke.style, budget: &budget)
        let style = stroke.style
        let solid = StrokeStyle(width: style.width, cap: style.cap, join: style.join,
                                miterLimit: style.miterLimit, dashes: nil)
        let outline = try StrokeOutline.make(dashed, style: solid, restoration: stroke.restoration,
                                            tolerance: partialTolerance, budget: &budget)
        // outline已经复原到图层坐标；不能再次应用paint或轮廓矩阵，也不能先把中心线折成弦。
        return try sourcePath(outline, tolerance: partialTolerance, budget: &budget)
    }
}
