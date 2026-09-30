import Testing
@testable import pag_swift

/// 正布局到实际像素的整数边界与资源上限；零布局必须由 inactive 消息处理。
struct DisplayGeometryTests {
    /// 非整数像素向上取整，逻辑尺寸与倍率仍保留原值，避免反向改变 none 缩放语义。
    @Test func roundsAllocationWithoutChangingLogicalGeometry() throws {
        let size = try PAGSize(width: 10.1, height: 20.2)
        let geometry = try DisplayGeometry(size: size, scale: 1.5)
        #expect(geometry.pixelWidth == 16 && geometry.pixelHeight == 31)
        #expect(geometry.size == size && geometry.scale == 1.5)
    }

    /// 非正或非有限倍率不能进入 Metal，错误仍说明具体参数。
    @Test(arguments: [0.0, -1, Double.infinity, Double.nan])
    func invalidScaleFails(_ scale: Double) throws {
        let size = try PAGSize(width: 10, height: 10)
        #expect(throws: PAGError.invalidArgument("scale")) { try DisplayGeometry(size: size, scale: scale) }
    }

    /// 相乘溢出与下溢至零在转 Int 前失败，不发生浮点或整数陷阱。
    @Test func unrepresentablePixelDimensionsFail() throws {
        let huge = try PAGSize(width: .greatestFiniteMagnitude, height: 1)
        #expect(throws: PAGError.invalidArgument("displayPixelSize")) { try DisplayGeometry(size: huge, scale: 2) }
        let tiny = try PAGSize(width: .leastNonzeroMagnitude, height: 1)
        #expect(throws: PAGError.invalidArgument("displayPixelSize")) { try DisplayGeometry(size: tiny, scale: 0.5) }
    }

    /// 单边上限与总像素上限独立检查，乘法即使超过 Int.max 也能安全拒绝。
    @Test func dimensionAndAreaBudgetsAreIndependent() throws {
        let wide = try PAGSize(width: 16_385, height: 1)
        #expect(throws: PAGError.resourceLimitExceeded("displayPixels")) { try DisplayGeometry(size: wide, scale: 1) }
        let area = try PAGSize(width: 4_097, height: 4_096)
        #expect(throws: PAGError.resourceLimitExceeded("displayPixels")) { try DisplayGeometry(size: area, scale: 1) }
        let overflow = try PAGSize(width: 4_294_967_296, height: 4_294_967_296)
        #expect(throws: PAGError.resourceLimitExceeded("displayPixels")) {
            try DisplayGeometry(size: overflow, scale: 1, maximumDimension: .max, maximumPixels: .max)
        }
    }
}
