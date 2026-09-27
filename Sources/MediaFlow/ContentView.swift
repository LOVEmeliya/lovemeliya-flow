import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MediaCore
import FlowService

enum Palette {
    static let background = Color(red: 0.065, green: 0.073, blue: 0.09)
    static let sidebar = Color(red: 0.085, green: 0.094, blue: 0.11)
    static let surface = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let accent = Color(red: 1, green: 0.64, blue: 0.33)
    static let muted = Color(red: 0.57, green: 0.60, blue: 0.65)
    static let line = Color.white.opacity(0.075)
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var dropActive = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 216)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) { header; queue; footer }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            Rectangle().fill(Palette.line).frame(width: 1)
            SettingsPanel().frame(width: 320)
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropActive, perform: handleDrop)
        .overlay { if dropActive { RoundedRectangle(cornerRadius: 16).stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(8).allowsHitTesting(false) } }
        .sheet(isPresented: $store.showEngine) { EngineView().environmentObject(store) }
        .sheet(isPresented: $store.showAI) { AIAccessView().environmentObject(store) }
        .sheet(isPresented: Binding(get: { store.logJobID != nil }, set: { if !$0 { store.logJobID = nil } })) {
            if let job = store.jobs.first(where: { $0.id == store.logJobID }) { JobLogView(job: job) }
        }
        .alert(AppBrand.name, isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("知道了", role: .cancel) { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 11).fill(Palette.accent); Text("LM").font(.system(size: 17, weight: .heavy, design: .rounded)).tracking(-1).foregroundStyle(Palette.background) }.frame(width: 37, height: 39)
                VStack(alignment: .leading, spacing: 5) { Text("LOVEmeliya").font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.9); Text("FLOW").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(3).foregroundStyle(Palette.accent); Text("音视频工具箱").font(.system(size: 9)).foregroundStyle(Palette.muted) }
            }.padding(.top, 35).padding(.bottom, 28).fixedSize(horizontal: false, vertical: true)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.bottom, 12)
            sidebarItem("转换队列", icon: "square.stack.3d.up", selected: true, count: store.jobs.count)
            Button { store.revealOutputDirectory() } label: { sidebarItem("输出文件夹", icon: "folder", selected: false) }.buttonStyle(.plain).padding(.top, 6)
            Button { store.showAI = true } label: { sidebarItem("AI 接入 · MCP", icon: "point.3.connected.trianglepath.dotted", selected: false) }.buttonStyle(.plain).padding(.top, 6)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(Palette.accent.opacity(0.85))
                Text("文件留在你的 Mac").font(.system(size: 12, weight: .medium))
                Text("转换在本机完成。\n无需上传，也无需登录。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            Button { store.showEngine = true } label: {
                HStack(spacing: 8) { Circle().fill(store.engine == nil ? Color.orange : Color.green).frame(width: 6, height: 6); VStack(alignment: .leading, spacing: 3) { Text("FFmpeg 引擎").font(.system(size: 12, weight: .medium)); Text(store.engine == nil ? "点击配置" : "就绪 · 管理与更新").font(.system(size: 10)).foregroundStyle(Palette.muted) }; Spacer(); Image(systemName: "gearshape").foregroundStyle(Palette.muted) }
            }.buttonStyle(.plain).padding(.top, 23).padding(.bottom, 24)
            Text("PERSONAL EDITION / " + AppBrand.version).font(.system(size: 8, design: .monospaced)).tracking(0.7).foregroundStyle(Palette.muted.opacity(0.7)).padding(.bottom, 20)
        }.padding(.horizontal, 18).background(Palette.sidebar)
    }
    private func sidebarItem(_ title: String, icon: String, selected: Bool, count: Int? = nil) -> some View {
        HStack(spacing: 10) { Image(systemName: icon).frame(width: 17); Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)); Spacer(); if let count { Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4)) } }
            .foregroundStyle(selected ? Palette.accent : Palette.muted).padding(.horizontal, 12).padding(.vertical, 12).background(selected ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) { Text("让格式，顺畅流转。").font(.system(size: 24, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85); Text("音视频转换、压缩与提取，一个队列搞定。").font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 10)
                Button { store.chooseFiles() } label: { Label("添加文件", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line)) }.buttonStyle(.plain).fixedSize().disabled(store.maintenanceRunning)
            }
            HStack(spacing: 18) {
                ForEach(AppStore.QueueFilter.allCases, id: \.self) { filter in Button { store.filter = filter } label: { VStack(spacing: 9) { Text(filter.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(store.filter == filter ? .white : Palette.muted); Rectangle().fill(store.filter == filter ? Palette.accent : .clear).frame(height: 2) }.frame(width: 54) }.buttonStyle(.plain) }
                Spacer()
                if store.importCount > 0 { ProgressView().controlSize(.small); Text("读取媒体").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                Menu { Button("将失败 / 取消的任务重新排队") { store.retryAll() }.disabled(store.busy); Button("清除已完成记录") { store.clearCompleted() } } label: { Image(systemName: "ellipsis").foregroundStyle(Palette.muted).frame(width: 28, height: 28).contentShape(Rectangle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("队列选项").accessibilityLabel("队列选项")
            }
        }.padding(.horizontal, 24).padding(.top, 38).fixedSize(horizontal: false, vertical: true).background(Palette.background)
    }
    @ViewBuilder private var queue: some View {
        if store.jobs.isEmpty { emptyState }
        else {
            VStack(spacing: 0) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted); TextField("搜索文件名", text: $store.search).textFieldStyle(.plain).font(.system(size: 11)); Text("\(store.visibleJobs.count) 个文件").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).fixedSize() }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 16).padding(.bottom, 12)
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(store.visibleJobs) { job in JobRow(job: job).environmentObject(store) }
                        if store.visibleJobs.isEmpty { Text("没有符合条件的任务").foregroundStyle(Palette.muted).padding(40) }
                        Button { store.chooseFiles() } label: { HStack { Image(systemName: "plus.circle"); Text("继续添加，或将文件拖到这里") }.font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(20).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5]))) }.buttonStyle(.plain).padding(.top, 5).disabled(store.maintenanceRunning)
                    }.padding(.bottom, 18).padding(.trailing, 10)
                }.scrollIndicators(.visible).clipped()
            }.padding(.horizontal, 24).frame(maxHeight: .infinity)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack { Circle().fill(Palette.accent.opacity(0.035)).frame(width: 136, height: 136); RoundedRectangle(cornerRadius: 22).fill(Palette.surface).frame(width: 82, height: 94).rotationEffect(.degrees(-9)); RoundedRectangle(cornerRadius: 20).fill(Palette.sidebar).frame(width: 82, height: 94).overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.accent.opacity(0.3))).rotationEffect(.degrees(7)); Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent) }.padding(.bottom, 25)
            Text("把文件放进来，交给 Flow").font(.system(size: 17, weight: .medium)).padding(.bottom, 10)
            Text("拖入视频或音频，也可以一次添加多个文件。").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.bottom, 24)
            Button { store.chooseFiles() } label: { Label("选择文件", systemImage: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.background).padding(.horizontal, 24).padding(.vertical, 12).background(Palette.accent, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).disabled(store.maintenanceRunning)
            HStack(spacing: 8) { ForEach(["MP4", "MOV", "MKV", "MP3", "FLAC"], id: \.self) { Text($0).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).padding(.horizontal, 8).padding(.vertical, 5).background(Palette.surface, in: RoundedRectangle(cornerRadius: 5)) } }.padding(.top, 26)
            Spacer()
            HStack(spacing: 7) { Image(systemName: "arrow.turn.down.right"); Text("在右侧选择输出方式，然后开始转换") }.font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.8)).padding(.bottom, 27)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var footer: some View {
        HStack {
            Circle().fill(store.isRunning ? Palette.accent : Palette.muted).frame(width: 5, height: 5)
            Text(store.isRunning ? "正在处理 · 队列按顺序执行" : store.jobs.isEmpty ? "准备就绪，等待添加文件" : "\(store.readyCount) 个手动待处理 · \(store.jobs.filter { $0.status == .awaitingApproval }.count) 个待确认 · \(store.completedCount) 个完成").font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer()
            if store.isRunning { Button("停止队列") { store.stopQueue() }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 11)) }
            else { Text("⌘ O 添加").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
        }.padding(.horizontal, 24).padding(.vertical, 17).fixedSize(horizontal: false, vertical: true).background(Palette.sidebar).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { Task { @MainActor in store.addURLs([url]) } }
            }
        }
        return !providers.isEmpty
    }
}

struct JobRow: View {
    @EnvironmentObject var store: AppStore
    let job: MediaJob
    private var statusColor: Color { switch job.status { case .completed: return .green; case .failed: return .red; case .running: return Palette.accent; default: return Palette.muted } }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: job.info?.videoCodec == nil && job.info?.audioCodec != nil ? "waveform" : "film").font(.system(size: 18)).foregroundStyle(Palette.accent.opacity(0.9)).frame(width: 38, height: 44).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.input.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(job.input.path)
                    Text(metadata).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1)
                    if let settings = job.settings, job.status != .ready { Text(settings.preset.title).font(.system(size: 9)).foregroundStyle(Palette.muted) }
                    if let client = job.sourceClient { Label("AI · " + client, systemImage: "sparkles").font(.system(size: 9)).foregroundStyle(Palette.accent).lineLimit(1) }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(job.status.title).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor).lineLimit(1).fixedSize()
                    HStack(spacing: 4) {
                        if job.status == .running { Button { store.cancelCurrent() } label: { Image(systemName: "stop.circle").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("取消当前任务，继续下一个") }
                        if let output = job.output, job.status == .completed { Button { store.reveal(output) } label: { Image(systemName: "folder").frame(width: 28, height: 28).contentShape(Rectangle()) }.help("在 Finder 中显示结果") }
                        Menu {
                            if job.status == .awaitingApproval { Button("确认并开始此 AI 任务") { store.approve(job.id) } }
                            if [.awaitingApproval, .queued].contains(job.status) { Button("取消此任务") { store.cancelJob(job.id) } }
                            Button("在 Finder 中显示源文件") { store.reveal(job.input) }
                            if let output = job.output { Button("打开输出文件") { NSWorkspace.shared.open(output) } }
                            Button("查看日志与命令") { store.logJobID = job.id }
                            if [.failed, .cancelled, .completed].contains(job.status) { Button(job.status == .completed ? "使用当前设置再次转换" : "重新排队") { store.retry(job.id) }.disabled(store.isRunning) }
                            Divider()
                            Button("移除记录", role: .destructive) { store.remove(job.id) }.disabled([.running, .queued].contains(job.status))
                        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("任务选项").accessibilityLabel("任务选项")
                    }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.muted)
                }.frame(width: 64, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
            if job.status == .running {
                ProgressView(value: job.progress).tint(Palette.accent)
                HStack { Text("\(Int(job.progress * 100))%"); Spacer(); if job.speed > 0 { Text(String(format: "%.1f×", job.speed)) }; if let eta = job.eta { Text("预计剩余 " + Timecode.display(eta)) } }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            if job.status == .awaitingApproval {
                HStack {
                    Text("AI 已提交 · 请确认任务设置").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("取消") { store.cancelJob(job.id) }.buttonStyle(.plain).font(.system(size: 11))
                    Button("确认开始") { store.approve(job.id) }.font(.system(size: 11)).tint(Palette.accent)
                }
                if let settings = job.settings {
                    Text("输出：\(settings.outputDirectory ?? "默认目录")\n采样率：\(settings.sampleRate.map(String.init) ?? "预设默认") · 声道：\(settings.channels.map(String.init) ?? "预设默认") · 片段：\(settings.startTime.isEmpty ? "开头" : settings.startTime) → \(settings.endTime.isEmpty ? "结尾" : settings.endTime)").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let error = job.error { Text(error).font(.system(size: 10)).foregroundStyle(job.status == .failed ? .red.opacity(0.9) : Palette.muted).lineLimit(3).textSelection(.enabled) }
            if let bytes = job.outputBytes, job.status == .completed {
                HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("输出 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); if let original = job.info?.bytes, original > 0 { Text(String(format: "· 原文件的 %.0f%%", Double(bytes) / Double(original) * 100)) } }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(job.status == .running ? Palette.accent.opacity(0.35) : Palette.line))
    }
    private var metadata: String {
        guard let info = job.info else { return job.status == .probing ? "正在读取媒体信息…" : job.input.pathExtension.uppercased() }
        var parts = [Timecode.display(info.duration), ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)]
        if let width = info.width, let height = info.height { parts.append("\(width)×\(height)") }
        if let codec = info.videoCodec ?? info.audioCodec { parts.append(codec.uppercased()) }
        if info.isHDR { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }
}
