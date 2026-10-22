import Foundation
import Testing
@testable import pag_swift

/// 投影角度、层缩放抵消与显示像素映射的纯值合同。
struct DropShadowOffsetTests {
    /// 180度向右，图层自身两倍缩放不放大五像素投影，显示目标三倍缩放仍生效。
    @Test func layerScaleIsCancelledBeforeDisplayScale() throws {
        let layer = try SceneAffine.scale(x: 2, y: 2)
        let display = try layer.following(.scale(x: 3, y: 3))
        let style = SourceDropShadow(blendMode: 1, color: SceneColor(red: 0, green: 0, blue: 0),
            opacity: 191, angle: 180, distance: 5, size: 0, spread: 0)
        let identity = try DocumentIdentity(data: Data([1]))
        let shadow = FrameDropShadow(layerID: PAGLayerID(document: identity, path: [1]),
            matrix: display, layerMatrix: layer, styles: [style], opacity: 1)
        let offset = try DropShadowOffset.display(style: style, shadow: shadow)
        #expect(abs(offset.x - 15) < 0.0001)
        #expect(abs(offset.y) < 0.0001)
    }

    /// 非正距离使上游位移归零，不让角度中的NaN通过这一快捷分支隐藏文件损坏。
    @Test func nonpositiveDistanceHasNoOffset() throws {
        let style = SourceDropShadow(blendMode: 0, color: SceneColor(red: 0, green: 0, blue: 0),
            opacity: 255, angle: 90, distance: 0, size: 20, spread: 0)
        let identity = try DocumentIdentity(data: Data([2]))
        let shadow = FrameDropShadow(layerID: PAGLayerID(document: identity, path: [1]),
            matrix: .identity, layerMatrix: .identity, styles: [style], opacity: 1)
        #expect(try DropShadowOffset.display(style: style, shadow: shadow) == .zero)
    }

    /// 正尺寸按层轴倍率抵消后成为显示轴blurriness，Gaussian透明halo等于该值向上取整。
    @Test func gaussianSizeFollowsDisplayScale() throws {
        let layer = try SceneAffine.scale(x: 2, y: 4)
        let display = try layer.following(.scale(x: 3, y: 2))
        let style = SourceDropShadow(blendMode: 0, color: SceneColor(red: 255, green: 255, blue: 255),
            opacity: 191, angle: 180, distance: 0, size: 5, spread: 0)
        let identity = try DocumentIdentity(data: Data([3]))
        let shadow = FrameDropShadow(layerID: PAGLayerID(document: identity, path: [1]),
            matrix: display, layerMatrix: layer, styles: [style], opacity: 1)
        let size = try DropShadowOffset.displayBlurSize(style: style, shadow: shadow)
        #expect(size == ScenePoint(x: 15, y: 10))
        let layout = try #require(try FeatherGaussianLayout.make(size, width: 20, height: 30))
        #expect(layout.haloX == 15 && layout.haloY == 10)
        #expect(layout.width == 50 && layout.height == 50)
    }

    /// 斜切显示矩阵不能偷偷改为屏幕轴Gaussian；需在局部滤镜合同补齐后再放行。
    @Test func skewedGaussianIsExplicitlyUnsupported() throws {
        let style = SourceDropShadow(blendMode: 0, color: SceneColor(red: 0, green: 0, blue: 0),
            opacity: 255, angle: 180, distance: 0, size: 4, spread: 0)
        let identity = try DocumentIdentity(data: Data([4]))
        let shadow = FrameDropShadow(layerID: PAGLayerID(document: identity, path: [1]),
            matrix: try SceneAffine(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0),
            layerMatrix: .identity, styles: [style], opacity: 1)
        #expect(throws: PAGError.unsupportedFeature("dropShadowBlurTransform")) {
            try DropShadowOffset.displayBlurSize(style: style, shadow: shadow)
        }
    }

    /// spread一按未钳的源半径扩输出范围，25像素仅约束shader采样而不缩小滤镜边界。
    @Test func strokeLayoutKeepsUnclampedHalo() throws {
        let layout = try DropShadowStrokeLayout.make(size: ScenePoint(x: 30, y: 4),
            width: 20, height: 10)
        #expect(layout.haloX == 30 && layout.haloY == 4)
        #expect(layout.width == 80 && layout.height == 18)
        #expect(throws: PAGError.resourceLimitExceeded("dropShadowStrokeDimensions")) {
            try DropShadowStrokeLayout.make(size: ScenePoint(x: 8_193, y: 0),
                width: 20, height: 10)
        }
    }

    /// V2零尺寸仍可凭正距离成为可见样式，但其扩散核仅保留中心二值采样。
    @Test func zeroSizeSpreadKeepsOriginalLocalDimensions() throws {
        let style = SourceDropShadow(blendMode: 1, color: SceneColor(red: 140, green: 114, blue: 231),
            opacity: 179, angle: 120, distance: 2, size: 0, spread: 1)
        let identity = try DocumentIdentity(data: Data([5]))
        let shadow = FrameDropShadow(layerID: PAGLayerID(document: identity, path: [1]),
            matrix: .identity, layerMatrix: .identity, styles: [style], opacity: 1)
        let size = try DropShadowOffset.displaySpreadSize(style: style, shadow: shadow)
        #expect(size == .zero)
        let layout = try DropShadowStrokeLayout.make(size: size, width: 20, height: 10)
        #expect(layout.width == 20 && layout.height == 10)
    }
}
