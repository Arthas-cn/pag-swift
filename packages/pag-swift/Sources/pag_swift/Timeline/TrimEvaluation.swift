import Foundation

/// 源Float比例区间；允许超出单位范围，实际距离由测量消费者处理。
struct TrimInterval: Sendable, Equatable {
    /// 区间起点，未夹到0；越界值参与上游单次归一化后的截取。
    let start: Float
    /// 区间终点，未夹到1；不能因为跨度大于1便折叠为完整路径。
    let end: Float

    /// 缓存按位匹配，保守区分正负零，不把Float算序差异隐藏在近似比较中。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.start.bitPattern == rhs.start.bitPattern && lhs.end.bitPattern == rhs.end.bitPattern
    }
}

/// 一次源帧的裁剪选择；最多两个区间，比例求值不分配路径或测量表。
enum TrimSelection: Sendable, Equatable {
    /// 比例差严格小于源Float epsilon，清空包括零长度在内的全部已有路径。
    case empty
    /// 最终精确0...1；保留完整拓扑，但reversed为true时仍反转每条路径。
    case unchanged(reversed: Bool)
    /// 逐路径或累计模式及方向；first先提取，非nil的second另起轮廓，不焊接。
    case ranges(mode: SourceTrimMode, reversed: Bool, first: TrimInterval, second: TrimInterval?)
}

/// ShapeRenderer.cpp::ApplyTrimPaths的源Float参数步骤，不执行路径反转、测量或绘制。
enum TrimEvaluation {
    /// 求三条轨道后按源码次序选择区间；取消、既有属性错误原样传播，新算术溢出报trimPrecision。
    static func selection(_ source: SourceTrimPaths, at frame: Int64) throws -> TrimSelection {
        try Task.checkCancellation()
        var start = Float(try PropertyEvaluation.scalar(source.start, at: frame))
        var end = Float(try PropertyEvaluation.scalar(source.end, at: frame))
        let angle = Float(try PropertyEvaluation.scalar(source.offset, at: frame))
        guard start.isFinite, end.isFinite, angle.isFinite else { throw PAGError.renderingFailure("trimPrecision") }
        let offset = fmodf(angle, 360) / 360
        start += offset
        end += offset
        let difference = start - end
        guard start.isFinite, end.isFinite, difference.isFinite else { throw PAGError.renderingFailure("trimPrecision") }
        // 近等分支早于反转和归一化；零长度路径在这一分支也必须清空。
        if abs(difference) < Float.ulpOfOne { return .empty }
        let reversed = start > end
        if reversed {
            start = 1 - start
            end = 1 - end
        }
        // 上游仅移动一圈；通用取模或clamp会改变缺省end100以及多圈输入的实际输出。
        if start > 1, end > 1 {
            start -= 1
            end -= 1
        } else if start < 0, end < 0 {
            start += 1
            end += 1
        }
        guard start.isFinite, end.isFinite else { throw PAGError.renderingFailure("trimPrecision") }
        if start == 0, end == 1 { return .unchanged(reversed: reversed) }
        if start < 0 {
            return .ranges(mode: source.mode, reversed: reversed,
                first: TrimInterval(start: start + 1, end: 1), second: TrimInterval(start: 0, end: end))
        }
        if end > 1 {
            return .ranges(mode: source.mode, reversed: reversed,
                first: TrimInterval(start: start, end: 1), second: TrimInterval(start: 0, end: end - 1))
        }
        return .ranges(mode: source.mode, reversed: reversed, first: TrimInterval(start: start, end: end), second: nil)
    }
}
