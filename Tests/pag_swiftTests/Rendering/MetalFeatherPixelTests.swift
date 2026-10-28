#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 在已挂载的真实macOS drawable核对羽化透明度的整层合成顺序和局部附件归还。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalFeatherPixelTests {
    /// 两个半透明子层先SrcOver再乘一次蒙版alpha；中心应为(64,0,32,96)而不是逐draw裁剪值。
    @MainActor @Test func opacityMaskAppliesAfterCompositedPrecomposition() async throws {
        let actual = try await pixels(try await plan(), at: [SIMD2(50, 50), SIMD2(85, 50)])
        try expect(actual, near: [SIMD4(64, 0, 32, 96), .zero])
    }

    /// 父羽化包住子普通矩形clip时，裁剪外必须透明，随后加入的兄弟蓝层不得继承子clip。
    @MainActor @Test func nestedRectangleClipInsideFeatherKeepsSiblingPixels() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let red = SceneFixtures.layer(11,
            content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0)),
            masks: [MaskTestSupport.mask(.init(constant: try rectangularPath(left: 0, right: 60,
                                                                                bottom: 100)))])
        let blueTransform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 60, y: 0), scale: .one, rotation: 0, opacity: 255))
        let blue = SceneFixtures.layer(12, transform: blueTransform,
            content: .solid(size: try PAGSize(width: 40, height: 100),
                            color: SceneColor(red: 0, green: 0, blue: 255)))
        let outerMask = MaskTestSupport.mask(.init(constant: try rectangularPath(left: 0, right: 100,
                                                                                  bottom: 100)),
                                             opacity: .init(constant: 128))
        let parent = SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0),
                                         masks: [outerMask])
        for layers in [[red], [red, blue]] {
            // 先隔离子裁剪验证外部透明，再加入兄弟证明endMask恢复原作用域。
            let child = try SceneFixtures.composition(1, layers: layers)
            let file = try SceneFixtures.build([child, SceneFixtures.composition(2, layers: [parent])])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: size, scale: 1, mode: .none)
            let actual = try await pixels(frame, at: [SIMD2(30, 50), SIMD2(80, 50)])
            let far: SIMD4<UInt8> = layers.count == 1 ? .zero : SIMD4(0, 0, 128, 128)
            try expect(actual, near: [SIMD4(128, 0, 0, 128), far])
        }
    }

    /// 水平feather=4应把路径右侧透明halo写到总体mask；x=60/62逐点锁定Gaussian衰减。
    @MainActor @Test func positiveFeatherKeepsDecalHaloAtPathEdge() async throws {
        let actual = try await pixels(try await blurPlan(),
            at: [SIMD2(58, 50), SIMD2(60, 50), SIMD2(62, 50), SIMD2(65, 50)])
        // 独立Gaussian半核：sigma=2、radius=4，阶跃边界卷积依次约0.782、0.398、0.094、0。
        try expect(actual, near: [SIMD4(199, 0, 0, 199), SIMD4(101, 0, 0, 101),
                                  SIMD4(24, 0, 0, 24), .zero])
    }

    /// 两轴羽化在角点应相乘而非取最大值；远端超过halo后仍是透明。
    @MainActor @Test func twoAxisFeatherMultipliesAtCorner() async throws {
        let frame = try await blurPlan(bottom: 60, feather: ScenePoint(x: 4, y: 4))
        let actual = try await pixels(frame,
            at: [SIMD2(50, 50), SIMD2(60, 50), SIMD2(50, 60), SIMD2(60, 60), SIMD2(65, 65)])
        try expect(actual, near: [SIMD4(255, 0, 0, 255), SIMD4(101, 0, 0, 101),
                                  SIMD4(101, 0, 0, 101), SIMD4(40, 0, 0, 40), .zero])
    }

    /// 非零路径起点需要先映入自身局部alpha表面，左侧halo仍须对齐原图坐标。
    @MainActor @Test func nonzeroPathOriginPreservesLeftHalo() async throws {
        let frame = try await blurPlan(left: 20, feather: ScenePoint(x: 4, y: 0))
        let actual = try await pixels(frame,
            at: [SIMD2(15, 50), SIMD2(18, 50), SIMD2(20, 50), SIMD2(25, 50)])
        // 左缘x=18距首个覆盖像素两点，包含核的offset=2/3/4三项，约56/255。
        try expect(actual, near: [.zero, SIMD4(56, 0, 0, 56),
                                  SIMD4(154, 0, 0, 154), SIMD4(255, 0, 0, 255)])
    }

    /// 羽化尾部接近总体bounds的10%裁边仍应有衰减值，裁边之外不能泄漏alpha。
    @MainActor @Test func overallTenPercentOutsetClipsLargeFeather() async throws {
        let frame = try await blurPlan(feather: ScenePoint(x: 12, y: 0))
        let actual = try await pixels(frame, at: [SIMD2(63, 50), SIMD2(65, 50), SIMD2(66, 50)])
        // sigma=6、radius=12；x=65仅取offset 6...12的归一化权重，约43/255。
        try expect(actual, near: [SIMD4(69, 0, 0, 69), SIMD4(43, 0, 0, 43), .zero])
    }

    /// feather=22触发上游sigma钳10及局部降采样；边缘须平滑衰减并在总体裁边归零。
    @MainActor @Test func highSigmaResamplesBeforeAndAfterGaussian() async throws {
        let frame = try await blurPlan(feather: ScenePoint(x: 22, y: 0))
        let actual = try await pixels(frame,
            at: [SIMD2(50, 50), SIMD2(55, 50), SIMD2(60, 50), SIMD2(65, 50), SIMD2(66, 50)])
        // 独立标量参照：扩出22、roundOut后95/104倍率、sigma10/radius20，两次线性采样。
        try expect(actual, near: [SIMD4(209, 0, 0, 209), SIMD4(170, 0, 0, 170),
                                  SIMD4(123, 0, 0, 123), SIMD4(77, 0, 0, 77), .zero])
    }

    /// 负起点的大羽化源样本先按总体surface裁剪，左端和右端仍须连续衰减。
    @MainActor @Test func highSigmaNegativeOriginUsesVisibleSourceClip() async throws {
        let frame = try await blurPlan(left: -10, feather: ScenePoint(x: 22, y: 0))
        let actual = try await pixels(frame,
            at: [SIMD2(0, 50), SIMD2(2, 50), SIMD2(5, 50), SIMD2(10, 50),
                 SIMD2(50, 50), SIMD2(55, 50), SIMD2(60, 50), SIMD2(65, 50), SIMD2(66, 50)])
        // 独立标量核：可见clip使样本从[-22,92]变为[-12,92]，缩纹理95宽且倍率95/104。
        try expect(actual, near: [SIMD4(215, 0, 0, 215), SIMD4(226, 0, 0, 226),
                                  SIMD4(239, 0, 0, 239), SIMD4(252, 0, 0, 252),
                                  SIMD4(209, 0, 0, 209), SIMD4(170, 0, 0, 170),
                                  SIMD4(123, 0, 0, 123), SIMD4(77, 0, 0, 77), .zero])
    }

    /// 羽化分支的矩形正扩张在原路径外留下alpha，负扩张向内收缩；两者都经正式局部GPU路径。
    @MainActor @Test func rectangularExpansionChangesFeatherMaskPixels() async throws {
        let expanded = try await pixels(try await blurPlan(feather: .zero, expansion: 4),
                                        at: [SIMD2(2, 50), SIMD2(50, 50), SIMD2(62, 50), SIMD2(65, 50)])
        try expect(expanded, near: [SIMD4(255, 0, 0, 255), SIMD4(255, 0, 0, 255),
                                    SIMD4(255, 0, 0, 255), .zero])
        let inset = try await pixels(try await blurPlan(feather: .zero, expansion: -4),
                                     at: [SIMD2(2, 50), SIMD2(6, 50), SIMD2(54, 50), SIMD2(58, 50)])
        try expect(inset, near: [.zero, SIMD4(255, 0, 0, 255), SIMD4(255, 0, 0, 255), .zero])
    }

    /// 首项Subtract只翻转本项补集，源inverse再翻回；角落与中心用实际圆角扩张画面区分。
    @MainActor @Test func rectangularExpansionKeepsFirstSubtractAndInverse() async throws {
        let subtract = try await pixels(try await blurPlan(left: 20, top: 20, bottom: 60,
            feather: .zero, expansion: 4, mode: .subtract),
            at: [SIMD2(16, 16), SIMD2(30, 30), SIMD2(70, 30)])
        try expect(subtract, near: [SIMD4(255, 0, 0, 255), .zero, .zero])
        let restored = try await pixels(try await blurPlan(left: 20, top: 20, bottom: 60,
            feather: .zero, expansion: 4, mode: .subtract, inverted: true),
            at: [SIMD2(16, 16), SIMD2(30, 30), SIMD2(70, 30)])
        try expect(restored, near: [.zero, SIMD4(255, 0, 0, 255), .zero])
    }

    /// 两轴都超过sigma10时须分别roundOut降采样并分轴卷积，角点RGBA取两轴衰减乘积。
    @MainActor @Test func highSigmaTwoAxisCornerUsesIndependentScales() async throws {
        let frame = try await blurPlan(bottom: 60, feather: ScenePoint(x: 22, y: 26))
        let actual = try await pixels(frame, at: [SIMD2(50, 50), SIMD2(60, 50),
                                                 SIMD2(50, 60), SIMD2(60, 60),
                                                 SIMD2(65, 65), SIMD2(66, 66)])
        // 独立标量参照：中间区95×87、实际比例95/104与87/112、水平后垂直各量化一次。
        try expect(actual, near: [SIMD4(164, 0, 0, 164), SIMD4(96, 0, 0, 96),
                                  SIMD4(102, 0, 0, 102), SIMD4(60, 0, 0, 60),
                                  SIMD4(26, 0, 0, 26), .zero])
    }

    /// 父层1.17倍缩放量化局部表面为1.2倍后，屏幕边缘仍按原1.17倍位置衰减与裁切。
    @MainActor @Test func fractionalDisplayScaleKeepsFeatherPosition() async throws {
        let frame = try await blurPlan(scale: 1.17)
        let actual = try await pixels(frame,
            at: [SIMD2(66, 50), SIMD2(70, 50), SIMD2(72, 50), SIMD2(78, 50)])
        #expect(actual[0].w >= 200)
        #expect(actual[1].w > 50 && actual[1].w < 200)
        #expect(actual[2].w > 0 && actual[2].w < actual[1].w)
        // 源总体右边66映到显示约77.22；x=78完全在效果范围外。
        #expect(actual[3] == .zero)
    }

    /// 羽化作用域内的静态Shape Picture标记先验证再逐draw回退，错位标记不能绕过局部检查。
    @MainActor @Test func shapePictureInsideFeatherUsesOriginalDrawing() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let shape: [SourceShape] = [
            .rectangle(reversed: false, size: ScenePoint(x: 100, y: 100),
                       position: ScenePoint(x: 50, y: 50), roundness: 0),
            .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)
        ]
        let mask = MaskTestSupport.mask(.init(constant: try rectangularPath(left: 0, right: 60,
                                                                              bottom: 100)), opacity: .init(constant: 128))
        let layer = SceneFixtures.layer(1, content: .shape(shape), masks: [mask])
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        #expect(frame.plan.commands.contains { if case .beginPicture = $0 { true } else { false } })
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                                                      resources: resources, pictures: resources.pictures)
        #expect(batch.pictureWorks.isEmpty && batch.featherWorks.count == 1)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0 && resources.pictures.activeBytes == 0)
        var malformed = frame.plan.commands
        let pictureIndex = try #require(malformed.firstIndex { if case .beginPicture = $0 { true } else { false } })
        guard case .beginPicture(let marker) = malformed[pictureIndex] else {
            Issue.record("缺少Shape Picture入口")
            return
        }
        malformed[pictureIndex] = .beginPicture(FramePicture(document: marker.document,
            source: marker.source, matrix: try .translation(x: 1, y: 0), content: marker.content))
        let badFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: malformed),
            images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
        #expect(throws: PAGError.renderingFailure("metalPictureShapeIdentity")) {
            try MetalFramePreparation.prepare(badFrame, width: 100, height: 100,
                                              resources: resources, pictures: resources.pictures)
        }
        #expect(resources.groups.activeBytes == 0 && resources.pictures.activeBytes == 0)
        let actual = try await pixels(frame, at: [SIMD2(30, 50), SIMD2(80, 50)])
        try expect(actual, near: [SIMD4(128, 0, 0, 128), .zero])
    }

    /// 只挂载测试窗口和库的drawable宿主；即使编码失败也关闭窗口并归还目标。
    @MainActor private func pixels(_ frame: PreparedFrame,
                                   at points: [SIMD2<Int>]) async throws -> [SIMD4<UInt8>] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 130, y: 130, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 100)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let actual = try await owner.pixels(frame, target: target, at: points)
            await target.close()
            window.close()
            return actual
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }

    /// 两层真实语义图的混合顺序与128/255蒙版项来自正式FramePlanner，不伪造PAG字节。
    private func plan() async throws -> PreparedFrame {
        let size = try PAGSize(width: 100, height: 100)
        let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: .zero, scale: .one, rotation: 0, opacity: 128))
        let red = SceneFixtures.layer(11, transform: half,
            content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0)))
        let blue = SceneFixtures.layer(12, transform: half,
            content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
        let child = try SceneFixtures.composition(1, layers: [red, blue])
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 0, y: 0), ScenePoint(x: 60, y: 0),
            ScenePoint(x: 60, y: 100), ScenePoint(x: 0, y: 100)
        ])
        let parent = SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0),
            masks: [MaskTestSupport.mask(.init(constant: path), opacity: .init(constant: 128))])
        let file = try SceneFixtures.build([child, SceneFixtures.composition(2, layers: [parent])])
        let scene = try await PreparedScene.prepare(file.composition)
        return try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
    }

    /// 将羽化和可选扩张放进正式语义场景，其他内容保持单张不透明红色以隔离蒙版alpha。
    private func blurPlan(left: Double = 0, top: Double = 0, bottom: Double = 100,
                          feather: ScenePoint = ScenePoint(x: 4, y: 0),
                          scale: Double = 1, expansion: Double = 0,
                          mode: SourceMaskMode = .add, inverted: Bool = false) async throws -> PreparedFrame {
        let size = try PAGSize(width: 100, height: 100)
        let path = try rectangularPath(left: left, top: top, right: 60, bottom: bottom)
        let mask = MaskTestSupport.mask(.init(constant: path), mode: mode, inverted: inverted,
            feather: .init(constant: feather), expansion: .init(constant: expansion))
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: .zero, scale: ScenePoint(x: scale, y: scale), rotation: 0, opacity: 255))
        let layer = SceneFixtures.layer(1, transform: transform, content: .solid(size: size,
            color: SceneColor(red: 255, green: 0, blue: 0)), masks: [mask])
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let scene = try await PreparedScene.prepare(file.composition)
        return try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
    }

    /// 构造末Close的非退化矩形，只用于源语义夹具，不伪造PAG二进制。
    private func rectangularPath(left: Double, top: Double = 0,
                                 right: Double, bottom: Double) throws -> SourcePath {
        try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: left, y: top), ScenePoint(x: right, y: top),
            ScenePoint(x: right, y: bottom), ScenePoint(x: left, y: bottom)
        ])
    }

    /// 预乘RGBA逐通道允许一次BGRA8量化误差，直接核对实际drawable像素。
    private func expect(_ actual: [SIMD4<UInt8>], near expected: [SIMD4<UInt8>]) throws {
        #expect(actual.count == expected.count)
        for (pixel, gold) in zip(actual, expected) {
            for channel in 0..<4 {
                #expect(abs(Int(pixel[channel]) - Int(gold[channel])) <= 1,
                        "实际\(pixel)，整层蒙版金值\(gold)")
            }
        }
    }
}
#endif
