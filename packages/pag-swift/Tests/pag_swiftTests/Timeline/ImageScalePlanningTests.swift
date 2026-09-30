import Testing
@testable import pag_swift

/// 文件缩放表到替换命令的映射；直接语义图覆盖真实资源尚未出现的乱序索引和四种模式。
struct ImageScalePlanningTests {
    /// 四种替换各自保持比例/原点语义，原图裁边不受影响，nil恢复且旧计划保持不可变。
    @Test(arguments: [PAGScaleMode.none, .stretch, .aspectFit, .aspectFill])
    func replacementModesPreserveOriginalAndRestore(_ mode: PAGScaleMode) async throws {
        let file = try await fixture(modes: [mode])
        let originalMatrix = try originalMatrix()
        let replacementMatrix = try expected(mode)
        let clip = try FrameClip(size: PAGSize(width: 100, height: 80), matrix: .identity)
        let original = try await images(file.composition)
        #expect(original.count == 6 && original.allSatisfy { $0.matrix == originalMatrix && $0.clip == nil })
        var edited = file.composition
        try edited.replaceImage(input(in: file), at: 0)
        let commands = try await images(edited)
        for command in commands {
            let replaced = command.layerID?.path.last == 11
            #expect(command.matrix == (replaced ? replacementMatrix : originalMatrix))
            #expect(command.clip == (replaced ? clip : nil))
        }
        try edited.replaceImage(nil, at: 0)
        let restored = try await images(edited)
        #expect(restored.allSatisfy { $0.matrix == originalMatrix && $0.clip == nil })
        #expect(original.allSatisfy { $0.matrix == originalMatrix && $0.clip == nil })
        #expect(commands.filter { $0.layerID?.path.last == 11 }.allSatisfy { $0.matrix == replacementMatrix })
    }

    /// 缩放表按原始[2,0]顺序配对，公开索引仍升序；按名称替换同样使用源槽且不额外开放索引权限。
    @Test func sparseUnsortedIndicesMapSharedInstances() async throws {
        let file = try await fixture(allowed: [2, 0], modes: [.none, .stretch])
        let originalMatrix = try originalMatrix()
        #expect(file.editableImageIndices == [0, 2])
        var edited = file.composition
        let input = try input(in: file)
        #expect(throws: PAGError.invalidEditableIndex(1)) { try edited.replaceImage(input, at: 1) }
        try edited.replaceImage(input, named: "match")
        let commands = try await images(edited)
        #expect(commands.map { $0.layerID?.path } == [[22, 13], [22, 12], [22, 11], [21, 13], [21, 12], [21, 11]])
        for command in commands {
            let mode: PAGScaleMode = switch command.layerID?.path.last {
            case 13: .none
            case 11: .stretch
            default: .aspectFit
            }
            #expect(command.matrix == (try expected(mode)))
            #expect(command.clip == (try FrameClip(size: PAGSize(width: 100, height: 80), matrix: .identity)))
        }
        try edited.replaceImage(nil, named: "match")
        #expect(try await images(edited).allSatisfy { $0.matrix == originalMatrix && $0.clip == nil })
    }

    /// 短表缺项回退LetterBox，长表尾部不分配给未允许槽；缺失或空表不改变允许索引。
    @Test func shortLongAndMissingTablesKeepFallbacks() async throws {
        let short = try await fixture(allowed: [2, 0], modes: [.aspectFill])
        let long = try await fixture(allowed: [2, 0], modes: [.none, .stretch, .aspectFill, .none])
        let absent = try await fixture(allowed: [2, 0], modes: nil)
        let empty = try await fixture(allowed: [2, 0], modes: [])
        let noAllowed = try await fixture(allowed: [], modes: [.none, .stretch, .aspectFill])
        for (file, modes) in [(short, [PAGScaleMode.aspectFit, .aspectFit, .aspectFill]),
                              (long, [.stretch, .aspectFit, .none]),
                              (absent, [.aspectFit, .aspectFit, .aspectFit]),
                              (empty, [.aspectFit, .aspectFit, .aspectFit]),
                              (noAllowed, [.aspectFit, .aspectFit, .aspectFit])] {
            var edited = file.composition
            try edited.replaceImage(input(in: file), named: "match")
            for command in try await images(edited) {
                let id = try #require(command.layerID?.path.last)
                #expect(command.matrix == (try expected(modes[Int(id) - 11])))
            }
            #expect(file.storage.catalog.imageScaleMode(for: SourceLayerReference(composition: 99, layer: 0)) == .aspectFit)
        }
        #expect(noAllowed.editableImageIndices.isEmpty)
        var locked = noAllowed.composition
        #expect(throws: PAGError.invalidEditableIndex(0)) { try locked.replaceImage(nil, at: 0) }
        #expect(long.storage.resources.imageScaleModes?.count == 4)
    }

    /// 三个不同源图片槽各自被两个预合成实例引用；真实PNG只作为输入，不冒充PAG编码。
    private func fixture(allowed: [Int]? = nil, modes: [PAGScaleMode]?) async throws -> PAGFile {
        let input = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        var resources = SourceResources(allowedImages: allowed, imageScaleModes: modes)
        for id in UInt32(1)...3 {
            resources.images[id] = SourceImage(id: id, image: input, logicalSize: try PAGSize(width: 100, height: 80),
                scaleFactor: 0.5, anchor: ScenePoint(x: -8, y: 4))
        }
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(11, name: "match", content: .image(1)),
            SceneFixtures.layer(12, name: "match", content: .image(2)),
            SceneFixtures.layer(13, name: "match", content: .image(3))
        ])
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(22, content: .precomposition(id: 1, startFrame: 0))
        ])
        return try SceneFixtures.build([child, root], resources: resources)
    }

    /// 保留源图片的scale和anchor预期，与文件替换模式无关。
    private func originalMatrix() throws -> SceneAffine { try SceneAffine(a: 2, b: 0, c: 0, d: 2, tx: 8, ty: -4) }

    /// 2×2输入映射到100×80逻辑矩形的独立算术预期，None沿用左上原点。
    private func expected(_ mode: PAGScaleMode) throws -> SceneAffine {
        switch mode {
        case .none: .identity
        case .stretch: try SceneAffine(a: 50, b: 0, c: 0, d: 40, tx: 0, ty: 0)
        case .aspectFit: try SceneAffine(a: 40, b: 0, c: 0, d: 40, tx: 10, ty: 0)
        case .aspectFill: try SceneAffine(a: 50, b: 0, c: 0, d: 50, tx: 0, ty: -10)
        }
    }

    /// 从同一语义夹具取得替换输入，使像素相同但布局不同的情况得到覆盖。
    private func input(in file: PAGFile) throws -> PAGImage {
        try #require(file.storage.resources.images[1]?.image)
    }

    /// 在原始根尺寸的首帧生成计划，返回实际覆盖顺序的图片命令。
    private func images(_ composition: PAGComposition) async throws -> [FrameImage] {
        let scene = try await PreparedScene.prepare(composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: composition.size, scale: 1, mode: .none)
        return frame.plan.commands.compactMap { if case .image(let value) = $0 { value } else { nil } }
    }
}
