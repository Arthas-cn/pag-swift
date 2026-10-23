import CoreGraphics
import Foundation
import pag_swift

/// 详情只选择库的遮罩 API，不在 App 侧裁剪或逐帧合成头像。
nonisolated enum DemoImageMaskChoice: String, CaseIterable, Identifiable, Sendable {
    /// 保留原 PAG 约束，不增加业务遮罩。
    case none = "无遮罩"
    /// 读取用户选择的原始图像槽，例如资源 10 的 xin7.png。
    case original = "原槽图片 alpha"
    /// 使用资源目录内已有透明 PNG 的 alpha。
    case png = "透明 PNG alpha"
    /// 内切槽逻辑框的正圆。
    case circle = "圆形"
    /// 填满槽逻辑框的椭圆。
    case ellipse = "椭圆"
    /// 短边四分之一的圆角半径。
    case rounded = "圆角矩形"
    /// 通过标准 CGPath 构造五角星，验证自定义路径入口。
    case custom = "自定义五角星路径"
    /// 选择器使用稳定业务标签。
    var id: String { rawValue }

    /// 把选择转成库选项；只在用户应用素材时读取一次 PNG，其余图形交给库准备。
    @concurrent func mask(root: URL, sourceTag: String) async throws -> PAGImageMask? {
        switch self {
        case .none: return nil
        case .original: return .originalImage(tag: sourceTag)
        case .png: return .alphaImage(try await PAGImage.load(from: root.appending(path: "media/rgba-corners.png")))
        case .circle: return .circle
        case .ellipse: return .ellipse
        case .rounded: return .roundedRectangle(cornerRadius: 0.25)
        case .custom:
            let path = CGMutablePath()
            for index in 0..<10 {
                let angle = Double(index) * .pi / 5 - .pi / 2
                let radius = index.isMultiple(of: 2) ? 48.0 : 20.0
                let point = CGPoint(x: 50 + cos(angle) * radius, y: 50 + sin(angle) * radius)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return try .path(PAGMaskPath(path, coordinateSize: PAGSize(width: 100, height: 100)))
        }
    }
}

/// 头像与遮罩分别布局，业务可填满头像而让遮罩保持比例。
nonisolated enum DemoImageScaleChoice: String, CaseIterable, Identifiable, Sendable {
    /// 不覆盖文件已有的 ImageFillRule 与缩放表。
    case file = "按 PAG 原规则"
    /// 等比填满槽，适合任意长宽比头像。
    case fill = "等比填满"
    /// 完整显示替换素材，空余区域透明。
    case fit = "等比适应"
    /// 两轴填满，允许改变素材宽高比。
    case stretch = "拉伸填满"
    /// 选择器稳定身份。
    var id: String { rawValue }
    /// nil 表示沿用文件规则，避免 Demo 默认改变旧替换行为。
    var mode: PAGScaleMode? {
        switch self {
        case .file: nil
        case .fill: .aspectFill
        case .fit: .aspectFit
        case .stretch: .stretch
        }
    }
}
