import Metal
import Testing
@testable import pag_swift

/// 真实Metal输入的渐变复用、RGBA退化及不可见材料失败顺序；此组不读取显示像素。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"))
struct MetalGradientPreparationTests {
    /// 八条材料/样式轨道分别驱动CPU和三个GPU输入身份，返回旧帧应恢复原对象。
    @Test func animatedMaterialsKeepOnlyMatchingBuffers() async throws {
        let owner = GradientPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        for field in 0..<8 {
            let scene = try await MetalStrokeFixtures.scene(GradientShapeFixtures.animated(field))
            let first = try await ShapePathFixtures.plan(scene, at: 0)
            let next = try await ShapePathFixtures.plan(scene, at: 5)
            let returned = try await ShapePathFixtures.plan(scene, at: 0)
            try await owner.verifyBuffers(first, next, returned, changesGeometry: field >= 4)
        }
    }

    /// 首色全透明的非退化渐变仍有绘制；退化保留自身alpha，再乘两层可折叠组alpha。
    @Test func transparentFirstAndDegenerateRGBAReachBatch() async throws {
        let owner = GradientPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        let colors = GradientColorFixtures.colors(alpha: [(0, 0), (1, 128)])
        let normal = GradientShapeFixtures.gradient(colors: .init(constant: colors))
        let scene = try await MetalStrokeFixtures.scene(GradientShapeFixtures.elements(normal))
        try await owner.verifyTransparentFirst(ShapePathFixtures.plan(scene, at: 0))
        let radial = GradientShapeFixtures.gradient(kind: .radial, start: .init(constant: .zero), end: .init(constant: .zero),
            colors: .init(constant: colors), opacity: .init(constant: 128))
        let group = ShapePropertyFixtures.group(opacity: .init(constant: 128))
        let nested: [SourceShape] = [.group(group, [.group(group, GradientShapeFixtures.elements(radial))])]
        let degenerate = try await MetalStrokeFixtures.scene(nested)
        try await owner.verifyDegenerate(ShapePathFixtures.plan(degenerate, at: 0))
    }

    /// 凸裁剪AABB相交但实际区域为空时，包括嵌套半透明多子项组，都先跳过不可用材料。
    @Test func emptyClipsPrecedeMaterialErrorsAcrossOpacityGroups() async throws {
        let owner = GradientPreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        let source = GradientShapeFixtures.gradient(colors: .init(constant: GradientShapeFixtures.excessiveColors()))
        let scene = try await MetalStrokeFixtures.scene(GradientShapeFixtures.elements(source))
        try await owner.verifyInvisibleFailures(ShapePathFixtures.plan(scene, at: 0))
        let empty = [ShapePropertyFixtures.rectangle(size: .init(constant: ScenePoint(x: 0, y: 20))),
                     SourceShape.gradientFill(.init(compositeOrder: .belowPrevious, gradient: source))]
        let emptyScene = try await MetalStrokeFixtures.scene(empty)
        try await owner.verifyEmptyGeometry(ShapePathFixtures.plan(emptyScene, at: 0))
    }

    /// 固定GPU常量的每字节布局和512逻辑字节预付门禁可独立验证；预取消保留CancellationError。
    @Test func packedLayoutBudgetAndCancellationAreExact() async throws {
        #expect(MemoryLayout<MetalGradientInterval>.stride == 48)
        #expect(MemoryLayout<MetalGradientUniforms>.stride == 464)
        #expect(MemoryLayout<MetalGradientUniforms>.alignment == 16)
        #expect(MemoryLayout<MetalGradientUniforms>.offset(of: \.header) == 64)
        #expect(MemoryLayout<MetalGradientUniforms>.offset(of: \.intervals) == 80)
        let layer = try ShapePropertyFixtures.prepare(GradientShapeFixtures.elements(GradientShapeFixtures.gradient()))
        let material = try #require(ShapePropertyFixtures.paints(layer).first).material.gradientValue()
        var small = try MetalFrameBudget(maximumBytes: 511)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try MetalGradientInput.make(material, origin: .zero, budget: &small)
        }
        var exact = try MetalFrameBudget(maximumBytes: 512)
        guard case .analytic(let input) = try MetalGradientInput.make(material, origin: .zero, budget: &exact) else {
            Issue.record("非退化双颜色必须使用解析输入"); return
        }
        #expect(input.header == SIMD4<UInt32>(0, 0, 1, 0))
        #expect(input.intervals.7.scale == .zero && input.intervals.7.bias == .zero && input.intervals.7.limits == .zero)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) { try exact.reserve(1) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = try MetalFrameBudget()
            _ = try MetalGradientInput.make(material, origin: .zero, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// 只在一个后台actor里创建/比较裸GPU输入；测试调用域仅传不可变语义帧。
private actor GradientPreparationOwner {
    /// 设备所有权从测试入口转入，不返回跨域别名。
    let device: any MTLDevice

    /// 接收独占设备引用，后续管线和资源均在此域访问。
    init(device: sending any MTLDevice) { self.device = device }

    /// 材料变化不重传网格的三个buffer；几何改变则替换，往返旧帧仍命中原输入。
    func verifyBuffers(_ first: PreparedFrame, _ next: PreparedFrame, _ returned: PreparedFrame, changesGeometry: Bool) throws {
        let resources = try MetalResources(device: device)
        let a = try batch(first, resources), b = try batch(next, resources), c = try batch(returned, resources)
        defer { a.releaseTransients(); b.releaseTransients(); c.releaseTransients() }
        #expect(a.passes.count == 1 && b.passes.count == 1 && c.passes.count == 1)
        #expect(a.loans.isEmpty && b.loans.isEmpty && c.loans.isEmpty)
        let old = try #require(a.passes.last?.draws.first), new = try #require(b.passes.last?.draws.first)
        let restored = try #require(c.passes.last?.draws.first)
        #expect(old.gradient != nil && new.gradient != nil && restored.gradient != nil)
        #expect((old.mesh === new.mesh) == !changesGeometry)
        #expect((old.mesh.buffer === new.mesh.buffer) == !changesGeometry)
        #expect((old.mesh.nodes === new.mesh.nodes) == !changesGeometry)
        #expect((old.mesh.triangles === new.mesh.triangles) == !changesGeometry)
        #expect(restored.mesh.buffer === old.mesh.buffer && restored.mesh.nodes === old.mesh.nodes && restored.mesh.triangles === old.mesh.triangles)
    }

    /// 不能用首边色alpha决定整条渐变不可见，输入只用paint opacity控制跳过。
    func verifyTransparentFirst(_ frame: PreparedFrame) throws {
        let result = try batch(frame, MetalResources(device: device))
        defer { result.releaseTransients() }
        let draw = try #require(result.passes.last?.draws.first)
        #expect(result.drawCount == 1 && draw.gradient?.first.w == 0 && draw.uniforms.color == .one)
    }

    /// 两次组alpha折叠保持退化材料，最终纯色只有蓝通道；此处核对值而非模拟shader。
    func verifyDegenerate(_ frame: PreparedFrame) throws {
        let result = try batch(frame, MetalResources(device: device))
        defer { result.releaseTransients() }
        let draw = try #require(result.passes.last?.draws.first)
        let a = Float(128) / 255, expected = a * a * a * a
        #expect(result.drawCount == 1 && result.loans.isEmpty && draw.gradient == nil)
        #expect(draw.uniforms.color.x == 0 && draw.uniforms.color.y == 0)
        #expect(abs(draw.uniforms.color.z - expected) < 0.000001 && abs(draw.uniforms.color.w - expected) < 0.000001)
    }

    /// 保持源资源表，改用两个斜裁剪和嵌套alpha组；对照可见材料必须仍报对应错误。
    func verifyInvisibleFailures(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let paint = try #require(ShapePathFixtures.fills(frame).first)
        let original = try paint.material.gradientValue()
        let size = try PAGSize(width: 40, height: 2)
        let first = FrameClip(size: size, matrix: try SceneAffine.rotation(degrees: 45).following(.translation(x: 20, y: 20)))
        let second = FrameClip(size: size, matrix: try SceneAffine.rotation(degrees: 45).following(.translation(x: 15, y: 25)))
        for invalidPrecision in [false, true] {
            let program = PreparedGradientColorizer(source: original.colorizer.source, first: original.colorizer.first,
                last: original.colorizer.last, result: invalidPrecision ? .invalidPrecision : .requiresTexture,
                estimatedBytes: original.colorizer.estimatedBytes)
            let material = PreparedGradient(kind: original.kind, start: original.start, end: original.end,
                matrix: original.matrix, colorizer: program, estimatedBytes: original.estimatedBytes)
            let draw = FrameCommand.shape(FrameShape(layerID: paint.layerID, geometryID: paint.geometryID,
                matrix: paint.matrix, material: .gradient(material), opacity: 1))
            for nested in [false, true] {
                let children = nested ? try MetalGroupFixtures.group(0.5, [draw, draw]) : [draw, draw]
                let commands: [FrameCommand] = [.beginGroup(.init(layerID: nil, frame: 0, clip: first, opacity: 0.5)),
                    .beginGroup(.init(layerID: nil, frame: 0, clip: second, opacity: 1))] + children + [.endGroup, .endGroup]
                let result = try batch(replacing(frame, commands: commands), resources)
                defer { result.releaseTransients() }
                #expect(result.drawCount == 0 && result.loans.isEmpty && result.passes.count == 1)
            }
            let error = invalidPrecision ? PAGError.renderingFailure("gradientPrecision") : .unsupportedFeature("gradientTextureColorizer")
            // 直接在owner内捕获，避免测试宏闭包把裸GPU缓存送出当前隔离域。
            do {
                let unexpected = try batch(replacing(frame, commands: [draw]), resources)
                unexpected.releaseTransients()
                Issue.record("可见的不可用材料必须失败")
            } catch let actual as PAGError { #expect(actual == error) }
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 网格为空时连映射/颜色限制都不消费，不能因为无像素的材料而中止帧。
    func verifyEmptyGeometry(_ frame: PreparedFrame) throws {
        let result = try batch(frame, MetalResources(device: device))
        defer { result.releaseTransients() }
        #expect(result.drawCount == 0 && result.loans.isEmpty)
    }

    /// 替换测试命令但保留真实准备几何，不重建另一份网格或猜测资源身份。
    private func replacing(_ frame: PreparedFrame, commands: [FrameCommand]) -> PreparedFrame {
        PreparedFrame(plan: FramePlan(time: frame.plan.time, targetBounds: frame.plan.targetBounds, commands: commands),
                      images: frame.images, shapes: frame.shapes, texts: frame.texts)
    }

    /// 使用真实共同准备路径，最终pass必须直接指向尚未取得的drawable。
    private func batch(_ frame: PreparedFrame, _ resources: MetalResources) throws -> MetalFrameBatch {
        let result = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        #expect(result.passes.last?.attachment == nil)
        return result
    }
}
