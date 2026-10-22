/// 仅按已激活的播放时间计算水平滚动，根合成循环和普通 seek 不参与位移。
enum MarqueeMotion {
    /// 返回当前副本向左移动的合成点数；等待期保持起始位置，非法宽度或溢出抛错。
    static func offset(width: Double, options: PAGMarqueeOptions, elapsed: PAGTime) throws -> Double {
        let period = width + options.gap
        guard width.isFinite, width > 0, period.isFinite, period > 0 else {
            throw PAGError.unsupportedFeature("marqueeTextWidth")
        }
        let movingMicroseconds = max(0, elapsed.microseconds - options.initialDelay.microseconds)
        let distance = Double(movingMicroseconds) / 1_000_000 * options.speed
        guard distance.isFinite else { throw PAGError.unsupportedFeature("marqueeElapsedTime") }
        return distance.truncatingRemainder(dividingBy: period)
    }
}
