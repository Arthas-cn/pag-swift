import Testing
@testable import pag_swift

/// 纯播放时钟与控制转换；所有输入时刻由用例给定，不依赖真实睡眠或刷新率。
struct PlaybackTimelineTests {
    /// 空合成、没有目标和暂不可用目标必须分别得到错误或 suspended，重复 play 幂等。
    @Test func playPreconditionsAndSuspension() throws {
        var timeline = PlaybackTimeline()
        #expect(throws: PAGError.missingComposition) { try timeline.play(at: 0) }
        try timeline.install(duration: PAGTime(microseconds: 100))
        #expect(throws: PAGError.missingSurface) { try timeline.play(at: 0) }
        timeline.setTarget(.unavailable, at: 0)
        #expect(try timeline.play(at: 1) == true)
        #expect(timeline.state == .suspended)
        #expect(try timeline.play(at: 2) == false)
        #expect(timeline.advance(to: 900) == false)
        timeline.setTarget(.available, at: 1_000)
        #expect(timeline.advance(to: 1_010) == true)
        #expect(timeline.position.microseconds == 10)
    }

    /// 有限结束先等待末帧；多个越界 tick 不重复计数，确认有效提交后才 finished。
    @Test func terminalSubmissionIsRequired() throws {
        var timeline = try playing(duration: 100)
        #expect(timeline.advance(to: 250) == true)
        #expect(timeline.position.microseconds == 99)
        #expect(timeline.completedIterations == 1)
        #expect(timeline.state == .playing)
        #expect(timeline.awaitsFinalFrame)
        #expect(timeline.advance(to: 900) == false)
        timeline.didSubmitFinalFrame()
        #expect(timeline.state == .finished)
        #expect(!timeline.wantsPlayback)
        #expect(try timeline.play(at: 1_000) == true)
        #expect(timeline.position == .zero)
        #expect(timeline.completedIterations == 0)
        timeline.advance(to: 1_010)
        #expect(timeline.position.microseconds == 10)
    }

    /// 正数是总次数，压力下跨过多轮仍选择正确余数和总终点。
    @Test func repeatCountIsTotalAndSkippedFramesDoNotSlowTime() throws {
        var timeline = try playing(duration: 100, repeats: 3)
        timeline.advance(to: 235)
        #expect(timeline.completedIterations == 2)
        #expect(timeline.position.microseconds == 35)
        #expect(!timeline.awaitsFinalFrame)
        timeline.advance(to: 300)
        #expect(timeline.completedIterations == 3)
        #expect(timeline.position.microseconds == 99)
        #expect(timeline.awaitsFinalFrame)
    }

    /// <=0 都是无限；单微秒与最大 UInt64 跳跃使用宽整数，不能溢出或除零。
    @Test(arguments: [0, -1, Int.min])
    func unboundedRepeatHandlesLargeElapsedTime(_ count: Int) throws {
        var timeline = try playing(duration: 1, repeats: count)
        timeline.advance(to: UInt64.max)
        #expect(timeline.completedIterations == UInt64.max)
        #expect(timeline.position == .zero)
        #expect(timeline.state == .playing)
        #expect(!timeline.awaitsFinalFrame)
    }

    /// Int64 最大时长与 UInt64 经过时间相加时不能溢出，seek 也不能消耗循环次数。
    @Test func longDurationAndSeekUseExactIntegerArithmetic() throws {
        var timeline = try playing(duration: .max, repeats: 0)
        try timeline.seek(to: PAGTime(microseconds: .max), at: 0)
        #expect(timeline.position.microseconds == Int64.max - 1)
        timeline.advance(to: UInt64.max)
        #expect(timeline.completedIterations == 3)
        #expect(timeline.position == .zero)
    }

    /// pause 在命令时刻采样并冻结，恢复窗口不会覆盖用户暂停，play 才重新起计。
    @Test func pauseAndVisibilityKeepUserIntent() throws {
        var timeline = try playing(duration: 100, repeats: 0)
        timeline.pause(at: 30)
        #expect(timeline.position.microseconds == 30)
        #expect(timeline.state == .paused)
        timeline.setTarget(.unavailable, at: 50)
        timeline.setTarget(.available, at: 900)
        #expect(timeline.state == .paused)
        #expect(timeline.advance(to: 1_000) == false)
        try timeline.play(at: 1_000)
        timeline.advance(to: 1_020)
        #expect(timeline.position.microseconds == 50)
        #expect(timeline.completedIterations == 0)
    }

    /// 隐藏前的可见时间计入，隐藏后的长间隔不计入循环次数。
    @Test func hideAndResumeFreezeClock() throws {
        var timeline = try playing(duration: 100, repeats: 0)
        timeline.setTarget(.unavailable, at: 35)
        #expect(timeline.position.microseconds == 35)
        #expect(timeline.state == .suspended)
        timeline.setTarget(.available, at: 10_000)
        timeline.advance(to: 10_010)
        #expect(timeline.position.microseconds == 45)
        #expect(timeline.completedIterations == 0)
    }

    /// 末帧等待中隐藏只能 suspended；恢复仍提交原终点，不能重算成下一轮。
    @Test func hiddenTerminalWaitsForValidSubmission() throws {
        var timeline = try playing(duration: 100)
        timeline.advance(to: 100)
        timeline.setTarget(.unavailable, at: 110)
        #expect(timeline.state == .suspended)
        #expect(timeline.awaitsFinalFrame)
        timeline.setTarget(.available, at: 1_000)
        #expect(timeline.advance(to: 1_001) == false)
        timeline.didSubmitFinalFrame()
        #expect(timeline.state == .finished)
        #expect(timeline.position.microseconds == 99)
    }

    /// 主动暂停撤销结束意图；迟到的末帧确认不能把 paused 改成 finished。
    @Test func pauseRevokesPendingFinish() throws {
        var timeline = try playing(duration: 100)
        timeline.advance(to: 100)
        timeline.pause(at: 100)
        timeline.didSubmitFinalFrame()
        #expect(timeline.state == .paused)
        #expect(timeline.completedIterations == 1)
        #expect(timeline.position.microseconds == 99)
    }

    /// seek 不计轮数、钳制端点，seek 末端只在下一次正向时间推进时结束。
    @Test func seekClampsWithoutConsumingIterations() throws {
        var timeline = try playing(duration: 100)
        try timeline.seek(to: PAGTime(microseconds: .min), at: 1_000)
        #expect(timeline.position == .zero)
        try timeline.seek(to: PAGTime(microseconds: .max), at: 2_000)
        #expect(timeline.position.microseconds == 99)
        #expect(timeline.completedIterations == 0)
        #expect(timeline.advance(to: 2_000) == false)
        #expect(!timeline.awaitsFinalFrame)
        timeline.advance(to: 2_001)
        #expect(timeline.awaitsFinalFrame)
        timeline.didSubmitFinalFrame()
        try timeline.seek(to: PAGTime(microseconds: 20), at: 3_000)
        #expect(timeline.state == .paused)
        try timeline.play(at: 3_000)
        #expect(timeline.position.microseconds == 20)
        #expect(timeline.completedIterations == 1)
        timeline.advance(to: 3_010)
        #expect(timeline.position.microseconds == 30)
        #expect(!timeline.awaitsFinalFrame)
    }

    /// 重复或倒序 tick 不倒移锚点，恢复正常时间戳后只计算尚未计入的差额。
    @Test func staleTicksCannotMoveTheAnchor() throws {
        var timeline = try playing(duration: 100, repeats: 0)
        timeline.advance(to: 30)
        #expect(timeline.advance(to: 30) == false)
        #expect(timeline.advance(to: 20) == false)
        timeline.advance(to: 40)
        #expect(timeline.position.microseconds == 40)
    }

    /// 减少总次数要求新的末帧确认；收尾未完成时增加次数或改无限可继续推进。
    @Test func repeatChangesReplacePendingTerminalIntent() throws {
        var timeline = try playing(duration: 100, repeats: 0)
        timeline.advance(to: 235)
        timeline.setRepeatCount(1, at: 235)
        #expect(timeline.completedIterations == 2)
        #expect(timeline.position.microseconds == 99)
        #expect(timeline.awaitsFinalFrame)
        timeline.setRepeatCount(4, at: 235)
        #expect(!timeline.awaitsFinalFrame)
        timeline.advance(to: 236)
        #expect(timeline.completedIterations == 3)
        #expect(timeline.position == .zero)
        timeline.advance(to: 336)
        #expect(timeline.awaitsFinalFrame)
        timeline.setRepeatCount(0, at: 336)
        timeline.advance(to: 337)
        #expect(timeline.completedIterations == 4)
        #expect(timeline.state == .playing)
    }

    /// rewind 与换文档重置次数；换文档保留目标和重复配置，非法安装保持原状态。
    @Test func rewindAndInstallResetOnlyDocumentState() throws {
        var timeline = try playing(duration: 100, repeats: 0)
        timeline.advance(to: 220)
        try timeline.rewind()
        #expect(timeline.position == .zero)
        #expect(timeline.completedIterations == 0)
        #expect(timeline.state == .paused)
        #expect(throws: PAGError.invalidArgument("duration")) {
            try timeline.install(duration: .zero)
        }
        #expect(timeline.duration?.microseconds == 100)
        try timeline.install(duration: nil)
        #expect(timeline.state == .empty)
        #expect(timeline.target == .available)
        #expect(timeline.repeatCount == 0)
        try timeline.install(duration: PAGTime(microseconds: 20))
        #expect(timeline.state == .ready)
    }

    /// 主错误保留位置，普通控制不能暗中恢复；成功替换清除错误并保持暂停。
    @Test func failureRequiresSuccessfulSceneInstallation() throws {
        var timeline = try playing(duration: 100)
        timeline.advance(to: 80)
        let error = PAGError.renderingFailure("test")
        timeline.fail(error)
        #expect(timeline.state == .failed)
        #expect(timeline.position.microseconds == 80)
        #expect(throws: error) { try timeline.play(at: 90) }
        #expect(throws: error) { try timeline.seek(to: .zero, at: 90) }
        #expect(throws: error) { try timeline.rewind() }
        timeline.pause(at: 100)
        #expect(timeline.state == .failed)
        try timeline.replace(duration: PAGTime(microseconds: 50), at: 200)
        #expect(timeline.failure == nil)
        #expect(timeline.state == .paused)
        #expect(timeline.position.microseconds == 49)
    }

    /// 建立真实时间状态机的可用目标，不注入任何 GPU 成功结果。
    private func playing(duration: Int64, repeats: Int = 1) throws -> PlaybackTimeline {
        var timeline = PlaybackTimeline()
        try timeline.install(duration: PAGTime(microseconds: duration))
        timeline.setRepeatCount(repeats, at: 0)
        timeline.setTarget(.available, at: 0)
        try timeline.play(at: 0)
        return timeline
    }
}
