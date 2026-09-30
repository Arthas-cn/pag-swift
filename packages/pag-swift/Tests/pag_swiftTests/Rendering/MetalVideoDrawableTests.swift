#if os(macOS)
import AppKit
import Metal
import Synchronization
import Testing
@testable import pag_swift

/// 真实视频输入在窗口drawable上执行完整片元通路；不创建离屏出图接口，也不读回播放像素。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的Metal设备"), .serialized, .timeLimit(.minutes(1)))
struct MetalVideoDrawableTests {
    /// 独立视频和完整文件直接提交；缩放表及ImageFillRule语义图可替换/恢复，撤销旧帧后能恢复。
    @MainActor @Test func submitsVideoPlanesDirectlyAndRejectsStaleFrames() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "pag-swift · Video verification"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.wantsLayer = true
        window.contentView = view
        let parent = try #require(view.layer)
        let box = DisplayTargetBox()
        let revoke = Mutex(false), counts = Mutex<[Int]>([])
        let owner = RenderOwner(device: try #require(MTLCreateSystemDefaultDevice()), observe: { event in
            if case .encoded(_, let count) = event {
                counts.withLock { $0.append(count) }
                let shouldRevoke = revoke.withLock {
                    let result = $0
                    $0 = false
                    return result
                }
                if shouldRevoke { _ = box.mailbox.beginMutation() }
            }
        })
        do {
            let geometry = try DisplayGeometry(size: PAGSize(width: 320, height: 240), scale: 1)
            let epoch = try #require(box.mailbox.beginMutation())
            _ = try await owner.prepareTarget(box, mutation: epoch)
            #expect(box.mount(to: parent, mutation: epoch))
            #expect(box.resize(to: geometry, mutation: epoch))
            #expect(box.mailbox.finishMutation(epoch, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            // 独立视频块隔离颜色/alpha布局；alpha完整文件的trackMatte依赖仍由公开入口拒绝。
            for name in ["RootLayerVideo.pag", "alpha.pag", "particle_video.pag", "MultiVideoSequence.pag"] {
                let source = try await PAGVideoFixtures.source(in: name)
                let file = try SceneFixtures.build([source])
                let scene = try await PreparedScene.prepare(file.composition)
                for frame in [0, source.durationFrames / 2, source.durationFrames - 1] {
                    let time = try SceneValidator.time(frame: frame, rate: source.frameRate)
                    let result = try await owner.submit(request(scene, time: time, epoch: epoch))
                    guard case .submitted(let actual) = result else {
                        Issue.record("视频没有完成真实drawable提交：\(name)/\(frame)")
                        continue
                    }
                    #expect(actual == (try SceneTiming.root(at: time, in: file.storage).representedTime))
                    #expect(!box.mailbox.snapshot.hasLease)
                }
            }
            // 0/0文件伸缩范围不改变原始时长播放；完整文件经过公开载入后仍可提交不同时间的帧。
            for name in ["1", "3", "5", "6", "8", "9", "11", "12", "13", "14", "17", "18", "21"] {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let source = file.storage.compositions[file.storage.rootIndex]
                let scene = try await PreparedScene.prepare(file.composition)
                for frame in [0, source.durationFrames / 2, source.durationFrames - 1] {
                    let time = try SceneValidator.time(frame: frame, rate: source.frameRate)
                    guard case .submitted(let actual) = try await owner.submit(request(scene, time: time, epoch: epoch)) else {
                        Issue.record("文件时间设置阻止实际提交：\(name)/\(frame)")
                        continue
                    }
                    #expect(actual == (try SceneTiming.root(at: time, in: file.storage).representedTime))
                }
            }
            // 文件缩放表同时影响两个可编辑图片槽；视频保持原采样，三个快照在相同中间时刻实际绘制。
            let replacement = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
            for name in ["2", "4", "7", "10", "16", "19", "20", "22"] {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let root = file.storage.compositions[file.storage.rootIndex]
                let time = try SceneValidator.time(frame: root.durationFrames / 2, rate: root.frameRate)
                var edited = file.composition
                for index in file.editableImageIndices { try edited.replaceImage(replacement, at: index) }
                var restored = edited
                for index in file.editableImageIndices { try restored.replaceImage(nil, at: index) }
                for composition in [file.composition, edited, restored] {
                    let scene = try await PreparedScene.prepare(composition)
                    guard case .submitted(let actual) = try await owner.submit(request(scene, time: time, epoch: epoch)) else {
                        Issue.record("图片缩放表文件未完成实际提交：\(name)")
                        continue
                    }
                    #expect(actual == (try SceneTiming.root(at: time, in: file.storage).representedTime))
                }
            }
            // 真实规则块进入共同drawable，但AudioMarker的音频尚未实现，不能把此语义图当整文件支持。
            for version: UInt16 in [54, 67] {
                let file = try await ImageTimeFixtures.file(rule: ImageTimeFixtures.realRule(version: version),
                    start: 22, duration: 401, offsets: [0], fileDuration: 500)
                var edited = file.composition
                try edited.replaceImage(replacement, at: 0)
                var restored = edited
                try restored.replaceImage(nil, at: 0)
                let time = try SceneValidator.time(frame: 100, rate: 30)
                for composition in [file.composition, edited, restored] {
                    let scene = try await PreparedScene.prepare(composition)
                    guard case .submitted(let actual) = try await owner.submit(request(scene, time: time, epoch: epoch)) else {
                        Issue.record("ImageFillRule语义图未完成实际提交：\(version)")
                        continue
                    }
                    #expect(actual == time)
                }
            }
            let grouped = try await PreparedScene.prepare(VideoPlanningFixtures.nested(starts: [0, -10], opacity: 128).composition)
            let time = PAGTime(microseconds: 1_000_000)
            guard case .submitted = try await owner.submit(request(grouped, time: time, epoch: epoch)) else {
                Issue.record("双视频整体透明组未提交")
                await box.shutdown()
                window.close()
                return
            }
            revoke.withLock { $0 = true }
            await #expect(throws: CancellationError.self) { try await owner.submit(request(grouped, time: time, epoch: epoch)) }
            let current = box.mailbox.snapshot.epoch
            #expect(await box.mailbox.waitUntilIdle(for: current))
            #expect(box.resize(to: geometry, mutation: current))
            #expect(box.mailbox.finishMutation(current, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            guard case .submitted = try await owner.submit(request(grouped, time: time, epoch: current)) else {
                Issue.record("撤销后的新视频请求不能恢复")
                await box.shutdown()
                window.close()
                return
            }
            #expect(counts.withLock {
                $0.count == 84 && $0.allSatisfy { $0 > 0 } &&
                    $0.prefix(12).allSatisfy { $0 == 1 } && $0.suffix(3).allSatisfy { $0 == 3 }
            })
            #expect(!box.mailbox.snapshot.hasLease)
        } catch {
            await box.shutdown()
            window.close()
            throw error
        }
        await box.shutdown()
        window.close()
    }

    /// 直接验证owner时建立有效播放许可，正常使用中由PAGPlayer维护这些身份。
    private func request(_ scene: PreparedScene, time: PAGTime, epoch: UUID) -> PlaybackFrameRequest {
        let gate = PlaybackSubmissionGate()
        let token = PlaybackRequestToken(documentID: scene.composition.storage.identity, compositionRevision: 1,
            playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
        gate.allow(token)
        return PlaybackFrameRequest(scene: scene, time: time, scaleMode: .aspectFit, token: token, gate: gate, endsPlayback: false)
    }
}
#endif
