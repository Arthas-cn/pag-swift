import Testing
@testable import pag_swift

/// 渐变Float坐标、paint逆矩阵及退化优先级；独立数学期望不依赖生产片元。
struct GradientTransformTests {
    /// 合同中的shear/非均匀缩放与网格原点产生确定系数，不能改成显示空间端点投影。
    @Test(arguments: [SourceGradientKind.linear, .radial])
    func shearAndOriginMatchIndependentMapping(_ kind: SourceGradientKind) throws {
        let paint = try SceneAffine(a: 2, b: 0, c: 1, d: 4, tx: 8, ty: 16)
        let source = try gradient(kind: kind, matrix: paint)
        let matrix = try mapped(source, origin: ScenePoint(x: 8, y: 16))
        #expect(try matrix == GradientTransform(a: 0.125, c: -0.03125, d: 0.0625))
        let unit = apply(matrix, to: SIMD2(4, 4))
        #expect(unit == SIMD2<Float>(0.375, 0.25))
        if kind == .linear { #expect(unit.x + 0.00001 == Float(0.375) + 0.00001) }
        else { #expect((unit.x * unit.x + unit.y * unit.y).squareRoot() == Float(13).squareRoot() / 8) }
    }

    /// 斜向有平移的Linear按setSinCos三步构造，起点/终点映到0/1；径向保留两个方向的半径比例。
    @Test func translatedDiagonalUsesLocalCoordinates() throws {
        let linear = try gradient(start: ScenePoint(x: 3, y: 7), end: ScenePoint(x: 6, y: 11))
        let matrix = try mapped(linear)
        let start = apply(matrix, to: SIMD2(3, 7)), end = apply(matrix, to: SIMD2(6, 11))
        #expect(abs(start.x) < 0.000001 && abs(start.y) < 0.000001)
        #expect(abs(end.x - 1) < 0.000001 && abs(end.y) < 0.000001)
        let radial = try mapped(gradient(kind: .radial, start: ScenePoint(x: 3, y: 7), end: ScenePoint(x: 6, y: 11)))
        #expect(abs(apply(radial, to: SIMD2(6, 11)).x - 0.6) < 0.000001)
        #expect(abs(apply(radial, to: SIMD2(6, 11)).y - 0.8) < 0.000001)
    }

    /// Float复合必须先tx=B.tx*A.a+A.tx再加B.ty*A.c；Double重排会错误得到1。
    @Test func concatenationKeepsSourceRoundingOrder() throws {
        let first = try GradientTransform(a: 1, c: 1, d: 1, tx: 1)
        let second = try GradientTransform(a: 1, d: 1, tx: 16_777_216, ty: -16_777_216)
        #expect(try first.concatenating(second).tx == 0)
        // 网格origin属于Double重定位政策，此处恰好需要保留被Float转换提前吞掉的1。
        let moved = try GradientTransform(a: 1, d: 1, tx: -16_777_216)
            .compensating(origin: ScenePoint(x: 16_777_217, y: 0))
        #expect(moved.tx == 1 && moved.a == 1)
    }

    /// 负缩放保留方向；无shear分支仅拒绝零轴，不套一般仿射的面积阈值。
    @Test func negativeAndTinyAxisScalesRemainUsable() throws {
        let mirror = try mapped(gradient(matrix: SceneAffine.scale(x: -2, y: 4)))
        #expect(mirror.a == -0.125 && mirror.d == 0.0625)
        let tiny = Double(Float(1) / 1_073_741_824)
        let value = try mapped(gradient(matrix: SceneAffine.scale(x: tiny, y: tiny)))
        #expect(value.a == 268_435_456 && value.d == 268_435_456)
    }

    /// 一般仿射的det等于2^-36时失败，略大于阈值可用；奇异paint不继承Stroke忽略矩阵的回落。
    @Test func affineThresholdAndSingularPaintFailExplicitly() throws {
        let axis = Float(1) / 262_144
        let boundary = try SceneAffine(a: Double(axis), b: 0.5, c: 0, d: Double(axis), tx: 0, ty: 0)
        #expect(throws: PAGError.renderingFailure("gradientTransform")) { try mapped(gradient(matrix: boundary)) }
        let above = try SceneAffine(a: Double(axis.nextUp), b: 0.5, c: 0, d: Double(axis), tx: 0, ty: 0)
        #expect(try mapped(gradient(matrix: above)).a.isFinite)
        let singular = try SceneAffine(a: 1, b: 1, c: 1, d: 1, tx: 0, ty: 0)
        #expect(throws: PAGError.renderingFailure("gradientTransform")) { try mapped(gradient(matrix: singular)) }
    }

    /// 非有限源Float长度、paint转换或网格补偿明确失败，不能靠Double/hypot使其成功。
    @Test func nonfiniteIntermediatesFail() throws {
        let huge = try gradient(end: ScenePoint(x: 1e30, y: 0))
        #expect(throws: PAGError.renderingFailure("gradientPrecision")) { try mapped(huge) }
        let transform = try SceneAffine.scale(x: 1e100, y: 1)
        #expect(throws: PAGError.renderingFailure("gradientPrecision")) { try mapped(gradient(matrix: transform)) }
        let normal = try gradient()
        #expect(throws: PAGError.renderingFailure("gradientPrecision")) { try mapped(normal, origin: ScenePoint(x: .infinity, y: 0)) }
    }

    /// 超过16色的颜色程序不可解析，零长度仍优先取完整RGBA；Linear首色与Radial末色不同。
    @Test(arguments: [SourceGradientKind.linear, .radial])
    func degeneracyPrecedesProgramAndInverseFailures(_ kind: SourceGradientKind) throws {
        let colors = GradientColorFixtures.colors(rgb: (0...16).map {
            (Float($0) / 16, $0 == 0 ? GradientColorFixtures.red : GradientColorFixtures.blue)
        }, alpha: [(0, 0), (1, 128)])
        let program = try GradientColorFixtures.compile(colors)
        guard case .requiresTexture = program.result else { Issue.record("夹具应超过解析色数"); return }
        let singular = try SceneAffine.scale(x: 0, y: 0)
        let threshold = Float(1) / 32768
        for length: Float in [0, threshold] {
            let value = try gradient(kind: kind, end: ScenePoint(x: Double(length), y: 0), matrix: singular, colorizer: program)
            guard case .solid(let color) = try GradientTransform.layout(for: value) else { Issue.record("退化必须为solid"); return }
            #expect(color == (kind == .linear ? program.first : program.last))
        }
        let nondegenerate = try gradient(kind: kind, end: ScenePoint(x: Double(threshold.nextUp), y: 0), colorizer: program)
        #expect(throws: PAGError.unsupportedFeature("gradientTextureColorizer")) { try GradientTransform.layout(for: nondegenerate) }
    }

    /// invalidPrecision颜色状态也必须等布局退化之后处理，同程序退化往返不能缓存成永远可画。
    @Test func invalidProgramIsDeferredUntilNondegenerate() throws {
        let program = try GradientColorFixtures.compile(GradientColorFixtures.colors(
            rgb: [0, 1, 2, 49998, 49999, 50000].map { (Float($0) * 0.00002, GradientColorFixtures.red) }))
        guard case .invalidPrecision = program.result else { Issue.record("夹具应有未定义尾部"); return }
        for length: Double in [0, 4, 0] {
            let value = try gradient(end: ScenePoint(x: length, y: 0), colorizer: program)
            if length == 0 {
                guard case .solid = try GradientTransform.layout(for: value) else { Issue.record("零长度不能被状态拒绝"); return }
            } else {
                #expect(throws: PAGError.renderingFailure("gradientPrecision")) { try GradientTransform.layout(for: value) }
            }
        }
    }

    /// 已取消布局即使可退化也不能成功返回，后台入口不依赖主actor。
    @Test func cancelledLayoutDoesNotReturnSolid() async throws {
        let value = try gradient(end: .zero)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask { #expect(throws: CancellationError.self) { try GradientTransform.layout(for: value) } }
            for try await _ in group {}
        }
    }

    /// 构造纯语义材料，保活真实编译颜色程序；不生成字节文件或平台显示对象。
    private func gradient(kind: SourceGradientKind = .linear, start: ScenePoint = .zero,
                          end: ScenePoint = ScenePoint(x: 4, y: 0), matrix: SceneAffine = .identity,
                          colorizer: PreparedGradientColorizer? = nil) throws -> PreparedGradient {
        let program = try colorizer ?? GradientColorFixtures.compile(GradientColorFixtures.colors())
        return PreparedGradient(kind: kind, start: start, end: end, matrix: matrix,
                                colorizer: program, estimatedBytes: 256 + program.estimatedBytes)
    }

    /// 映射断言前明确要求非退化分支，避免把solid误当单位矩阵通过。
    private func mapped(_ gradient: PreparedGradient, origin: ScenePoint = .zero) throws -> GradientTransform {
        guard case .mapped(let matrix) = try GradientTransform.layout(for: gradient, origin: origin) else {
            throw PAGError.invalidArgument("gradientTestExpectedMapping")
        }
        return matrix
    }

    /// 测试端在给定坐标上检查已编译系数，不调用另一个生产坐标求值器作期望。
    private func apply(_ matrix: GradientTransform, to point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(matrix.a * point.x + matrix.c * point.y + matrix.tx,
              matrix.b * point.x + matrix.d * point.y + matrix.ty)
    }
}
