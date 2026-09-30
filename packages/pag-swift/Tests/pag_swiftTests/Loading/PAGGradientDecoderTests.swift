import Foundation
import Testing
@testable import pag_swift

/// 真实渐变载荷与独立原始字段探针对照；内部读取通过不代表整文件或显示已支持。
struct PAGGradientDecoderTests {
    /// 25个载荷的类型、默认值、每张表与颜色时间段逐项相符，并核对调查覆盖数量。
    @Test func allRealPayloadsMatchIndependentFields() throws {
        var fills = 0, strokes = 0, tables = 0, animated = 0, radial = 0
        var files = 0
        for url in try PAGFixtures.allPAGURLs() {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(Data(contentsOf: url))
            if inspection.gradientPayloads.isEmpty == false { files += 1 }
            for payload in inspection.gradientPayloads {
                let fields = try PAGGradientAuditTests().inspect(payload)
                var reader = payload.reader
                var decoder = GradientFixtures.decoder()
                let gradient: SourceGradient
                if payload.code == 22 {
                    let source = try decoder.readGradientFill(reader: &reader)
                    #expect(source.compositeOrder == .belowPrevious)
                    gradient = source.gradient
                    fills += 1
                } else {
                    let source = try decoder.readGradientStroke(reader: &reader)
                    let style = try #require(fields["stroke"] as? [String: Double])
                    #expect(source.width.initialValue == style["width"])
                    #expect(source.miterLimit.initialValue == style["miter"])
                    #expect(Double(source.cap.rawValue) == style["cap"])
                    #expect(Double(source.join.rawValue) == style["join"])
                    #expect(source.compositeOrder == .belowPrevious && source.dashes == nil)
                    gradient = source.gradient
                    strokes += 1
                }
                #expect(reader.remainingByteCount == 0)
                tables += try compare(gradient, with: fields, stroke: payload.code == 23)
                if gradient.isAnimated { animated += 1 }
                if gradient.kind == .radial { radial += 1 }
            }
        }
        #expect(fills == 19 && strokes == 6 && files == 10)
        #expect(tables == 27 && animated == 3 && radial == 11)
    }

    /// 固定真实值独立于调查探针：缺省坐标、交错表、字节alpha、非0.5中点与两段三值动画保持原值。
    @Test func defaultsAndAnimatedValuesRemainExact() throws {
        let stroke = try GradientFixtures.stroke()
        let gradient = stroke.gradient
        #expect(gradient.kind == .radial && gradient.start.initialValue == .zero)
        #expect(gradient.end.initialValue == ScenePoint(x: 100, y: 0))
        #expect(stroke.width.initialValue == 10 && stroke.miterLimit.initialValue == 4)
        #expect(stroke.cap == .butt && stroke.join == .miter && stroke.isAnimated == false)
        #expect(gradient.colors.initialValue.alphaStops.map(\.position) == [Float(25500) * 0.00002, Float(35312) * 0.00002])
        #expect(gradient.colors.initialValue.colorStops.map(\.color) == [
            SceneColor(red: 255, green: 248, blue: 6), SceneColor(red: 249, green: 248, blue: 6)])
        let fill = try GradientFixtures.fill("TextAnimatorMode.pag", range: 361..<390)
        #expect(fill.gradient.colors.initialValue.alphaStops.map(\.opacity) == [76, 51])
        let circle = try GradientFixtures.stroke("wstask_circle.pag", range: 2454..<2502)
        #expect(circle.gradient.colors.initialValue.alphaStops[0].midpoint == Float(32708) * 0.00002)
        let frames = try GradientFixtures.fill(range: 714..<846).gradient.colors.keyframes
        try #require(frames.count == 2)
        #expect(frames.map(\.startFrame) == [0, 28] && frames.map(\.endFrame) == [28, 41])
        #expect(frames[0].endValue === frames[1].startValue)
        #expect(frames[0].endValue.colorStops.map(\.color) == [
            SceneColor(red: 255, green: 39, blue: 101), SceneColor(red: 255, green: 131, blue: 91),
            SceneColor(red: 255, green: 223, blue: 81)])
    }

    /// 每个真实载荷的所有短前缀与单字节尾随都失败，不发布不完整渐变。
    @Test func everyRealPrefixAndTrailingByteFails() throws {
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(data)
            for payload in inspection.gradientPayloads {
                let bytes = data.subdata(in: payload.range)
                for end in 0..<bytes.count {
                    #expect(throws: PAGError.self) { try GradientFixtures.read(payload.code, data: bytes.prefix(end)) }
                }
                #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: bytes.count)) {
                    try GradientFixtures.read(payload.code, data: bytes + Data([0]))
                }
            }
        }
    }

    /// 按独立编码探针比对共同属性和每一段颜色端点，不把当前实现的数组结构当作预期值来源。
    private func compare(_ gradient: SourceGradient, with fields: [String: Any], stroke: Bool) throws -> Int {
        let values = try #require(fields["values"] as? [UInt8])
        #expect(gradient.kind.rawValue == values[stroke ? 2 : 3])
        #expect([gradient.start.initialValue.x, gradient.start.initialValue.y] == fields["startPoint"] as? [Double])
        #expect([gradient.end.initialValue.x, gradient.end.initialValue.y] == fields["endPoint"] as? [Double])
        #expect(gradient.opacity.initialValue == fields["opacity"] as? UInt8)
        let animated = try #require(fields["animatedFlags"] as? [Int])
        let index = stroke ? 3 : 4
        #expect(gradient.start.isAnimated == animated.contains(index))
        #expect(gradient.end.isAnimated == animated.contains(index + 1))
        #expect(gradient.colors.isAnimated == animated.contains(index + 2))
        #expect(gradient.opacity.isAnimated == animated.contains(index + 3))
        let tables = try #require(fields["colors"] as? [[String: Any]])
        let actual = [gradient.colors.initialValue] + gradient.colors.keyframes.map(\.endValue)
        try #require(actual.count == tables.count)
        for (value, table) in zip(actual, tables) {
            let alphas = try #require(table["alpha"] as? [[Int]])
            let colors = try #require(table["rgb"] as? [[Int]])
            #expect(value.alphaStops == alphas.map {
                SourceAlphaStop(position: Float($0[0]) * 0.00002, midpoint: Float($0[1]) * 0.00002, opacity: UInt8($0[2]))
            })
            #expect(value.colorStops == colors.map {
                SourceColorStop(position: Float($0[0]) * 0.00002, midpoint: Float($0[1]) * 0.00002,
                                color: SceneColor(red: UInt8($0[2]), green: UInt8($0[3]), blue: UInt8($0[4])))
            })
        }
        let times = try #require(fields["colorTimes"] as? [Int64])
        let kinds = try #require(fields["colorKinds"] as? [UInt32])
        #expect(gradient.colors.keyframes.map(\.startFrame) == Array(times.dropLast()))
        #expect(gradient.colors.keyframes.map(\.endFrame) == Array(times.dropFirst()))
        for (frame, kind) in zip(gradient.colors.keyframes, kinds) {
            switch frame.easing {
            case .hold: #expect(kind == 3)
            case .linear: #expect(kind <= 1)
            case .bezier(_, let second): #expect(kind == 2 && second == nil)
            }
        }
        return tables.count
    }
}
