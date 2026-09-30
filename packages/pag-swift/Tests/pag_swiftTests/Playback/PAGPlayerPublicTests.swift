import Testing
import pag_swift

/// 只用公开导入验证控制合同，避免@testable掩盖缺失的访问级别。
struct PAGPlayerPublicTests {
    /// 空播放器可读快照；缺少合成与缺少表面分别报告正确错误，控制不会虚报GPU完成。
    @Test func publicControlsKeepMissingResourcesExplicit() async throws {
        let player = PAGPlayer()
        #expect(await player.snapshot.state == .empty)
        await #expect(throws: PAGError.missingComposition) { try await player.play() }
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        try await player.setComposition(file.composition)
        let ready = await player.snapshot
        #expect(ready.state == .ready && ready.presentedTime == nil)
        await #expect(throws: PAGError.missingSurface) { try await player.play() }
        await #expect(throws: PAGError.missingSurface) { try await player.render(at: .zero) }
        await player.setRepeatCount(2)
        await player.setScaleMode(.aspectFill)
        try await player.seek(to: PAGProgress.end)
        #expect(await player.snapshot.position.microseconds == file.composition.duration.microseconds - 1)
        try await player.rewind()
        let rewound = await player.snapshot
        #expect(rewound.position == .zero && rewound.repeatCount == 2)
        await player.stop()
        await player.detachSurface()
        try await player.setComposition(nil)
        let empty = await player.snapshot
        #expect(empty.state == .empty && empty.repeatCount == 2)
    }

    /// 每位公开状态订阅先获得当前值，控制后保留最新快照，不把订阅当作逐帧事件日志。
    @Test func publicStreamBeginsWithCurrentSnapshot() async throws {
        let player = PAGPlayer()
        let stream = await player.snapshots()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.state == .empty)
        await player.setRepeatCount(3)
        await player.setRepeatCount(7)
        #expect(await iterator.next()?.repeatCount == 7)
    }
}
