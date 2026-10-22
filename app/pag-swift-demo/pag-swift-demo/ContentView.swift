import SwiftUI
import pag_swift

/// 展示库的SwiftUI与原生宿主；界面仅发控制命令，不承担解码、计时或绘制。
struct ContentView: View {
    /// 此窗口独占的演示会话，body重算时保留两个播放器身份。
    @State private var session = DemoSession()
    /// 相对resources的路径；验收可用启动参数选样例，切换由task负责取消旧载入。
    @State private var sample = CommandLine.arguments.first { $0.hasPrefix("--pag-sample=") }
        .map { String($0.dropFirst("--pag-sample=".count)) } ?? "srgb.pag"
    /// 现有Demo的媒体替换选择；旧静图启动参数仍映射到PNG。
    @State private var media = DemoMediaChoice(rawValue: CommandLine.arguments.first { $0.hasPrefix("--pag-media=") }
        .map { String($0.dropFirst("--pag-media=".count)) } ?? "") ??
        (CommandLine.arguments.contains("--pag-replace-images") ? .png : .original)
    /// 只替换当前选择的一个图片槽；稳定验收样例默认选 scene.png。
    @State private var imageSlot = 0
    /// 本次动态文字的实际策略，启动参数兼容原有跑马灯验收。
    @State private var textLayout: DemoTextLayout = CommandLine.arguments.contains("--pag-marquee") ? .marquee : .original
    /// 输入框草稿不会在每次敲键时中断播放器。
    @State private var textDraft = String(repeating: "PAG Swift ", count: 12)
    /// 用户点击应用后才交给宿主 tag 回调的文字。
    @State private var appliedText = String(repeating: "PAG Swift ", count: 12)
    /// 归一化定位值，结束拖动时向库发seek。
    @State private var progress = 0.0
    /// 共享缩放选项，实际换算由库完成。
    @State private var scaleMode = PAGScaleMode.aspectFit
    /// 移除并重建宿主，验证播放器状态独立于View生命周期。
    @State private var isMounted = true
    /// 只隐藏原生宿主的祖先，验证平台事件而非业务pause。
    @State private var isNativeHidden = false
    /// 切换真实布局尺寸，验证surface继续呈现。
    @State private var isCompact = false
    /// 自动验收临时使用的真实高度；nil继续使用手动尺寸开关。
    @State private var verificationHeight: Double?
    /// 每次窗口生命周期只执行一次显式请求的自动验收。
    @State private var didStartVerification = false
    /// 自动验收结束后的结果；nil表示未运行或仍在执行。
    @State private var verificationResult: String?

    /// 演示控制与显示结果；状态文字来自库快照。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PAG Swift 播放验证").font(.title2.bold())
                Picker("样例", selection: $sample) {
                    Text("色彩与动画").tag("srgb.pag")
                    Text("红色实底").tag("red.pag")
                    Text("图层蒙版 AudioMarker").tag("AudioMarker.pag")
                    Text("描边路径 0").tag("0.pag")
                    Text("描边场景 list/0").tag("list/0.pag")
                    Text("描边场景 list/12").tag("list/12.pag")
                    Text("描边场景 list/13").tag("list/13.pag")
                    Text("描边场景 list/15").tag("list/15.pag")
                    Text("描边场景 list/19").tag("list/19.pag")
                    Text("形状动画 list/14").tag("list/14.pag")
                    Text("形状动画 list/16").tag("list/16.pag")
                    Text("形状动画 list/18").tag("list/18.pag")
                    Text("形状动画 list/9").tag("list/9.pag")
                    Text("星形与文字").tag("TextDirection.pag")
                    Text("线性渐变 2 色").tag("gradient/grad_2.pag")
                    Text("径向渐变 2 色").tag("gradient/grad_2_radial.pag")
                    Text("线性渐变 5 色").tag("gradient/grad_5.pag")
                    Text("径向渐变 5 色").tag("gradient/grad_5_radial.pag")
                    Text("线性渐变 9 色").tag("gradient/grad_9.pag")
                    Text("径向渐变 9 色").tag("gradient/grad_9_radial.pag")
                    Text("路径裁剪 fans").tag("fans.pag")
                    Text("路径裁剪 refreshing").tag("refreshing.pag")
                    Text("路径裁剪 test").tag("test.pag")
                    Text("路径裁剪圆环").tag("wstask_circle.pag")
                    Text("文本").tag("editing/TEXT04.pag")
                    Text("动态素材验收（稳定槽）").tag("editing/replace.pag")
                    Text("图片三槽分段").tag("editing/ImageDecodeTest.pag")
                    Text("位图序列").tag("RootLayerBitmap.pag")
                    Text("位图冻结帧").tag("RootLayerBitmapFreeze.pag")
                    Text("位图时间偏移").tag("RootLayerBitmapOffset.pag")
                    Text("位图多分辨率").tag("small.pag")
                    Text("内嵌视频").tag("RootLayerVideo.pag")
                    Text("视频冻结帧").tag("RootLayerVideoFreeze.pag")
                    Text("视频时间偏移").tag("RootLayerVideoOffset.pag")
                    Text("多视频合成").tag("MultiVideoSequence.pag")
                    Text("视频多分辨率").tag("data_video.pag")
                    Text("透明粒子视频").tag("particle_video.pag")
                    Text("图片与视频合成").tag("2")
                    Text("含音频元数据 TZ2").tag("TZ2.pag")
                    Text("合并路径 list/3").tag("list/3.pag")
                    Text("轨道遮罩 list/7").tag("list/7.pag")
                    Text("渐变叠加 LOGO").tag("PAG_LOGO.pag")
                    Text("图层混合 tougao").tag("tougao.pag")
                    Text("复杂蒙版 travel").tag("travel.pag")
                    Text("组合效果 clip1").tag("nodegroup_clip1.pag")
                    Text("动态模糊 2J").tag("2J.pag")
                    Text("动态模糊 MT2").tag("MT2.pag")
                }
                if sample == "editing/replace.pag" || sample == "editing/ImageDecodeTest.pag" {
                    Picker("图片槽素材", selection: $media) {
                        ForEach(DemoMediaChoice.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                }
                if sample == "editing/ImageDecodeTest.pag" {
                    Picker("替换图片槽", selection: $imageSlot) {
                        Text("标志 512-logo.png · 索引 0").tag(0)
                        Text("场景 scene.png · 索引 1").tag(1)
                        Text("前景 test.png · 索引 2").tag(2)
                    }
                }
                if sample == "editing/replace.pag" {
                    Picker("替换图片槽", selection: $imageSlot) {
                        Text("场景 scene.png · 索引 0").tag(0)
                        Text("照片 rotation.jpg · 索引 1").tag(1)
                    }
                }
                if sample == "editing/TEXT04.pag" {
                    Picker("动态文字", selection: $textLayout) {
                        ForEach(DemoTextLayout.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    HStack {
                        TextField("按图层名替换的文字", text: $textDraft)
                        Button("应用文字") { appliedText = textDraft }
                    }
                }
                HStack {
                    Button("播放") { session.perform(.play) }
                    Button("暂停") { session.perform(.pause) }
                    Button("回到开头") { session.perform(.rewind) }
                }
                .buttonStyle(.bordered)
                .disabled(session.isLoading || !session.isLoaded)
                HStack {
                    Text("定位")
                    Slider(value: $progress, in: 0...1) { editing in
                        if !editing { session.perform(.seek(progress)) }
                    }
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 48)
                }
                .disabled(session.isLoading || !session.isLoaded)
                Picker("缩放", selection: $scaleMode) {
                    Text("完整显示").tag(PAGScaleMode.aspectFit)
                    Text("填满裁切").tag(PAGScaleMode.aspectFill)
                    Text("拉伸").tag(PAGScaleMode.stretch)
                    Text("原始大小").tag(PAGScaleMode.none)
                }
                Toggle("挂载显示宿主", isOn: $isMounted)
                Toggle("隐藏原生宿主的祖先", isOn: $isNativeHidden)
                Toggle("缩小显示区域", isOn: $isCompact)
                if let verificationResult { Text(verificationResult).font(.caption).textSelection(.enabled) }
                if let error = session.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if isMounted {
                    hostPanel(title: "SwiftUI", status: session.swiftUIStatus) {
                        PAGView(player: session.swiftUIPlayer)
                    }
                    hostPanel(title: NativeDemoView.platformName, status: session.nativeStatus) {
                        NativeDemoView(player: session.nativePlayer, isContentHidden: isNativeHidden)
                    }
                } else {
                    Text("显示宿主已移除；重新挂载后保留位置与暂停意图。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 300)
        .task { await session.observe() }
        .task(id: DemoSelection(path: sample, media: media, imageSlot: imageSlot,
                                textLayout: textLayout, text: appliedText)) {
            // 新快照从首帧安装，不能让手动定位条沿用上一个素材的数值。
            progress = 0
            await session.load(sample, media: media, imageSlot: imageSlot,
                               dynamicText: appliedText, textLayout: textLayout)
        }
        .task(id: session.isLoaded) {
            guard session.isLoaded, DemoHostVerification.isRequested, !didStartVerification else { return }
            didStartVerification = true
            verificationResult = await DemoHostVerification(
                swiftUIPlayer: session.swiftUIPlayer, nativePlayer: session.nativePlayer,
                setMounted: { isMounted = $0 }, setNativeHidden: { isNativeHidden = $0 },
                setHeight: { verificationHeight = $0 },
                // clip1旧故障在4秒后才出现，验收终帧必须越过该效果层起点。
                finalFrameTime: PAGTime(microseconds: sample == "nodegroup_clip1.pag" ? 4_250_000 : 2_000_000)
            ).run()
            // 验收结束后恢复手动布局开关，不能让临时零尺寸/固定高度继续覆盖用户操作。
            isCompact = true
            verificationHeight = nil
        }
        .onChange(of: scaleMode) { _, mode in session.perform(.scale(mode)) }
    }

    /// 相同背景和尺寸便于比较两个宿主在相同播放位置的画面。
    private func hostPanel<Content: View>(title: String, status: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).bold(); Spacer(); Text(status).font(.caption).monospacedDigit() }
            content()
                .frame(maxWidth: .infinity)
                .frame(height: verificationHeight ?? (isCompact ? 100 : 220))
                .background(.gray.opacity(0.15))
        }
    }
}

/// 载入任务的完整身份；选文件或切换素材都取消旧任务并请求安装新快照。
private struct DemoSelection: Hashable {
    /// 相对仓库resources的真实样例路径。
    let path: String
    /// 由库加载并替换的可选素材，original恢复原文件输入。
    let media: DemoMediaChoice
    /// 本轮只替换的可编辑图片索引。
    let imageSlot: Int
    /// 可编辑文字的自动字号、截断或滚动选择。
    let textLayout: DemoTextLayout
    /// 点击应用后锁定的内容，不随输入框每次敲键变化。
    let text: String
}
