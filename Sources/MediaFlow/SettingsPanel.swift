import SwiftUI
import MediaCore
import FlowService

struct SettingsPanel: View {
    @EnvironmentObject var store: AppStore
    @State private var showTrim = false
    private var category: Binding<Int> { Binding(get: { store.settings.preset.isAudio ? 1 : store.settings.preset.isRemux ? 2 : 0 }, set: { store.settings.preset = $0 == 1 ? .mp3 : $0 == 2 ? .remuxMKV : .mp4 }) }
    private var availablePresets: [Preset] { Preset.allCases.filter { category.wrappedValue == 1 ? $0.isAudio : category.wrappedValue == 2 ? $0.isRemux : !$0.isAudio && !$0.isRemux } }
    private var hardwareAvailable: Bool { [.mp4, .compact, .hevc].contains(store.settings.preset) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.accent); Text("输出设置").font(.system(size: 14, weight: .semibold)); Spacer(); Text("OUTPUT").font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(Palette.muted) }.padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 20).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        caption("01", "选择用途")
                        Picker("用途", selection: category) { Text("视频").tag(0); Text("音频").tag(1); Text("换封装").tag(2) }.pickerStyle(.segmented).labelsHidden()
                        Picker("输出格式", selection: $store.settings.preset) { ForEach(availablePresets) { preset in Text(preset.title).tag(preset) } }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading).controlSize(.regular)
                        Text(store.settings.preset.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                    divider
                    if !store.settings.preset.isRemux {
                        VStack(alignment: .leading, spacing: 12) {
                            caption("02", "质量与尺寸")
                            if ![.wav, .flac].contains(store.settings.preset) {
                                label("质量偏好")
                                Picker("质量", selection: $store.settings.quality) { ForEach(Quality.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !store.settings.preset.isAudio {
                                label("画面尺寸")
                                Picker("尺寸", selection: $store.settings.resolution) { ForEach(Resolution.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                                if store.settings.preset == .compact && store.settings.resolution == .source { Text("轻量预设会限制在 1080p 以内，不放大原画面。").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                                Toggle("保留音频", isOn: $store.settings.includeAudio).font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
                                if hardwareAvailable {
                                    Toggle("Apple 硬件加速", isOn: $store.settings.hardware).font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
                                    Text(store.settings.hardware ? "更快完成；同等画质的体积可能更大。" : "软件编码，通常更适合控制画质与体积。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                Text("转换保留全部音轨并转为双声道；暂不导出字幕。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                            } else if [.flac, .wav].contains(store.settings.preset) {
                                Text(store.settings.preset == .flac ? "保持原音轨的采样率与声道，使用 FLAC 无损编码。" : "保持采样率与声道，输出 16-bit PCM。").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                            } else { Text("提取第一条音轨，输出双声道。").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        }
                        divider
                        DisclosureGroup(isExpanded: $showTrim) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 9) { timeField("开始", text: $store.settings.startTime); timeField("结束", text: $store.settings.endTime) }
                                Text("支持秒数或 HH:MM:SS。留空表示从头到尾；本批次所有文件使用相同时间。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                if !store.settings.startTime.isEmpty || !store.settings.endTime.isEmpty { Button("清除截取时间") { store.settings.startTime = ""; store.settings.endTime = "" }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.accent) }
                            }.padding(.top, 10)
                        } label: { Label("仅转换指定片段", systemImage: "scissors").font(.system(size: 11)) }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("不重新编码", systemImage: "bolt").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                            Text(store.settings.preset == .remuxMKV ? "保留视频、音轨、字幕与附件。不同编码的兼容性由 MKV 封装决定。" : "保留视频和音轨；不包含字幕与附件。封装不兼容时请改用 MKV。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            if !store.settings.startTime.isEmpty || !store.settings.endTime.isEmpty { Button("清除已有的截取时间") { store.settings.startTime = ""; store.settings.endTime = "" }.font(.system(size: 11)).foregroundStyle(.orange); Text("换封装模式不支持精确截取。").font(.system(size: 10)).foregroundStyle(.orange) }
                        }
                    }
                    divider
                    VStack(alignment: .leading, spacing: 12) {
                        caption("03", "保存位置")
                        Button { store.chooseOutputDirectory() } label: { HStack(spacing: 9) { Image(systemName: "folder").foregroundStyle(Palette.accent); VStack(alignment: .leading, spacing: 4) { Text(store.settings.outputDirectory == nil ? "源文件旁的输出文件夹" : URL(fileURLWithPath: store.settings.outputDirectory!).lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle); Text(store.settings.outputDirectory ?? "LOVEmeliya Flow 输出 /").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(2).truncationMode(.middle) }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading); Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize() }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).help(store.settings.outputDirectory ?? "每个源文件所在目录中的 LOVEmeliya Flow 输出 文件夹")
                        if store.settings.outputDirectory != nil { Button("恢复默认位置") { store.settings.outputDirectory = nil }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.accent) }
                        Label("重名时自动编号，保留源文件", systemImage: "checkmark.shield").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20).padding(.trailing, 26).padding(.bottom, 20).disabled(store.isRunning || store.maintenanceRunning)
            }.scrollIndicators(.visible).frame(maxHeight: .infinity).clipped()
            Rectangle().fill(Palette.line).frame(height: 1)
            VStack(spacing: 10) {
                if store.engine == nil { Button("先配置 FFmpeg 引擎") { store.showEngine = true }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Palette.accent) }
                else if !(store.engine?.supports(store.settings.preset, hardware: store.settings.hardware) ?? false) { Text("当前引擎缺少此预设所需的编码器").font(.system(size: 10)).foregroundStyle(.orange) }
                Button { store.startQueue() } label: { HStack(spacing: 8) { Image(systemName: store.isRunning ? "hourglass" : "play.fill"); Text(store.isRunning ? "正在转换" : store.readyCount > 0 ? "开始转换 · \(store.readyCount)" : "开始转换") }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.background.opacity(store.canStart ? 1 : 0.55)).frame(maxWidth: .infinity).padding(.vertical, 14).background(Palette.accent.opacity(store.canStart ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).disabled(!store.canStart)
                Text(store.isRunning ? "本轮设置已锁定，新添加文件留待下一批。" : "以上设置仅应用于手动任务；AI 任务使用自己的设置。").font(.system(size: 9)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20).fixedSize(horizontal: false, vertical: true).background(Palette.sidebar)
        }.background(Palette.sidebar).clipped()
        .onAppear { showTrim = !store.settings.startTime.isEmpty || !store.settings.endTime.isEmpty }
    }
    private var divider: some View { Rectangle().fill(Palette.line).frame(height: 1) }
    private func caption(_ number: String, _ text: String) -> some View { HStack(spacing: 8) { Text(number).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.accent); Text(text).font(.system(size: 11, weight: .semibold)) } }
    private func label(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(Palette.muted) }
    private func timeField(_ title: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 5) { label(title); TextField("00:00:00", text: text).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)) } }
}

struct EngineView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("FFmpeg 引擎管理").font(.system(size: 21, weight: .semibold)); Text("应用与引擎独立更新，转换始终在本机执行。").font(.system(size: 12)).foregroundStyle(Palette.muted) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            VStack(alignment: .leading, spacing: 9) {
                Label(store.engine == nil ? "引擎未就绪" : "引擎就绪", systemImage: store.engine == nil ? "exclamationmark.circle" : "checkmark.circle.fill").foregroundStyle(store.engine == nil ? .orange : .green).font(.system(size: 13, weight: .semibold))
                Text(store.engineMessage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if let engine = store.engine { Text(engine.ffmpeg.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled); Text("已检测到 \(engine.encoders.count) 个编码器").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack { Button("重新检测") { Task { await store.refreshEngine() } }; Button("选择 ffmpeg…") { store.chooseEngine() }; if store.customEnginePath != nil { Button("恢复自动查找") { store.useAutomaticEngine() } }; if store.detectingEngine { ProgressView().controlSize(.small) } }.disabled(store.busy)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("通过 Homebrew 安装 / 更新").font(.system(size: 13, weight: .semibold))
                Text("从 Homebrew 获取引擎及所需依赖，完成后自动重新检测。更新会影响本机共用的 FFmpeg；本版不提供一键版本回退。").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if store.brewURL == nil { Text("未检测到 Homebrew。请先安装 Homebrew，或直接选择已有的完整 FFmpeg 安装。").font(.system(size: 11)).foregroundStyle(.orange) }
                if !store.brewManaged { Text("当前使用自定义引擎，请自行更新，或先恢复自动查找。").font(.system(size: 11)).foregroundStyle(.orange) }
                HStack { Button(store.maintenanceRunning ? "引擎维护中…" : "安装 / 更新 FFmpeg") { store.maintainEngine() }.disabled(store.busy || store.brewURL == nil || !store.brewManaged); if store.maintenanceRunning { ProgressView().controlSize(.small) }; Spacer() }
            }
            ScrollView { Text(store.maintenanceLog.isEmpty ? "运行记录会显示在这里。" : store.maintenanceLog).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 175).background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
            Text("已支持：视频转码、音频提取、换封装、批量队列、片段截取。HDR 转码、字幕烧录与多文件合并暂未纳入第一版。").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(26).frame(width: 630).background(Palette.sidebar).tint(Palette.accent)
    }
}

struct JobLogView: View {
    let job: MediaJob
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) { VStack(alignment: .leading, spacing: 5) { Text("任务日志").font(.title2.weight(.semibold)); Text(job.input.lastPathComponent).font(.caption).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle).help(job.input.lastPathComponent) }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading); Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.log, forType: .string) }.fixedSize(); Button("完成") { dismiss() }.fixedSize().keyboardShortcut(.cancelAction) }.fixedSize(horizontal: false, vertical: true)
            ScrollView([.horizontal, .vertical]) { Text(job.log.isEmpty ? "此任务尚未执行，没有转换日志。" : job.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .topLeading) }.background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
        }.padding(22).frame(width: 820, height: 550).background(Palette.sidebar)
    }
}
