import CoreGraphics
import Testing
@testable import pag_swift

/// 真实 PAG 字体轮廓进入渲染网格，对照独立系统曲线填充；不声称已经通过 GPU 画面验收。
struct GlyphMeshTests {
    /// TEXT04 全部填充/描边网格都必须保留曲线覆盖与孔洞，远离边界的采样与 CGPath nonzero 一致。
    @Test func realPAGGlyphsMatchSystemPathCoverage() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let text = try #require(scene.texts.values.first)
        var cache = try RenderGeometryCache()
        var checked = 0
        for (glyphIndex, glyph) in text.glyphs.enumerated() {
            for (pass, outline) in [glyph.fill, glyph.stroke].compactMap({ $0 }).enumerated() {
                var budget = try GeometryBudget()
                // 使用 8 倍显示精度，参照检查排除 1/32 源单位的曲线边缘，超过最大细分误差。
                let transform = try glyph.matrix.following(.scale(x: 8, y: 8))
                let mesh = try cache.mesh(for: .glyph(outline), transform: transform, budget: &budget)
                let reference = GeometryTestSupport.systemPath(outline)
                let edge = reference.copy(strokingWithWidth: 0.0625, lineCap: .round, lineJoin: .round, miterLimit: 10)
                let bounds = reference.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
                var differences = 0
                var overlaps = 0
                // 固定无理数式步进覆盖内部与外部，不受全局随机状态或三角形对角线巧合影响。
                for sample in 0..<1000 {
                    let x = bounds.minX + bounds.width * (Double(sample) * 0.61803398875).truncatingRemainder(dividingBy: 1)
                    let y = bounds.minY + bounds.height * (Double(sample) * 0.41421356237 + 0.17).truncatingRemainder(dividingBy: 1)
                    let point = CGPoint(x: x, y: y)
                    guard !edge.contains(point, using: .winding) else { continue }
                    let coverage = GeometryTestSupport.coverage(mesh, at: ScenePoint(x: x, y: y))
                    if (coverage > 0) != reference.contains(point, using: .winding) { differences += 1 }
                    if coverage > 1 { overlaps += 1 }
                    checked += 1
                }
                #expect(differences == 0, "glyph \(glyphIndex), pass \(pass) 的曲线填充覆盖不同")
                #expect(overlaps == 0, "glyph \(glyphIndex), pass \(pass) 的三角形内部重叠")
                #expect(!mesh.vertices.isEmpty)
            }
        }
        #expect(checked > 10_000 && cache.count > 0)
    }
}
