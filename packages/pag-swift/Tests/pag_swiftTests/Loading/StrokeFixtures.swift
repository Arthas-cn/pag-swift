import Foundation
@testable import pag_swift

/// 普通描边测试的真实字段读取与纯语义轨道；不构造自称合法的PAG文件。
enum StrokeFixtures {
    /// 读取实际tag21载荷并要求完整消费，允许测试单独缩小解码预算。
    static func decode(_ data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> SourceStroke {
        var reader = PAGByteReader(data: data)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
        return try decoder.readStroke(reader: &reader)
    }

    /// 按独立取证的字段范围截取真实文件；文件和范围错误不被吞掉。
    static func source(named name: String, range: Range<Int>) throws -> SourceStroke {
        try decode(PAGFixtures.data(named: name).subdata(in: range))
    }

    /// 单独读取真实SimpleProperty颜色字段，flags由所在Fill配置的源码调查提供。
    static func color(_ data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> SourceProperty<SceneColor> {
        var reader = PAGByteReader(data: data)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
        let property = try decoder.readColorProperty(PropertyFlags(exists: true, isAnimated: true, hasSpatial: false),
            defaultValue: .defaultFill, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return property
    }

    /// 纯语义的一段轨道，用于文件未提供的分支；不涉及编码或猜测字段布局。
    static func track<Value: Sendable>(_ first: Value, _ last: Value, start: Int64 = 0, end: Int64 = 10,
                                       easing: SourceEasing = .linear) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: start, endFrame: end,
            startValue: first, endValue: last, easing: easing, spatialCurve: nil)])
    }

    /// 明确构造纯语义Stroke，默认值沿源码；可独立覆盖各条轨道而不伪造二进制。
    static func make(width: SourceProperty<Double> = SourceProperty(constant: 2),
                     miter: SourceProperty<Double> = SourceProperty(constant: 4),
                     color: SourceProperty<SceneColor> = SourceProperty(constant: SceneColor(red: 255, green: 255, blue: 255)),
                     opacity: SourceProperty<UInt8> = SourceProperty(constant: 255),
                     cap: SourceLineCap = .butt, join: SourceLineJoin = .miter,
                     order: ShapeCompositeOrder = .belowPrevious, dashes: SourceDashes? = nil) -> SourceStroke {
        SourceStroke(compositeOrder: order, cap: cap, join: join, miterLimit: miter,
                     color: color, opacity: opacity, width: width, dashes: dashes)
    }
}
