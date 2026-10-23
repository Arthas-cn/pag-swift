import SwiftUI
import pag_swift

/// 单资源业务详情；只挂载一个库宿主，槽位操作使用真实 tag。
struct DemoDetailView: View {
    /// 导航选中的资源候选，解析失败也保留详情和报告入口。
    let resource: DemoResource
    /// 页面生命周期独占的播放器及有限日志。
    @State private var session = DemoSession()
    /// 仅切换显示适配边界，不同时绘制两个播放器。
    @State private var nativeHost = false
    /// 用户拖动草稿，松手才 seek，避免每像素重建帧请求。
    @State private var seekProgress = 0.0
    /// 拖动期间不让节流状态快照覆盖用户手势。
    @State private var isSeeking = false
    /// 总次数小于等于零为无限，支持观察一次结束与有限重播边界。
    @State private var repeatCount = 0
    /// 最终显示映射交给库计算。
    @State private var scale = PAGScaleMode.aspectFit

    /// 画面、播放控制、真实槽位和诊断各占独立卡片。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(resource.id).font(.headline); Spacer(); Text(session.status).font(.caption) }
                    Text(session.metadata).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    ZStack {
                        Color.gray.opacity(0.12)
                        if nativeHost { NativeDemoView(player: session.player, isContentHidden: false) }
                        else { PAGView(player: session.player) }
                    }
                    .frame(height: 300).clipShape(.rect(cornerRadius: 14))
                    .accessibilityIdentifier("detail.canvas")
                    Toggle("使用 \(NativeDemoView.platformName) 宿主", isOn: $nativeHost)
                        .font(.caption)
                }
                playbackControls
                DemoPlaybackDebugControls(session: session)
                if let error = session.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Text("内容槽位 · \(session.slots.count)").font(.title3.bold())
                    Spacer()
                    Button("多槽示例") { session.applyMultipleSlots() }
                    Button("全部恢复") { session.restore() }
                }
                .disabled(!session.isLoaded)
                if session.isLoaded, session.slots.isEmpty {
                    Text("此文件没有可替换源槽，正常播放原内容。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(session.slots) { slot in DemoSlotEditor(slot: slot, session: session) }
                DemoDiagnosticsView(session: session)
                NavigationLink("SwiftUI / \(NativeDemoView.platformName) 宿主对照验收", value: DemoRoute.hosts(resource))
                    .font(.caption)
            }
            .padding()
        }
        .navigationTitle(resource.name)
        .task { await session.run(resource) }
        .onChange(of: session.progress) { _, value in if !isSeeking { seekProgress = value } }
        .onChange(of: repeatCount) { _, value in
            session.perform("repeat", detail: value <= 0 ? "无限" : "\(value) 轮") { await $0.setRepeatCount(value) }
        }
        .onChange(of: scale) { _, value in session.perform("scale", detail: String(describing: value)) { await $0.setScaleMode(value) } }
        .onChange(of: nativeHost) { _, value in session.append("host", detail: value ? NativeDemoView.platformName : "SwiftUI") }
    }

    /// 只发公开控制命令，UI 滑杆不充当播放时钟。
    private var playbackControls: some View {
        VStack(spacing: 12) {
            HStack {
                Button("播放", systemImage: "play.fill") { session.perform("play") { try await $0.play() } }
                Button("暂停", systemImage: "pause.fill") { session.perform("pause") { await $0.pause() } }
                Button("重新播放", systemImage: "backward.end.fill") {
                    session.perform("rewindAndPlay") { try await $0.rewind(); try await $0.play() }
                }
                Spacer()
                Picker("总轮数", selection: $repeatCount) {
                    Text("1 轮").tag(1)
                    Text("2 轮").tag(2)
                    Text("无限").tag(0)
                }
                .fixedSize()
            }
            .buttonStyle(.bordered)
            HStack {
                Slider(value: $seekProgress, in: 0...1) { editing in
                    isSeeking = editing
                    if !editing {
                        let position = seekProgress
                        session.perform("seek", detail: String(position)) { try await $0.seek(to: PAGProgress(position)) }
                    }
                }
                Text(seekProgress, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 44)
            }
            Picker("缩放", selection: $scale) {
                Text("完整显示").tag(PAGScaleMode.aspectFit)
                Text("填满裁切").tag(PAGScaleMode.aspectFill)
                Text("拉伸").tag(PAGScaleMode.stretch)
                Text("原始大小").tag(PAGScaleMode.none)
            }
        }
        .disabled(!session.isLoaded)
    }
}

/// 一个真实源槽的编辑卡片；草稿属于当前 tag，应用后才产生新内容版本。
private struct DemoSlotEditor: View {
    /// 库返回的稳定源槽，尺寸是源层局部坐标而非屏幕大小。
    let slot: PAGContentSlot
    /// 操作仍交给当前详情的唯一播放器。
    let session: DemoSession
    /// 默认长文字用于观察溢出，可改短文字验证静止。
    @State private var text = String(repeating: "PAG Swift 动态文字 ", count: 8)
    /// 自动字号、截断和跑马灯是互斥布局选择。
    @State private var layout = DemoTextLayout.marquee
    /// 明确选择动图播放或只取首帧；更改后点击对应素材按钮应用到当前 tag。
    @State private var imagePlayback = PAGImagePlaybackMode.animated
    /// 头像素材的缩放策略；遮罩有自己的布局，不跟随素材宽高比变化。
    @State private var imageScale = DemoImageScaleChoice.file
    /// 当前遮罩草稿，应用素材后才提交给库。
    @State private var imageMask = DemoImageMaskChoice.none
    /// 原始遮罩源 tag；空值由目录选择 xin7.png 或首个可用图像槽。
    @State private var maskSource = ""

    /// 展示源身份与尺寸，并提供隐藏、恢复和类型匹配的业务操作。
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(slot.tag, systemImage: slot.kind == .text ? "textformat" : "photo")
                    .font(.headline).textSelection(.enabled)
                Spacer()
                Button("隐藏") { session.restore(tag: slot.tag, hidden: true) }
                Button("恢复") { session.restore(tag: slot.tag) }
            }
            Text("\(slot.kind.rawValue) 源槽 \(slot.sourceIndex) · \(slot.instanceCount) 个实例 · \(sizeDescription)")
                .font(.caption).foregroundStyle(.secondary)
            if !slot.sourceNames.isEmpty {
                Text(slot.sourceNames.joined(separator: " / ")).font(.caption2).foregroundStyle(.secondary)
            }
            if slot.kind == .text {
                TextField("替换文字", text: $text, axis: .vertical).lineLimit(2...4)
                HStack {
                    Picker("布局", selection: $layout) {
                        ForEach(DemoTextLayout.allCases) { value in Text(value.rawValue).tag(value) }
                    }
                    Button("应用文字") { session.replaceText(tag: slot.tag, text: text, layout: layout) }
                }
            } else {
                Picker("图像播放方式", selection: $imagePlayback) {
                    Text("播放动图").tag(PAGImagePlaybackMode.animated)
                    Text("静态首帧").tag(PAGImagePlaybackMode.still)
                }
                .pickerStyle(.segmented)
                Picker("图片适配", selection: $imageScale) {
                    ForEach(DemoImageScaleChoice.allCases) { choice in Text(choice.rawValue).tag(choice) }
                }
                Picker("槽位遮罩", selection: $imageMask) {
                    ForEach(DemoImageMaskChoice.allCases) { choice in Text(choice.rawValue).tag(choice) }
                }
                if imageMask == .original {
                    Picker("遮罩原槽", selection: $maskSource) {
                        ForEach(session.slots.filter { $0.kind == .image }) { source in
                            Text(source.tag).tag(source.tag)
                        }
                    }
                    Text("只读取原图 alpha，保留来源槽的内容与用途。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(DemoMediaChoice.allCases) { choice in
                        Button(choice.rawValue) {
                            session.replaceImage(tag: slot.tag, choice: choice, playbackMode: imagePlayback,
                                scale: imageScale, mask: imageMask, maskSource: maskSource)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            if let event = session.contentEvents.last(where: { $0.tag == slot.tag }) {
                Text("\(event.status.rawValue) · \(event.detail ?? String(format: "%.3fs", event.elapsedSeconds))")
                    .font(.caption2).textSelection(.enabled)
            }
        }
        .padding().background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 14))
        .disabled(!session.isLoaded)
        .accessibilityIdentifier("detail.slot.\(slot.tag)")
        .onAppear {
            if maskSource.isEmpty {
                maskSource = session.slots.first(where: { $0.tag == "xin7.png" })?.tag ??
                    session.slots.first(where: { $0.kind == .image })?.tag ?? ""
            }
        }
    }

    /// 没有固有文本框的槽明确显示未提供，不拿某个实例屏幕尺寸填空。
    private var sizeDescription: String {
        slot.size.map { "局部 \(Int($0.width))×\(Int($0.height))" } ?? "无固有文本框"
    }
}
