/// 外部视频媒体owner的窄交接边界；场景求值只请求PAG局部时间，不接触AVPlayer对象。
protocol ExternalVideoSampling: Sendable {
    /// 返回真实NV12输入；暂未给出目标帧时报mediaFailure供占位选择。
    func frame(for source: ExternalVideoStorage, at time: PAGTime,
               isPlaying: Bool) async throws -> VideoFrameTransfer
    /// 暂停独立系统预取而保留最近有效输入，PAG播放意图仍由主控制器持有。
    func pause() async
}
