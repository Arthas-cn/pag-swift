/// 上游GradientGenerator的256×1未预乘RGBA8输入表；它不是最终显示帧。
enum GradientTexturePixels {
    /// 按已剥端点hardstop的Float色标逐段写入；预算或非有限值失败时不返回半表。
    static func make(stops: [GradientStop], budget: inout MetalFrameBudget) throws -> [UInt8] {
        guard stops.count >= 2 else { throw PAGError.renderingFailure("gradientTextureStops") }
        try budget.reserve(256 * 4 + 512 + stops.count * 32)
        var pixels = [UInt8](repeating: 0, count: 256 * 4)
        var previous = 0
        for index in 1..<stops.count {
            try Task.checkCancellation()
            let nextPosition = stops[index].position * 256
            guard nextPosition.isFinite, nextPosition >= 0 else {
                throw PAGError.renderingFailure("gradientPrecision")
            }
            let next = min(Int(nextPosition), 255)
            guard next > previous else { previous = next; continue }
            let first = stops[index - 1].color, last = stops[index].color
            let step = Float(1) / Float(next - previous)
            let delta = (last - first) * step
            var color = first
            for pixel in previous...next {
                try Task.checkCancellation()
                try budget.reserve(16)
                guard color.x.isFinite, color.y.isFinite, color.z.isFinite, color.w.isFinite,
                      min(color.x, color.y, color.z, color.w) >= -1 / 255,
                      max(color.x, color.y, color.z, color.w) <= 1 + 1 / 255 else {
                    throw PAGError.renderingFailure("gradientPrecision")
                }
                let offset = pixel * 4
                // Float累加可能越过端色一ULP；先截断再饱和到字节，避免Swift浮转整数陷阱。
                pixels[offset] = UInt8(clamping: Int(color.x * 255))
                pixels[offset + 1] = UInt8(clamping: Int(color.y * 255))
                pixels[offset + 2] = UInt8(clamping: Int(color.z * 255))
                pixels[offset + 3] = UInt8(clamping: Int(color.w * 255))
                color += delta
            }
            previous = next
        }
        return pixels
    }
}
