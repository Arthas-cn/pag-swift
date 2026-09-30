#if os(macOS)
import AppKit
import Metal
import Synchronization
import Testing
@testable import pag_swift

/// 在真实macOS显示树中直接提交drawable；这不是截图测试或三宿主画面一致性验收。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .serialized, .timeLimit(.minutes(1)))
struct MetalDrawableIntegrationTests {
    /// 完整文件及路径语义图完成GPU提交，撤销阻止commit，resize后继续；真实字段片段不冒充整文件支持。
    @MainActor @Test func submitsRealDrawablesAndRejectsRevokedEncodedFrame() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Metal verification"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.wantsLayer = true
        window.contentView = view
        let parent = try #require(view.layer)
        let box = DisplayTargetBox()
        let revokeAfterEncoding = Mutex(false)
        let counts = Mutex<[Int]>([])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = RenderOwner(device: device, observe: { event in
            if case .encoded(_, let count) = event {
                counts.withLock { $0.append(count) }
                let revoke = revokeAfterEncoding.withLock { flag in
                    let old = flag
                    flag = false
                    return old
                }
                // 故障注入只撤销值代数，不从后台修改NSView/CALayer。
                if revoke { _ = box.mailbox.beginMutation() }
            }
        })
        do {
            var geometry = try DisplayGeometry(size: PAGSize(width: 320, height: 240), scale: 1)
            let mutation = try #require(box.mailbox.beginMutation())
            let info = try await owner.prepareTarget(box, mutation: mutation)
            #expect(!info.isMainThread)
            #expect(box.mount(to: parent, mutation: mutation))
            #expect(box.resize(to: geometry, mutation: mutation))
            #expect(box.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            // 所有输入来自真实完整PAG；视频与bitmap仍走同一drawable通路，没有截图或输出读回。
            for name in ["red.pag", "editing/TEXT04.pag", "editing/ImageDecodeTest.pag", "RootLayerBitmap.pag",
                         "RootLayerBitmapFreeze.pag", "RootLayerBitmapOffset.pag", "small.pag",
                         "RootLayerVideo.pag", "RootLayerVideoFreeze.pag", "RootLayerVideoOffset.pag",
                         "MultiVideoSequence.pag", "MultiVideoSequenceOffset.pag", "data_video.pag",
                         "particle_video.pag", "jisha.pag"] {
                let scene = try await PreparedScene.prepare(PAGLoader().load(data: PAGFixtures.data(named: name)).composition)
                let request = makeRequest(scene, epoch: mutation)
                let result = try await owner.submit(request)
                guard case .submitted(let time) = result else {
                    Issue.record("真实窗口没有可提交的drawable：\(name)")
                    continue
                }
                #expect(time == .zero && !box.mailbox.snapshot.hasLease)
            }
            // 真实tag19字段与纯语义形变都进入共同drawable；这不表示0.pag的其他标签已支持。
            let paths: [(SourceProperty<SourcePath>, ScenePoint)] = [
                (try ShapePathFixtures.track(), .zero),
                (try PathFixtures.property(named: "0.pag", range: 164..<202), ScenePoint(x: 50, y: 50)),
                (try PathFixtures.property(named: "0.pag", range: 631..<744), ScenePoint(x: -60, y: -100))
            ]
            for (path, position) in paths {
                let file = try ShapePathFixtures.file(path, offsets: [0], position: position)
                let scene = try await PreparedScene.prepare(file.composition)
                for frame: Int64 in [0, 10, 20] {
                    let time = try SceneValidator.time(frame: frame, rate: 30)
                    guard case .submitted(let rendered) = try await owner.submit(makeRequest(scene, epoch: mutation, time: time)) else {
                        Issue.record("路径语义图未完成实际GPU提交：\(frame)")
                        continue
                    }
                    #expect(rendered == time && !box.mailbox.snapshot.hasLease)
                }
            }
            let scene = try await PreparedScene.prepare(MetalGroupFixtures.composition())
            guard case .submitted = try await owner.submit(makeRequest(scene, epoch: mutation)) else {
                Issue.record("整体透明组没有完成真实GPU提交")
                await box.shutdown()
                window.close()
                return
            }
            let rejected = makeRequest(scene, epoch: mutation)
            revokeAfterEncoding.withLock { $0 = true }
            await #expect(throws: CancellationError.self) { try await owner.submit(rejected) }
            #expect(!box.mailbox.snapshot.hasLease && box.mailbox.snapshot.isBlocked)
            let resize = box.mailbox.snapshot.epoch
            #expect(await box.mailbox.waitUntilIdle(for: resize))
            geometry = try DisplayGeometry(size: geometry.size, scale: 2)
            #expect(box.resize(to: geometry, mutation: resize))
            #expect(box.mailbox.finishMutation(resize, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            let current = makeRequest(scene, epoch: resize)
            guard case .submitted = try await owner.submit(current) else {
                Issue.record("resize后的新代数未完成GPU提交")
                await box.shutdown()
                window.close()
                return
            }
            let stale = makeRequest(scene, epoch: mutation)
            await #expect(throws: CancellationError.self) { try await owner.submit(stale) }
            #expect(!box.mailbox.snapshot.hasLease)
            #expect(counts.withLock { $0.count == 27 && $0.allSatisfy { $0 > 0 } && $0.suffix(3).allSatisfy { $0 == 5 } })
            let inactive = try #require(box.mailbox.beginMutation())
            #expect(box.mailbox.finishMutation(inactive, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: false)))
            guard case .targetUnavailable = try await owner.submit(makeRequest(scene, epoch: inactive)) else {
                Issue.record("inactive目标不应取drawable")
                await box.shutdown()
                window.close()
                return
            }
        } catch {
            await box.shutdown()
            window.close()
            throw error
        }
        await box.shutdown()
        #expect(parent.sublayers?.isEmpty != false)
        window.close()
    }

    /// 直接测试owner时显式建立与mailbox一致的token和许可，正常播放器由controller完成此职责。
    private func makeRequest(_ scene: PreparedScene, epoch: UUID, time: PAGTime = .zero) -> PlaybackFrameRequest {
        let gate = PlaybackSubmissionGate()
        let token = PlaybackRequestToken(documentID: scene.composition.storage.identity, compositionRevision: 1,
                                         playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
        gate.allow(token)
        return PlaybackFrameRequest(scene: scene, time: time, scaleMode: .aspectFit, token: token, gate: gate, endsPlayback: false)
    }
}
#endif
