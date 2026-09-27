import Foundation
import Combine
import MediaCore

@MainActor
public final class TaskService: ObservableObject {
    @Published public var jobs: [MediaJob] = []
    @Published public private(set) var runningID: UUID?
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var policy = AccessPolicy()
    @Published public private(set) var audit: [AuditEntry] = []
    @Published public var clients: [String: Date] = [:]
    public var engine: EngineInfo?
    public var maintenance = false
    public let support: URL
    public private(set) var plans: [FlowPlan] = []
    public private(set) var submissions: [Submission] = []
    private var runner: ProcessRunner?
    private var processing: Task<Void, Never>?
    private var paused = false
    private struct State: Codable { var jobs: [MediaJob]; var plans: [FlowPlan]; var submissions: [Submission] }

    public init(support: URL = FlowPaths.support) {
        self.support = support
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: support.appendingPathComponent("service.json")) {
                let state = try JSONDecoder().decode(State.self, from: data)
                jobs = state.jobs; plans = state.plans; submissions = state.submissions
            } else if let data = try? Data(contentsOf: support.appendingPathComponent("queue.json")) {
                jobs = try JSONDecoder().decode([MediaJob].self, from: data)
            }
            if let data = try? Data(contentsOf: support.appendingPathComponent("ai-policy.json")) { policy = try JSONDecoder().decode(AccessPolicy.self, from: data) }
            if let data = try? Data(contentsOf: support.appendingPathComponent("ai-audit.json")) { audit = try JSONDecoder().decode([AuditEntry].self, from: data) }
            for i in jobs.indices where [.running, .probing, .queued].contains(jobs[i].status) {
                jobs[i].status = jobs[i].isAI ? .awaitingApproval : .ready
                jobs[i].progress = 0; jobs[i].eta = nil; jobs[i].speed = 0
                jobs[i].error = "上次执行已中断，请确认后重新开始。"; jobs[i].errorCode = "INTERRUPTED"
            }
        } catch { lastError = "任务存储读取失败：\(error.localizedDescription)" }
    }
    public func persist() throws {
        try JSONEncoder().encode(State(jobs: jobs, plans: plans, submissions: submissions)).write(to: support.appendingPathComponent("service.json"), options: .atomic)
    }
    public func persistSafely() { do { try persist() } catch { lastError = "保存失败：\(error.localizedDescription)"; paused = true } }
    public func update(_ id: UUID, _ body: (inout MediaJob) -> Void) { guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }; body(&jobs[i]) }
    public func setPolicy(_ value: AccessPolicy) throws {
        try JSONEncoder().encode(value).write(to: support.appendingPathComponent("ai-policy.json"), options: .atomic)
        policy = value
        for id in jobs.filter({ $0.isAI && [.queued, .running].contains($0.status) }).map(\.id) {
            guard let job = jobs.first(where: { $0.id == id }) else { continue }
            let allowed = value.enabled && (try? value.input(job.input.path)) != nil && (try? value.outputDirectory(job.settings?.outputDirectory ?? "")) != nil
            if !allowed { cancel([id]) }
            else if value.requireApproval && job.status == .queued { update(id) { $0.status = .awaitingApproval } }
        }
        persistSafely()
    }
    public func enqueueManual(settings: ConversionSettings) {
        lastError = nil
        let before = jobs
        for i in jobs.indices where jobs[i].status == .ready && !jobs[i].isAI {
            jobs[i].settings = settings; jobs[i].status = .queued
        }
        do { try persist(); paused = false; startWorker() } catch { jobs = before; lastError = error.localizedDescription }
    }
    public func approve(_ id: UUID) {
        lastError = nil
        guard let job = jobs.first(where: { $0.id == id }), job.isAI, job.status == .awaitingApproval else { return }
        do {
            guard !maintenance else { throw FlowError("ENGINE_BUSY", "引擎维护中，请稍后确认任务。") }
            guard policy.enabled else { throw FlowError("MCP_DISABLED", "请先启用 AI 接入。") }
            _ = try policy.input(job.input.path); _ = try policy.outputDirectory(job.settings?.outputDirectory ?? "")
            update(id) { $0.status = .queued; $0.error = nil }; try persist(); paused = false; startWorker()
        } catch { update(id) { $0.status = .awaitingApproval; $0.error = error.localizedDescription }; lastError = error.localizedDescription }
    }
    public func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status.terminal else { return }
        update(id) { $0.status = job.isAI ? .awaitingApproval : .ready; $0.progress = 0; $0.error = nil; $0.errorCode = nil; $0.speed = 0; $0.eta = nil }
        persistSafely()
    }
    public func cancel(_ ids: [UUID]) {
        for id in ids {
            guard let job = jobs.first(where: { $0.id == id }), !job.status.terminal else { continue }
            if runningID == id { runner?.cancel() }
            else { update(id) { $0.status = .cancelled; $0.error = "任务已取消。"; $0.errorCode = "CANCELLED"; $0.eta = nil } }
        }
        persistSafely()
    }
    public func stopAll() {
        paused = true
        for i in jobs.indices where jobs[i].status == .queued { jobs[i].status = jobs[i].isAI ? .awaitingApproval : .ready }
        runner?.cancel(); persistSafely()
    }
    public func startWorker() {
        guard processing == nil, engine != nil, !maintenance, !paused else { return }
        guard jobs.contains(where: { $0.status == .queued }) else { return }
        isRunning = true
        processing = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "LOVEmeliya Flow 转换媒体")
            defer { ProcessInfo.processInfo.endActivity(activity); processing = nil; isRunning = false; runningID = nil; runner = nil; persistSafely() }
            while !paused && !maintenance, let job = jobs.first(where: { $0.status == .queued }), let engine {
                await convert(job, engine: engine)
            }
        }
    }
    private func convert(_ job: MediaJob, engine: EngineInfo) async {
        let id = job.id; let current = ProcessRunner(); runner = current; runningID = id
        var temp: URL?
        defer { if let temp { try? FileManager.default.removeItem(at: temp) }; runningID = nil; runner = nil; persistSafely() }
        update(id) { $0.status = .running; $0.progress = 0; $0.error = nil; $0.errorCode = nil; $0.output = nil; $0.outputBytes = nil; $0.outputInfo = nil; $0.log = "" }
        do {
            try persist()
            guard let settings = job.settings else { throw FlowError("INVALID_SETTINGS", "任务缺少转换设置。") }
            if job.isAI { try validateAIJob(job) }
            guard engine.supports(settings.preset, hardware: settings.hardware) else { throw FlowError("ENCODER_UNAVAILABLE", "当前引擎缺少指定编码器。") }
            let probeArgs = ["-v", "error"] + (job.isAI ? EngineService.localInputArguments : []) + ["-show_format", "-show_streams", "-of", "json", job.input.path]
            let probe = try await current.run(executable: engine.ffprobe, arguments: probeArgs, timeout: 30)
            guard probe.exitCode == 0 else { throw FlowError("INVALID_MEDIA", "无法读取媒体：\(probe.errorText.suffix(800))") }
            let info = try MediaInfo.decodeProbe(probe.stdout); update(id) { $0.info = info }
            if job.isAI { try validateAIJob(job) }
            let output = try CommandBuilder.uniqueOutput(input: job.input, settings: settings)
            let temporary = CommandBuilder.temporaryURL(for: output); temp = temporary
            let plan = try CommandBuilder.make(input: job.input, info: info, settings: settings, output: output, temporary: temporary, restricted: job.isAI)
            update(id) { $0.log = CommandBuilder.displayCommand(executable: engine.ffmpeg, arguments: plan.arguments) + "\n\n" }
            let progress = ProgressBuffer()
            let result = try await current.run(executable: engine.ffmpeg, arguments: plan.arguments, onOutput: { [weak self] chunk in
                for snapshot in progress.consume(chunk) { Task { @MainActor in self?.update(id) {
                    guard $0.status == .running else { return }
                    $0.progress = plan.expectedDuration > 0 ? min(0.99, snapshot.seconds / plan.expectedDuration) : 0
                    $0.speed = snapshot.speed; $0.eta = snapshot.speed > 0 && plan.expectedDuration > 0 ? max(0, (plan.expectedDuration - snapshot.seconds) / snapshot.speed) : nil
                } } }
            })
            update(id) { $0.log += result.errorText }
            guard result.exitCode == 0 else { throw FlowError("CONVERSION_FAILED", "转换失败（\(result.exitCode)）。\(settings.hardware ? "可关闭硬件加速后重试。" : "请查看任务日志。")\n\(result.errorText.suffix(800))") }
            // Validate the actual output before publishing a success result.
            let verified = try await current.run(executable: engine.ffprobe, arguments: ["-v", "error", "-show_format", "-show_streams", "-of", "json", temporary.path], timeout: 30)
            guard verified.exitCode == 0 else { throw FlowError("OUTPUT_INVALID", "输出无法被媒体引擎读取。") }
            let outputInfo = try MediaInfo.decodeProbe(verified.stdout)
            guard outputInfo.bytes > 0 else { throw FlowError("OUTPUT_INVALID", "输出文件为空。") }
            if job.isAI { try validateAIJob(job) }
            try FileManager.default.moveItem(at: temporary, to: output)
            update(id) { $0.status = .completed; $0.progress = 1; $0.output = output; $0.outputBytes = outputInfo.bytes; $0.outputInfo = outputInfo; $0.eta = nil }
        } catch is CancellationError { update(id) { $0.status = .cancelled; $0.error = "任务已取消，临时输出已清理。"; $0.errorCode = "CANCELLED"; $0.eta = nil } }
        catch {
            update(id) { $0.status = .failed; $0.error = error.localizedDescription; $0.errorCode = (error as? FlowError)?.code ?? "CONVERSION_FAILED"; $0.log += "\n" + error.localizedDescription; $0.eta = nil }
        }
    }
    private func validateAIJob(_ job: MediaJob) throws {
        guard policy.enabled else { throw FlowError("MCP_DISABLED", "AI 接入已关闭。") }
        let canonical = try policy.input(job.input.path)
        guard canonical.path == job.input.path else { throw FlowError("SOURCE_CHANGED", "源路径已变化，请重新生成方案。") }
        _ = try policy.outputDirectory(job.settings?.outputDirectory ?? "")
        if let fingerprint = job.fingerprint, try FileFingerprint(canonical) != fingerprint { throw FlowError("SOURCE_CHANGED", "源文件已变化，请重新生成方案。") }
    }
    public func record(client: String, tool: String, outcome: String) {
        audit.append(AuditEntry(client: String(client.prefix(80)), tool: tool, outcome: outcome))
        if audit.count > 200 { audit.removeFirst(audit.count - 200) }
        try? JSONEncoder().encode(audit).write(to: support.appendingPathComponent("ai-audit.json"), options: .atomic)
    }
    public func storePlan(_ plan: FlowPlan) throws {
        let before = plans
        plans.removeAll { $0.expiresAt < Date() }
        if plans.count >= 100 { plans.removeFirst(plans.count - 99) }
        plans.append(plan)
        do { try persist() } catch { plans = before; throw error }
    }
    public func submit(plan: FlowPlan, key: String, client: String) throws -> Submission {
        guard !maintenance else { throw FlowError("ENGINE_BUSY", "引擎维护中，请稍后重试。") }
        if let old = submissions.first(where: { $0.key == key && $0.client == client }) {
            guard old.planID == plan.id else { throw FlowError("IDEMPOTENCY_CONFLICT", "此 request_id 已用于其他方案。") }; return old
        }
        // A plan can only be submitted once, even under another request_id.
        if let old = submissions.first(where: { $0.planID == plan.id && $0.client == client }) { return old }
        guard plan.expiresAt > Date() else { throw FlowError("PLAN_EXPIRED", "方案已过期，请重新调用 flow_plan。") }
        guard let engine, engine.supports(plan.settings.preset, hardware: plan.settings.hardware) else { throw FlowError("ENCODER_UNAVAILABLE", "引擎不可用或缺少编码器。") }
        for item in plan.items {
            _ = try policy.input(item.input.path)
            guard try FileFingerprint(item.input) == item.fingerprint else { throw FlowError("SOURCE_CHANGED", "源文件已变化，请重新生成方案。") }
        }
        _ = try policy.outputDirectory(plan.settings.outputDirectory ?? "")
        guard jobs.filter({ !$0.status.terminal }).count + plan.items.count <= 500 else { throw FlowError("QUEUE_FULL", "待处理任务超过 500 个。") }
        let beforeJobs = jobs; let beforeSubmissions = submissions
        let batch = UUID().uuidString
        let added = plan.items.map { item -> MediaJob in
            var job = MediaJob(input: item.input); job.info = item.info; job.fingerprint = item.fingerprint
            job.sourceClient = client; job.batchID = batch; job.settings = item.settings
            job.status = policy.requireApproval ? .awaitingApproval : .queued
            return job
        }
        let submission = Submission(client: client, key: key, planID: plan.id, batchID: batch, jobIDs: added.map(\.id))
        jobs += added; submissions.append(submission)
        do { try persist() } catch { jobs = beforeJobs; submissions = beforeSubmissions; throw error }
        paused = false; startWorker(); return submission
    }
}

private final class ProgressBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var parser = ProgressParser()
    func consume(_ text: String) -> [ProgressSnapshot] { lock.lock(); defer { lock.unlock() }; return parser.consume(text) }
}
