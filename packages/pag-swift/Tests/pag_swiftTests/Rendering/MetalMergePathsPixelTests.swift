#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 用正式帧计划和已挂载drawable核对MergePaths的Append及面积Boolean画面；测试读取仅作诊断。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalMergePathsPixelTests {
    /// 两个源矩形及子组路径合成后由蓝Fill一次消费；合并前红Fill必须从画面消失。
    @MainActor @Test func appendRendersOnePathAndClearsPriorPaint() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let left = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 20, y: 20),
                                          position: ScenePoint(x: 20, y: 50), roundness: 0)
        let right = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 20, y: 20),
                                           position: ScenePoint(x: 70, y: 50), roundness: 0)
        let shapes: [SourceShape] = [
            left, .fill(color: .defaultFill, opacity: 255),
            .group(ShapePropertyFixtures.group(), [right]), .mergePaths(.merge),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)
        ]
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(shapes))])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        let pixels = try await pixels(frame, at: [SIMD2(20, 50), SIMD2(45, 50), SIMD2(70, 50)])
        #expect(pixels == [SIMD4(0, 0, 255, 255), .zero, SIMD4(0, 0, 255, 255)])
    }

    /// 两个相交矩形的左独占、重叠和右独占区域，逐模式核对Boolean实际覆盖。
    @MainActor @Test(arguments: [SourceMergePathsMode.add, .subtract, .intersect, .excludeIntersections])
    func booleanModesRenderExpectedRegions(_ mode: SourceMergePathsMode) async throws {
        let size = try PAGSize(width: 100, height: 100)
        let first = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                           position: ScenePoint(x: 30, y: 40), roundness: 0)
        let second = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                            position: ScenePoint(x: 50, y: 40), roundness: 0)
        let shapes: [SourceShape] = [first, .fill(color: .defaultFill, opacity: 255), second,
                                     .mergePaths(mode),
                                     .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)]
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(shapes))])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        let pixels = try await pixels(frame, at: [SIMD2(20, 40), SIMD2(40, 40), SIMD2(60, 40), SIMD2(90, 40)])
        let blue = SIMD4<UInt8>(0, 0, 255, 255)
        let expected: [SIMD4<UInt8>] = switch mode {
        case .add: [blue, blue, blue, .zero]
        case .subtract: [blue, .zero, .zero, .zero]
        case .intersect: [.zero, blue, .zero, .zero]
        case .excludeIntersections: [blue, .zero, blue, .zero]
        case .merge: throw PAGError.invalidArgument("mergePathsPixelMode")
        }
        #expect(pixels == expected)
    }

    /// PathOps填充布尔对开放轮廓隐式闭合；三角形与矩形交集的内外点必须保持一致。
    @MainActor @Test func openTriangleBooleanClosesForFill() async throws {
        let path = try SourcePath(verbs: [.move, .line, .line], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 60, y: 10), ScenePoint(x: 10, y: 60)
        ])
        let rectangle = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 30, y: 30),
                                               position: ScenePoint(x: 30, y: 30), roundness: 0)
        let shapes: [SourceShape] = [
            .path(.init(constant: path)), rectangle, .mergePaths(.intersect),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)
        ]
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(shapes))])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
        let actual = try await pixels(frame, at: [SIMD2(20, 20), SIMD2(30, 30),
                                                  SIMD2(40, 40), SIMD2(10, 10)])
        #expect(actual == [SIMD4(0, 0, 255, 255), SIMD4(0, 0, 255, 255), .zero, .zero])
    }

    /// Intersect输出必须保留边界给后续Stroke，不能只生成能填充的面积三角网格。
    @MainActor @Test func intersectedPathKeepsStrokeBoundary() async throws {
        let first = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                           position: ScenePoint(x: 30, y: 40), roundness: 0)
        let second = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                            position: ScenePoint(x: 50, y: 40), roundness: 0)
        let green = SceneColor(red: 0, green: 255, blue: 0)
        let shapes: [SourceShape] = [first, second, .mergePaths(.intersect),
            .stroke(StrokeFixtures.make(width: .init(constant: 4), color: .init(constant: green),
                                        order: .abovePrevious))]
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(shapes))])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
        let actual = try await pixels(frame, at: [SIMD2(30, 40), SIMD2(40, 40),
                                                  SIMD2(50, 40), SIMD2(20, 40)])
        #expect(actual == [SIMD4(0, 255, 0, 255), .zero, SIMD4(0, 255, 0, 255), .zero])
    }

    /// 相减后的内孔必须保持真正的空白，不能把两条边界错误地按同向nonzero填满。
    @MainActor @Test func subtractionKeepsHoleInDrawable() async throws {
        let outer = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 60, y: 60),
                                           position: ScenePoint(x: 50, y: 50), roundness: 0)
        let inner = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 20, y: 20),
                                           position: ScenePoint(x: 50, y: 50), roundness: 0)
        let shapes: [SourceShape] = [outer, inner, .mergePaths(.subtract),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)]
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(shapes))])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
        let actual = try await pixels(frame, at: [SIMD2(25, 50), SIMD2(50, 50),
                                                  SIMD2(75, 50), SIMD2(10, 50)])
        #expect(actual == [SIMD4(0, 0, 255, 255), .zero, SIMD4(0, 0, 255, 255), .zero])
    }

    /// 三次曲线与矩形交集既保留拱形边界，也让内部面积进入最终drawable。
    @MainActor @Test func cubicIntersectionKeepsCurvedRegion() async throws {
        let arch = try SourcePath(verbs: [.move, .cubic, .line, .close], points: [
            ScenePoint(x: 10, y: 80), ScenePoint(x: 10, y: 10), ScenePoint(x: 90, y: 10),
            ScenePoint(x: 90, y: 80), ScenePoint(x: 10, y: 80)
        ])
        let window = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 60, y: 60),
                                            position: ScenePoint(x: 50, y: 50), roundness: 0)
        let shapes: [SourceShape] = [.path(.init(constant: arch)), window, .mergePaths(.intersect),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)]
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .shape(shapes))])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .none)
        // 拱顶在x=50附近约y=27.5；离边界数像素处取点，避免把AA边缘当成几何差异。
        let actual = try await pixels(frame, at: [SIMD2(50, 20), SIMD2(50, 50),
                                                  SIMD2(50, 75), SIMD2(10, 50)])
        #expect(actual == [.zero, SIMD4(0, 0, 255, 255), SIMD4(0, 0, 255, 255), .zero])
    }

    /// 测试诊断直接从窗口drawable抽取三个点；所有层生命周期仍走生产mailbox与批次。
    @MainActor private func pixels(_ frame: PreparedFrame, at points: [SIMD2<Int>]) async throws -> [SIMD4<UInt8>] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · MergePaths pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget()
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
            let result = try await owner.pixels(frame, target: target, at: points)
            await target.close()
            window.close()
            return result
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }
}
#endif
