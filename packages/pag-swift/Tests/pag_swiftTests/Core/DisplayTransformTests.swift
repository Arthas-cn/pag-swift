import Testing
@testable import pag_swift

/// 验证三种宿主共用的居中缩放与像素倍率，测试纯计算而不申请显示纹理。
struct DisplayTransformTests {
    /// 同一横向内容在方形目标中，各模式应产生明确的比例、留边或裁切。
    @Test func scaleModesUseOneCenteredMapping() throws {
        let content = try PAGSize(width: 100, height: 50)
        let target = try PAGSize(width: 200, height: 200)
        let none = try DisplayTransform(contentSize: content, targetSize: target, scale: 1, mode: .none)
        #expect(none.a == 1 && none.d == 1 && none.tx == 50 && none.ty == 75)
        let stretch = try DisplayTransform(contentSize: content, targetSize: target, scale: 1, mode: .stretch)
        #expect(stretch.a == 2 && stretch.d == 4 && stretch.tx == 0 && stretch.ty == 0)
        let fit = try DisplayTransform(contentSize: content, targetSize: target, scale: 1, mode: .aspectFit)
        #expect(fit.a == 2 && fit.d == 2 && fit.tx == 0 && fit.ty == 50)
        let fill = try DisplayTransform(contentSize: content, targetSize: target, scale: 1, mode: .aspectFill)
        #expect(fill.a == 4 && fill.d == 4 && fill.tx == -100 && fill.ty == 0)
        #expect(fill.clipRect == DisplayRect(x: 0, y: 0, width: 200, height: 200))
    }

    /// none 仍按像素倍率输出，保持一个合成点对应一个宿主逻辑点。
    @Test func pixelScaleDoesNotChangeLogicalScaleMode() throws {
        let transform = try DisplayTransform(
            contentSize: PAGSize(width: 100, height: 50),
            targetSize: PAGSize(width: 200, height: 100), scale: 3, mode: .none
        )
        #expect(transform.a == 3 && transform.d == 3)
        #expect(transform.tx == 150 && transform.ty == 75)
        #expect(transform.b == 0 && transform.c == 0)
        #expect(transform.clipRect.width == 600 && transform.clipRect.height == 300)
    }

    /// 像素倍率必须有限且为正，零布局应走生命周期挂起而不是传零倍率。
    @Test(arguments: [0.0, -1, .nan, .infinity])
    func invalidPixelScaleFails(_ scale: Double) throws {
        let size = try PAGSize(width: 100, height: 100)
        #expect(throws: PAGError.invalidArgument("scale")) {
            try DisplayTransform(contentSize: size, targetSize: size, scale: scale, mode: .aspectFit)
        }
    }

    /// 合法单个参数仍可能让组合运算溢出，必须在写入变换之前失败。
    @Test func overflowingTransformFails() throws {
        let content = try PAGSize(width: 1, height: 1)
        let huge = try PAGSize(width: .greatestFiniteMagnitude, height: 1)
        #expect(throws: PAGError.invalidArgument("displayTransform")) {
            try DisplayTransform(contentSize: content, targetSize: huge, scale: 2, mode: .stretch)
        }
    }

    /// 极端宽高比导致零缩放时应失败，不能返回不可逆的隐形变换。
    @Test func underflowingScaleFails() throws {
        let content = try PAGSize(width: .greatestFiniteMagnitude, height: 1)
        let target = try PAGSize(width: .leastNonzeroMagnitude, height: 1)
        #expect(throws: PAGError.invalidArgument("displayTransform")) {
            try DisplayTransform(contentSize: content, targetSize: target, scale: 1, mode: .aspectFit)
        }
    }
}
