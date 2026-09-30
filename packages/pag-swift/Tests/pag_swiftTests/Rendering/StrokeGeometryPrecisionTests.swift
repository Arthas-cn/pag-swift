import Foundation
import Testing
@testable import pag_swift

/// 区分源固定偏移精度与最终两步近似；独立rational公式只作为采样参照，不调用生产曲线helper。
struct StrokeGeometryPrecisionTests {
    /// 放大只增加最终细分，不能为达到理想圆1/8误差而改写源接受的半径3单Q边界。
    @Test func sourceOffsetErrorRemainsSeparateFromDisplayTolerance() throws {
        let geometry = try StrokeGeometryTestSupport.circle(style: StrokeGeometryTestSupport.style(width: 4))
        var counts: [Int] = []
        for scale in [1.0, 100] {
            var budget = try GeometryBudget()
            let precision = try GeometryPrecision(transform: .scale(x: scale, y: scale))
            let contours = try PathFlattening.shape(geometry, tolerance: precision.tolerance, budget: &budget)
            let points = contours.flatMap { $0 }
            #expect(points.contains(ScenePoint(x: 2.25, y: 2.25)))
            counts.append(points.count)
            // 源Q中点径向距离为9√2/4；理想圆半径3。这个源误差随最终显示矩阵放大。
            let error = (9 * sqrt(2) / 4 - 3) * scale
            #expect(error > 0.125)
            #expect(abs(error / scale - 0.18198051533946424) < 1e-12)
        }
        #expect(counts[1] > counts[0])
    }

    /// hairline源Conic经出口转换和折线化后，在非均匀显示放大下仍满足两步合计1/8像素采样界。
    @Test func finalConversionAndFlatteningStayWithinCombinedTolerance() throws {
        let geometry = try StrokeGeometryTestSupport.circle(style: StrokeGeometryTestSupport.style(width: 1.0 / 4096))
        let view = try SceneAffine.scale(x: 64, y: 16)
        var budget = try GeometryBudget()
        let precision = try GeometryPrecision(transform: view)
        let contours = try PathFlattening.shape(geometry, tolerance: precision.tolerance, budget: &budget)
        try #require(contours.count == 1)
        let contour = try #require(contours.first)
        let polygon = contour.map { ScenePoint(x: $0.x * 64, y: $0.y * 16) }
        var maximumError = 0.0
        for quarter in 0..<4 {
            for index in 0...512 {
                let point = rationalQuarter(Double(index) / 512, quarter: quarter)
                let displayed = ScenePoint(x: point.x * 64, y: point.y * 16)
                maximumError = max(maximumError, distance(displayed, to: polygon))
            }
        }
        #expect(maximumError <= 0.125)
        #expect(maximumError > 0)
    }

    /// 显示反射与同档放大使用同一层坐标网格，几何坐标不应提前乘显示矩阵。
    @Test func displayReflectionChangesPrecisionWithoutBakingCoordinates() throws {
        let geometry = try StrokeGeometryTestSupport.circle(style: StrokeGeometryTestSupport.style(width: 0.5))
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let source = RenderGeometrySource.shape(geometry)
        let positive = try cache.mesh(for: source, transform: .scale(x: 64, y: 16), budget: &budget)
        let reflected = try cache.mesh(for: source, transform: .scale(x: -64, y: 16), budget: &budget)
        #expect(positive === reflected)
        let actual = positive.vertices.map { ScenePoint(x: $0.x + positive.origin.x, y: $0.y + positive.origin.y) }
        #expect((actual.map(\.x).max() ?? 0) <= 1.25)
        #expect((actual.map(\.x).min() ?? 0) >= -1.25)
    }

    /// 直接以Double计算实际源Float权重的rational曲线，再按四分之一旋转生成独立参照。
    private func rationalQuarter(_ t: Double, quarter: Int) -> ScenePoint {
        let weight = Double(Float(bitPattern: 0x3F3504F3)), one = 1 - t
        let denominator = one * one + 2 * weight * one * t + t * t
        let x = (one * one + 2 * weight * one * t) / denominator
        let y = (2 * weight * one * t + t * t) / denominator
        return switch quarter {
        case 0: ScenePoint(x: x, y: y)
        case 1: ScenePoint(x: -y, y: x)
        case 2: ScenePoint(x: -x, y: -y)
        default: ScenePoint(x: y, y: -x)
        }
    }

    /// 用解析投影独立求采样点到闭合折线的最近距离，不使用生产距离/细分函数生成期望。
    private func distance(_ point: ScenePoint, to polygon: [ScenePoint]) -> Double {
        var result = Double.infinity
        for index in polygon.indices {
            let start = polygon[index], end = polygon[(index + 1) % polygon.count]
            let dx = end.x - start.x, dy = end.y - start.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
            result = min(result, hypot(point.x - start.x - t * dx, point.y - start.y - t * dy))
        }
        return result
    }
}
