import SwiftUI
import AppKit
import MediaCore
import FlowService
import Combine

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    let service: TaskService
    var jobs: [MediaJob] { get { service.jobs } set { service.jobs = newValue } }
    private var serviceSubscription: AnyCancellable?
    private var bridge: BridgeServer?
    private var bootstrapped = false
    @Published var showAI = false
    @Published var bridgeMessage = "正在启动本地任务服务…"
    @Published var settings = ConversionSettings() { didSet { savePreferences() } }
    @Published var engine: EngineInfo?
    @Published var engineMessage = "正在检测 FFmpeg…"
    @Published var detectingEngine = false
    @Published var customEnginePath: String? { didSet { savePreferences() } }
    var isRunning: Bool { service.isRunning }
    @Published var importCount = 0
    @Published var maintenanceRunning = false { didSet { service.maintenance = maintenanceRunning } }
    @Published var maintenanceLog = ""
    @Published var alertMessage: String?
    @Published var showEngine = false
    @Published var logJobID: UUID?
    @Published var search = ""
    @Published var filter: QueueFilter = .all
    private var runner: ProcessRunner?
    private var isInitialized = false
    private let support: URL

    enum QueueFilter: String, CaseIterable {
        case all = "全部", waiting = "待处理", finished = "已完成"
    }
    private struct Preferences: Codable { var settings: ConversionSettings; var customEnginePath: String? }

    init() {
        support = FlowPaths.support
        service = TaskService(support: support)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: support.appendingPathComponent("preferences.json")),
           let preferences = try? JSONDecoder().decode(Preferences.self, from: data) {
            settings = preferences.settings; customEnginePath = preferences.customEnginePath
        }
        serviceSubscription = service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        isInitialized = true
    }

    var busy: Bool { isRunning || maintenanceRunning || importCount > 0 || detectingEngine }
    var readyCount: Int { jobs.filter { $0.status == .ready && !$0.isAI }.count }
    var completedCount: Int { jobs.filter { $0.status == .completed }.count }
    var visibleJobs: [MediaJob] {
        jobs.filter { job in
            (search.isEmpty || job.input.lastPathComponent.localizedCaseInsensitiveContains(search)) &&
            (filter == .all || (filter == .finished ? job.status == .completed : job.status != .completed))
        }
    }
    var brewURL: URL? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) } }
    var brewManaged: Bool { guard let engine else { return customEnginePath == nil }; return engine.ffmpeg.path == "/opt/homebrew/bin/ffmpeg" || engine.ffmpeg.path == "/usr/local/bin/ffmpeg" }
    var canStart: Bool { !busy && engine != nil && readyCount > 0 && (engine?.supports(settings.preset, hardware: settings.hardware) ?? false) }

    func bootstrap() async {
        guard !bootstrapped else { return }; bootstrapped = true
        let router = ToolRouter(service: service)
        let server = BridgeServer { request in await router.handle(request) }
        do { try server.start(); bridge = server; bridgeMessage = "本地服务就绪 · stdio / Unix socket" }
        catch { bridgeMessage = error.localizedDescription; alertMessage = bridgeMessage; return }
        await refreshEngine()
        await readMetadata(ids: jobs.filter { $0.info == nil && $0.status == .ready }.map(\.id))
        if let message = service.lastError { alertMessage = message }
    }
    func refreshEngine() async {
        guard !detectingEngine else { return }
        detectingEngine = true
        defer { detectingEngine = false }
        do {
            engine = try await EngineService.detect(customPath: customEnginePath)
            engineMessage = engine?.version ?? "已就绪"
            service.engine = engine
        } catch { engine = nil; service.engine = nil; engineMessage = error.localizedDescription }
    }
    func chooseEngine() {
        let panel = NSOpenPanel(); panel.title = "选择 ffmpeg 可执行文件"
        panel.message = "同一目录中需要同时存在 ffprobe。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            customEnginePath = url.path; Task { await refreshEngine() }
        }
    }
    func useAutomaticEngine() { customEnginePath = nil; Task { await refreshEngine() } }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.title = "添加音视频文件"; panel.prompt = "添加到队列"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addURLs(panel.urls) }
    }
    func addURLs(_ urls: [URL]) {
        guard !maintenanceRunning else { alertMessage = "引擎维护期间请稍后添加文件。"; return }
        var added: [UUID] = []; var skipped = 0
        for url in urls {
            guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { skipped += 1; continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !jobs.contains(where: { $0.input.standardizedFileURL.resolvingSymlinksInPath() == canonical }) else { continue }
            let job = MediaJob(input: url.standardizedFileURL); jobs.append(job); added.append(job.id)
        }
        persistQueue()
        if skipped > 0 { alertMessage = "跳过了 \(skipped) 个文件夹或不可读取的项目，请添加具体的音视频文件。" }
        if !added.isEmpty { filter = .all; search = ""; Task { await readMetadata(ids: added) } }
    }
    private func readMetadata(ids: [UUID]) async {
        guard let engine, !ids.isEmpty else { return }
        importCount += 1
        defer { importCount -= 1; persistQueue() }
        for id in ids {
            guard let job = jobs.first(where: { $0.id == id }), job.status == .ready else { continue }
            update(id) { $0.status = .probing }
            do {
                let info = try await EngineService.probe(job.input, engine: engine)
                update(id) { $0.info = info; $0.status = .ready; $0.error = nil }
            } catch { update(id) { $0.status = .failed; $0.error = error.localizedDescription; $0.log = error.localizedDescription } }
        }
    }
    func chooseOutputDirectory() {
        let panel = NSOpenPanel(); panel.title = "选择输出文件夹"; panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK { settings.outputDirectory = panel.url?.path }
    }
    func startQueue() {
        guard canStart else { return }
        do {
            let start = try Timecode.parse(settings.startTime) ?? 0
            if let end = try Timecode.parse(settings.endTime), end <= start { throw MediaFlowError.message("结束时间必须晚于开始时间。") }
            service.enqueueManual(settings: settings)
            if let message = service.lastError { alertMessage = message }
        } catch { alertMessage = error.localizedDescription }
    }
    func cancelCurrent() { if let id = service.runningID { service.cancel([id]) } }
    func cancelJob(_ id: UUID) { service.cancel([id]) }
    func stopQueue() { service.stopAll() }
    func retry(_ id: UUID) { service.retry(id) }
    func approve(_ id: UUID) { service.approve(id); if let message = service.lastError { alertMessage = message } }
    func retryAll() {
        guard !busy else { return }
        for id in jobs.filter({ [.failed, .cancelled].contains($0.status) }).map(\.id) { service.retry(id) }
    }
    func remove(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), ![.running, .queued].contains(job.status) else { return }
        jobs.removeAll { $0.id == id }; persistQueue()
    }
    func clearCompleted() { jobs.removeAll { $0.status == .completed }; persistQueue() }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func revealOutputDirectory() {
        if let path = settings.outputDirectory { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else if let output = jobs.last(where: { $0.output != nil })?.output { reveal(output) }
        else if let first = jobs.first { reveal(first.input) }
    }
    private func update(_ id: UUID, _ body: (inout MediaJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; body(&jobs[index])
    }
    private func savePreferences() {
        guard isInitialized else { return }
        do { try JSONEncoder().encode(Preferences(settings: settings, customEnginePath: customEnginePath)).write(to: support.appendingPathComponent("preferences.json"), options: .atomic) }
        catch { alertMessage = "设置保存失败：\(error.localizedDescription)" }
    }
    private func persistQueue() { service.persistSafely() }
    func updatePolicy(_ body: (inout AccessPolicy) -> Void) {
        var policy = service.policy; body(&policy)
        do { try service.setPolicy(policy) } catch { alertMessage = error.localizedDescription }
    }
    func chooseAIDirectory(write: Bool) {
        let panel = NSOpenPanel(); panel.title = write ? "授权 AI 写入转换结果的目录" : "授权 AI 读取媒体的目录"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = write; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let paths = panel.urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            updatePolicy { if write { $0.writeDirectories = Array(Set($0.writeDirectories + paths)).sorted() } else { $0.readDirectories = Array(Set($0.readDirectories + paths)).sorted() } }
        }
    }
    var mcpExecutable: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/lovemeliya-flow-mcp").path }
    var mcpConfig: String {
        let config = ["mcpServers": ["lovemeliya-flow": ["command": mcpExecutable, "args": ["--stdio"]] as [String: Any]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func copyMCPConfig() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mcpConfig, forType: .string) }
    func checkMCPBridge() async {
        do {
            let response = try await LocalBridge.request(BridgeRequest(name: "flow_capabilities", arguments: .object([:]), client: "APP 连接检查", session: "app-check"))
            bridgeMessage = response.ok ? "连接检查通过 · 本地服务可访问" : response.error?.message ?? "检查失败"
            _ = try? await LocalBridge.request(BridgeRequest(name: "_disconnect", arguments: .object([:]), client: "APP", session: "app-check"))
        } catch { bridgeMessage = error.localizedDescription }
    }
    func maintainEngine() {
        guard !busy, let brew = brewURL, brewManaged else { return }
        maintenanceRunning = true; maintenanceLog = "正在检查 Homebrew 的 FFmpeg 安装…\n"
        let maintenance = ProcessRunner(); runner = maintenance
        Task {
            defer { maintenanceRunning = false; runner = nil }
            do {
                let installed = try await maintenance.run(executable: brew, arguments: ["list", "--versions", "ffmpeg"], timeout: 30, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                let action = installed.exitCode == 0 && !installed.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "upgrade" : "install"
                maintenanceLog += "执行 brew \(action) ffmpeg（可能需要几分钟）…\n"
                let append: @Sendable (String) -> Void = { [weak self] chunk in Task { @MainActor in
                    guard let self else { return }; self.maintenanceLog += chunk
                    if self.maintenanceLog.count > 80_000 { self.maintenanceLog = String(self.maintenanceLog.suffix(60_000)) }
                } }
                let result = try await maintenance.run(executable: brew, arguments: [action, "ffmpeg"], timeout: 1800,
                    environment: ["HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ANALYTICS": "1", "NONINTERACTIVE": "1"], onOutput: append, onError: append)
                guard result.exitCode == 0 else { throw MediaFlowError.message("Homebrew 执行失败（\(result.exitCode)），请检查日志。") }
                await refreshEngine()
                maintenanceLog += engine == nil ? "\n维护结束，但引擎验证失败：\(engineMessage)" : "\n完成，引擎已重新检测。"
            } catch { maintenanceLog += "\n" + error.localizedDescription }
        }
    }
}
