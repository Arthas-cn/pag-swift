import Foundation
import Testing
@testable import pag_swift

/// 真实渐变字段到内部颜色程序的连续性；不经过正式PAG入口，不声明整文件播放支持。
struct GradientRealColorTests {
    /// 32个载荷的34份颜色值中32份解析可用，真实精度与容量不足各一份必须保持独立分类。
    @Test func realColorValuesMatchVerifiedProgramClassification() throws {
        var payloadCount = 0, valueCount = 0, invalidCount = 0, textureCount = 0
        for url in try PAGFixtures.allPAGURLs() {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(Data(contentsOf: url))
            for payload in inspection.gradientPayloads {
                var reader = payload.reader
                var decoder = GradientFixtures.decoder()
                let source = try payload.code == 22 ? decoder.readGradientFill(reader: &reader).gradient
                    : decoder.readGradientStroke(reader: &reader).gradient
                for value in [source.colors.initialValue] + source.colors.keyframes.map(\.endValue) {
                    let program = try GradientColorFixtures.compile(value)
                    if url.lastPathComponent == "grad_alpha.pag", payload.range == 141..<250 {
                        // 15个alpha色标与RGB合并后超出八段解析容量；真实文件不能静默丢掉透明度。
                        guard case .requiresTexture = program.result else {
                            Issue.record("grad_alpha必须明确保留纹理颜色程序需求")
                            return
                        }
                        #expect(value.alphaStops.count == 15)
                        textureCount += 1
                        valueCount += 1
                        continue
                    }
                    if url.lastPathComponent == "zongyi2.pag", payload.range == 326..<370 {
                        // 原五色末间距near，剥末后剩三有效段且upper<1，源shader在尾部未给系数赋值。
                        guard case .invalidPrecision = program.result else {
                            Issue.record("zongyi2必须保留未定义尾部的明确失败")
                            return
                        }
                        #expect(program.first == SIMD4<Float>(1, 1, 1, 1))
                        #expect(program.last == SIMD4<Float>(177, 141, 228, 255) / 255)
                        invalidCount += 1
                        valueCount += 1
                        continue
                    }
                    guard case .analytic = program.result else {
                        Issue.record("真实颜色值未产生预期解析程序：\(url.lastPathComponent) \(payload.range)")
                        return
                    }
                    for time: Float in [0, 0.25, 0.5, 0.75, 1] {
                        let color = try GradientColorFixtures.sample(program, at: time)
                        #expect(color.x.isFinite && color.y.isFinite && color.z.isFinite && color.w.isFinite)
                    }
                    valueCount += 1
                }
                payloadCount += 1
            }
        }
        #expect(payloadCount == 32 && valueCount == 34 && invalidCount == 1 && textureCount == 1)
    }
}
