import CoreGraphics

/// 图像槽的附加 alpha 遮罩；只限制替换内容，仍与原 PAG 图层遮罩、透明度共同生效。
public enum PAGImageMask: Sendable {
    /// 读取静图 alpha，颜色不参与；按指定模式放入目标槽逻辑框，框外透明。
    case alphaImage(PAGImage, scaleMode: PAGScaleMode = .aspectFit)
    /// 从同文档指定图像源槽读取原图 alpha，保留源裁边信息，不影响该槽当前内容。
    case originalImage(tag: String, scaleMode: PAGScaleMode = .aspectFit)
    /// 内切目标槽逻辑框的圆形，长方形槽的两侧保持透明。
    case circle
    /// 填满目标槽逻辑框的椭圆，正方形槽等价于圆形。
    case ellipse
    /// 填满逻辑框的圆角矩形；半径是短边比例，必须位于 0...0.5。
    case roundedRectangle(cornerRadius: Double)
    /// 自定义不可变路径，按指定模式把路径坐标框放入槽逻辑框。
    case path(PAGMaskPath, scaleMode: PAGScaleMode = .aspectFit)
}

/// 跨隔离安全的自定义路径快照；不保留可变 CGMutablePath，坐标采用左上原点、y 向下。
public struct PAGMaskPath: Sendable {
    /// 路径坐标的完整画布，超出画布部分被裁剪，不以路径紧致包围框重新居中。
    public let coordinateSize: PAGSize
    /// true 使用奇偶填充以表达孔洞，false 使用 Core Graphics 非零绕组规则。
    public let usesEvenOddFillRule: Bool
    /// 复制后的路径元素，最多 4096 项；不会在播放期间再次读取宿主路径。
    private let elements: [MaskPathElement]

    /// 复制并验证路径；非法坐标/空路径抛 invalidArgument，超过元素预算抛资源错误。
    public init(_ path: CGPath, coordinateSize: PAGSize, usesEvenOddFillRule: Bool = false) throws {
        var elements: [MaskPathElement] = []
        var invalid = false
        var exceeded = false
        path.applyWithBlock { pointer in
            guard elements.count < 4096 else { exceeded = true; return }
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: invalid = true; return
            }
            let points = (0..<count).map { element.points[$0] }
            if points.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) { invalid = true }
            elements.append(MaskPathElement(kind: element.type.rawValue, points: points))
        }
        guard !exceeded else { throw PAGError.resourceLimitExceeded("maskPathElements") }
        guard !invalid, !elements.isEmpty else { throw PAGError.invalidArgument("maskPath") }
        self.coordinateSize = coordinateSize
        self.usesEvenOddFillRule = usesEvenOddFillRule
        self.elements = elements
    }

    /// 只在后台安装阶段重建局部路径，用完即释放；不把可变路径跨执行器共享。
    func makePath() -> CGPath {
        let result = CGMutablePath()
        for element in elements {
            switch CGPathElementType(rawValue: element.kind) {
            case .moveToPoint: result.move(to: element.points[0])
            case .addLineToPoint: result.addLine(to: element.points[0])
            case .addQuadCurveToPoint: result.addQuadCurve(to: element.points[1], control: element.points[0])
            case .addCurveToPoint:
                result.addCurve(to: element.points[2], control1: element.points[0], control2: element.points[1])
            case .closeSubpath: result.closeSubpath()
            default: break // 构造器已拒绝未知元素；原始值仅用于可发送的值表示。
            }
        }
        return result
    }
}

/// 单条已验证的 Core Graphics 命令，点数组完全属于当前快照。
private struct MaskPathElement: Sendable {
    /// 已知 CGPathElementType 原始值，不支持未知未来命令。
    let kind: Int32
    /// 命令要求的零至三个有限控制点/终点。
    let points: [CGPoint]
}
