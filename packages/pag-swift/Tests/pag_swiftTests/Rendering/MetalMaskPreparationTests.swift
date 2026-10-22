import Metal
import Testing
@testable import pag_swift

/// 验证蒙版网格在取得drawable之前的预算边界、取消与失败回收。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"))
struct MetalMaskPreparationTests {
    /// 篡改计划中的补集位不能借同一个复合网格静默画反，失败不留GPU组附件。
    @Test func expressionInverseMismatchRejectsBatch() throws {
        let path = try ShapePathFixtures.square(20)
        let expression = try SampledMaskExpression(terms: [
            SampledMaskTerm(path: path, mode: .subtract, isInverted: false),
            SampledMaskTerm(path: path, mode: .add, isInverted: false)
        ])
        #expect(expression.isInverted)
        let invalid = FrameMask(layerID: try MetalGroupFixtures.layer, source: .expression(expression),
                                isInverted: false, matrix: .identity)
        let frame = MetalGroupFixtures.frame([.beginMask(invalid), try MetalGroupFixtures.solid(), .endMask])
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        #expect(throws: PAGError.renderingFailure("metalMaskInverseMismatch")) {
            try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 前面已准备图元后遇到无法区分零verb的Boolean空结果，也不能发布未裁剪半帧。
    @Test func ambiguousBooleanEmptyResultRejectsWholeBatch() throws {
        let path = try ShapePathFixtures.square(20)
        let expression = try SampledMaskExpression(terms: [
            SampledMaskTerm(path: path, mode: .add, isInverted: false),
            SampledMaskTerm(path: path, mode: .difference, isInverted: false)
        ])
        let mask = FrameMask(layerID: try MetalGroupFixtures.layer, source: .expression(expression),
                             isInverted: false, matrix: .identity)
        let frame = MetalGroupFixtures.frame([try MetalGroupFixtures.solid(), .beginMask(mask),
                                              try MetalGroupFixtures.solid(x: 50), .endMask])
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        #expect(throws: PAGError.unsupportedFeature("maskBooleanEmptyResult")) {
            try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 同一纯色图元增加蒙版后必须增加GPU输入成本；少一字节或预取消不能发布半帧。
    @Test func maskMeshBudgetAndCancellationAreAtomic() async throws {
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 0, y: 0), ScenePoint(x: 40, y: 0),
            ScenePoint(x: 40, y: 40), ScenePoint(x: 0, y: 40)
        ])
        let mask = FrameMask(layerID: try MetalGroupFixtures.layer, source: .path(path),
                             isInverted: false, matrix: .identity)
        let solid = try MetalGroupFixtures.solid()
        let plain = MetalGroupFixtures.frame([solid])
        let masked = MetalGroupFixtures.frame([.beginMask(mask), solid, .endMask])
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var plainBudget = try MetalFrameBudget()
        let plainBatch = try MetalFramePreparation.prepare(plain, width: 100, height: 100,
            resources: resources, budget: &plainBudget)
        plainBatch.releaseTransients()
        var maskBudget = try MetalFrameBudget()
        let maskBatch = try MetalFramePreparation.prepare(masked, width: 100, height: 100,
            resources: resources, budget: &maskBudget)
        maskBatch.releaseTransients()
        #expect(maskBudget.usedBytes > plainBudget.usedBytes)
        // 基础图元的精确费用已足够，只有蒙版额外的网格/常量会让这一帧失败。
        let baseCost = plainBudget.usedBytes
        let maskCost = maskBudget.usedBytes
        let base = try MetalFramePreparation.prepare(plain, width: 100, height: 100,
            resources: resources, maximumBytes: baseCost)
        base.releaseTransients()
        for limit in [baseCost, maskCost - 1] {
            #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
                try MetalFramePreparation.prepare(masked, width: 100, height: 100,
                    resources: resources, maximumBytes: limit)
            }
            #expect(resources.groups.activeBytes == 0)
        }
        let exact = try MetalFramePreparation.prepare(masked, width: 100, height: 100,
            resources: resources, maximumBytes: maskCost)
        #expect(exact.drawCount == 1)
        exact.releaseTransients()
        #expect(resources.groups.activeBytes == 0)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let isolated = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
            #expect(throws: CancellationError.self) {
                try MetalFramePreparation.prepare(masked, width: 100, height: 100, resources: isolated)
            }
            #expect(isolated.groups.activeBytes == 0)
        }
        try await cancelled.value
    }
}
