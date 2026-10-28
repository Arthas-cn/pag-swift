import Testing
@testable import pag_swift

/// 描边坐标逆变换的Float分支边界；可逆性与填充的Double面积判定不是同一合同。
struct StrokeTransformTests {
    /// 单位、反射缩放与一般仿射恢复独立已知坐标，避免把矩阵顺序或平移符号写反。
    @Test func inverseRestoresKnownCoordinates() throws {
        #expect(try StrokeEvaluation.inverse(of: .identity) == .identity)
        let diagonal = try SceneAffine(a: -2, b: 0, c: 0, d: 4, tx: 10, ty: -20)
        let diagonalInverse = try #require(try StrokeEvaluation.inverse(of: diagonal))
        #expect(diagonalInverse == (try SceneAffine(a: -0.5, b: 0, c: 0, d: 0.25, tx: 5, ty: 5)))
        let matrix = try SceneAffine(a: 2, b: 1, c: 4, d: 4, tx: 10, ty: -20)
        let inverse = try #require(try StrokeEvaluation.inverse(of: matrix))
        #expect(inverse == (try SceneAffine(a: 1, b: -0.25, c: -1, d: 0.5, tx: -30, ty: 12.5)))
        #expect(try inverse.applying(to: ScenePoint(x: 36, y: 3)) == ScenePoint(x: 3, y: 5))
    }

    /// 极小对角矩阵仍按非零单轴求逆；一般仿射在2^-36处及以下失败，边界外成功。
    @Test func diagonalAndGeneralThresholdsAreDistinct() throws {
        let tiny = try SceneAffine.scale(x: Double(Float(1e-8)), y: Double(Float(1e-8)))
        let result = try #require(try StrokeEvaluation.inverse(of: tiny))
        #expect(result.a == 100_000_000 && result.d == 100_000_000)
        #expect(try StrokeEvaluation.inverse(of: SceneAffine.scale(x: 0, y: 1)) == nil)
        let threshold: Float = 1 / 68_719_476_736
        for value in [threshold.nextDown, threshold, threshold.nextUp, -threshold, -threshold.nextUp] {
            let matrix = try SceneAffine(a: Double(value), b: 1, c: 0, d: 1, tx: 0, ty: 0)
            #expect((try StrokeEvaluation.inverse(of: matrix) != nil) == (abs(value) > threshold))
        }
        #expect(try StrokeEvaluation.inverse(of: SceneAffine(a: 1, b: 2, c: 2, d: 4, tx: 0, ty: 0)) == nil)
    }

    /// 有限Double输入若在Float行列式、倒数或平移中溢出，应报错而不是奇异矩阵回落。
    @Test func nonfiniteIntermediateResultsFail() throws {
        let maximum = Double(Float.greatestFiniteMagnitude)
        let matrices = [
            try SceneAffine(a: maximum, b: 1, c: 0, d: 2, tx: 0, ty: 0),
            try SceneAffine.scale(x: Double(Float.leastNonzeroMagnitude), y: 1),
            try SceneAffine(a: 1e-8, b: 0, c: 0, d: 1, tx: maximum, ty: 0)
        ]
        for matrix in matrices {
            #expect(throws: SceneValidator.invalid("unrepresentableStrokeTransform")) {
                try StrokeEvaluation.inverse(of: matrix)
            }
        }
        #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try StrokeEvaluation.inverse(of: SceneAffine.scale(x: Double.greatestFiniteMagnitude, y: 1))
        }
    }

    /// 已取消任务不能通过单位矩阵的快速路径发布逆变换。
    @Test func precancelledInverseFails() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeEvaluation.inverse(of: .identity)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
