import Foundation
import MediaCore

@MainActor
public final class ToolRouter {
    public let service: TaskService
    private var inspecting = false
    public init(service: TaskService) { self.service = service }
    public func handle(_ request: BridgeRequest) async -> BridgeResponse {
        let client = String(request.client.prefix(80))
        if request.name == "_disconnect" { service.clients.removeValue(forKey: request.session); return .success(.object([:])) }
        service.clients[request.session] = Date()
        service.clients = service.clients.filter { Date().timeIntervalSince($0.value) < 45 }
        if request.name == "_connect" { return .success(.object(["enabled": .bool(service.policy.enabled)])) }
        do {
            let value = try await call(request.name, arguments: request.arguments, client: client)
            service.record(client: client, tool: request.name, outcome: "成功")
            return .success(value)
        } catch {
            let error = error as? FlowError ?? FlowError("OPERATION_FAILED", String(error.localizedDescription.prefix(1500)))
            service.record(client: client, tool: request.name, outcome: error.code)
            return .failure(error)
        }
    }
    private func call(_ name: String, arguments: JSONValue, client: String) async throws -> JSONValue {
        guard let definition = ToolCatalog.definitions.first(where: { $0.name == name }) else { throw FlowError("UNKNOWN_TOOL", "未知工具。") }
        guard let args = arguments.object else { throw FlowError("INVALID_ARGUMENTS", "参数必须是对象。") }
        let allowed = Set(definition.inputSchema.object?["properties"]?.object?.keys.map { $0 } ?? [])
        guard Set(args.keys).isSubset(of: allowed) else { throw FlowError("INVALID_ARGUMENTS", "包含不支持的参数。") }
        if name == "flow_capabilities" {
            return .object([
                "app": .string("LOVEmeliya Flow"), "version": .string("1.1.0"), "enabled": .bool(service.policy.enabled),
                "execution_mode": .string(service.policy.requireApproval ? "confirmation" : "direct"),
                "read_directories": try .from(service.policy.readDirectories), "write_directories": try .from(service.policy.writeDirectories),
                "engine": service.engine.map { .string($0.version) } ?? .null,
                "presets": .array(Preset.allCases.map { .object(["id": .string($0.rawValue), "description": .string($0.subtitle), "available": .bool(service.engine?.supports($0) ?? false), "hardware_available": .bool([.mp4, .compact, .hevc].contains($0) && (service.engine?.supports($0, hardware: true) ?? false))]) }),
                "max_batch_size": .number(20), "supports_target_size": .bool(false), "supports_hdr_transcode": .bool(false),
                "notes": .string("Local self-contained media only. No shell commands, URLs, playlists, subtitle burning, joining or engine updates. Output never overwrites. Paths/metadata are returned to the connected AI client. Use flow_plan then flow_submit; query using job IDs.")
            ])
        }
        guard service.policy.enabled else { throw FlowError("MCP_DISABLED", "请在 APP 的“AI 接入”页面启用 MCP 并授权目录。") }
        switch name {
        case "flow_inspect":
            guard !inspecting, !service.maintenance else { throw FlowError("BUSY", "正在检查媒体或维护引擎，请稍后重试。") }
            let url = try service.policy.input(requiredString(args, "path"))
            let engine = try requireEngine(); inspecting = true; defer { inspecting = false }
            let info = try await EngineService.probe(url, engine: engine, restricted: true)
            guard service.policy.enabled else { throw FlowError("MCP_DISABLED", "AI 接入已关闭。") }
            _ = try service.policy.input(url.path)
            return .object(["path": .string(url.path), "media": try .from(info)])
        case "flow_plan": return try await makePlan(args, client: client)
        case "flow_submit":
            let planID = try requiredString(args, "plan_id"); let key = try requiredString(args, "request_id")
            guard key.count <= 128 else { throw FlowError("INVALID_ARGUMENTS", "request_id 最长 128 字符。") }
            if let previous = service.submissions.first(where: { $0.client == client && $0.key == key }) {
                guard previous.planID == planID else { throw FlowError("IDEMPOTENCY_CONFLICT", "request_id 已用于其他方案。") }
                return submissionResult(previous, duplicate: true)
            }
            if let previous = service.submissions.first(where: { $0.client == client && $0.planID == planID }) { return submissionResult(previous, duplicate: true) }
            guard let plan = service.plans.first(where: { $0.id == planID && $0.client == client }) else { throw FlowError("PLAN_NOT_FOUND", "找不到方案，请重新调用 flow_plan。") }
            return submissionResult(try service.submit(plan: plan, key: key, client: client), duplicate: false)
        case "flow_get_job":
            let job = try lookup(requiredString(args, "job_id"))
            return try jobResult(job, includeLog: optionalBool(args, "include_log") ?? false)
        case "flow_list_jobs":
            let offset = try optionalInteger(args, "offset", range: 0...Int.max) ?? 0
            let limit = try optionalInteger(args, "limit", range: 1...100) ?? 25
            let source = try optionalString(args, "source") ?? "ai"
            guard ["ai", "manual", "all"].contains(source) else { throw FlowError("INVALID_ARGUMENTS", "无效的 source。") }
            let status = try optionalString(args, "status"); let batch = try optionalString(args, "batch_id")
            if let status, JobStatus(rawValue: status) == nil { throw FlowError("INVALID_ARGUMENTS", "无效状态。") }
            let all = service.jobs.filter { visible($0) && (source == "all" || (source == "ai" ? $0.isAI : !$0.isAI)) && (status == nil || $0.status.rawValue == status) && (batch == nil || $0.batchID == batch) }
            let page = Array(all.dropFirst(min(offset, all.count)).prefix(limit))
            let next = min(offset, all.count) + page.count
            return .object(["jobs": .array(try page.map { try jobResult($0) }), "total": .number(Double(all.count)), "next_offset": next < all.count ? .number(Double(next)) : .null])
        case "flow_cancel":
            let id = try optionalString(args, "job_id"); let batch = try optionalString(args, "batch_id")
            guard (id != nil) != (batch != nil) else { throw FlowError("INVALID_ARGUMENTS", "请只指定 job_id 或 batch_id。") }
            let jobs: [MediaJob]
            if let id { jobs = [try lookup(id)] }
            else { jobs = service.jobs.filter { $0.batchID == batch && visible($0) }; guard !jobs.isEmpty else { throw FlowError("JOB_NOT_FOUND", "找不到此批次。") } }
            guard jobs.allSatisfy(\.isAI) else { throw FlowError("MANUAL_JOB_PROTECTED", "MCP 不能取消手动任务。") }
            service.cancel(jobs.map(\.id))
            return .object(["job_ids": .array(jobs.map { .string($0.id.uuidString) }), "message": .string("已请求取消。运行中的任务清理后会变为 cancelled；已结束的任务保持原状态。")])
        default: throw FlowError("UNKNOWN_TOOL", "未知工具。")
        }
    }
    private func makePlan(_ args: [String: JSONValue], client: String) async throws -> JSONValue {
        guard !inspecting, !service.maintenance else { throw FlowError("BUSY", "正在检查媒体或维护引擎，请稍后重试。") }
        guard let items = args["inputs"]?.array, (1...20).contains(items.count), items.allSatisfy({ $0.string != nil }) else { throw FlowError("INVALID_ARGUMENTS", "inputs 必须包含 1–20 个文件路径。") }
        let inputs = try items.map { try service.policy.input($0.string!) }
        guard Set(inputs.map(\.path)).count == inputs.count else { throw FlowError("DUPLICATE_INPUT", "一个方案中不能重复添加同一个文件。") }
        let output = try service.policy.outputDirectory(requiredString(args, "output_directory"))
        var settings = ConversionSettings()
        guard let preset = Preset(rawValue: try requiredString(args, "preset")) else { throw FlowError("INVALID_ARGUMENTS", "无效预设。") }; settings.preset = preset
        if let quality = try optionalString(args, "quality") { guard let value = Quality(rawValue: quality) else { throw FlowError("INVALID_ARGUMENTS", "无效质量。") }; settings.quality = value }
        if let resolution = try optionalString(args, "resolution") { guard let value = Resolution(rawValue: resolution) else { throw FlowError("INVALID_ARGUMENTS", "无效尺寸。") }; settings.resolution = value }
        settings.hardware = try optionalBool(args, "hardware") ?? false
        settings.includeAudio = try optionalBool(args, "include_audio") ?? true
        if let start = try optionalNumber(args, "start_seconds") { settings.startTime = String(start) }
        if let end = try optionalNumber(args, "end_seconds") { settings.endTime = String(end) }
        if let existing = try optionalString(args, "existing_file"), existing != "rename" { throw FlowError("INVALID_ARGUMENTS", "仅支持 rename，不允许覆盖。") }
        settings.outputDirectory = output.path
        let audio: [String: JSONValue]
        if let value = args["audio"] { guard let a = value.object, Set(a.keys).isSubset(of: ["sample_rate", "channels"]) else { throw FlowError("INVALID_ARGUMENTS", "无效音频参数。") }; audio = a } else { audio = [:] }
        let sourceRate = audio["sample_rate"] == .string("source"); let sourceChannels = audio["channels"] == .string("source")
        if let rate = audio["sample_rate"], !sourceRate { guard let n = rate.number, [8000,16000,22050,24000,32000,44100,48000,96000].contains(n) else { throw FlowError("INVALID_ARGUMENTS", "不支持的采样率。") }; settings.sampleRate = Int(n) }
        if let channels = audio["channels"], !sourceChannels { guard let n = channels.number, [1,2,6,8].contains(n) else { throw FlowError("INVALID_ARGUMENTS", "不支持的声道数。") }; settings.channels = Int(n) }
        if preset.isRemux && (!audio.isEmpty || settings.hardware || settings.resolution != .source || !settings.includeAudio || args["quality"] != nil) { throw FlowError("INVALID_ARGUMENTS", "换封装不能修改音频、画质、尺寸或使用硬件转码。") }
        if preset.isAudio && (settings.hardware || settings.resolution != .source || !settings.includeAudio) { throw FlowError("INVALID_ARGUMENTS", "音频预设不能使用视频选项。") }
        if preset == .webm && settings.hardware { throw FlowError("INVALID_ARGUMENTS", "WebM 暂不支持硬件编码。") }
        let engine = try requireEngine()
        guard engine.supports(preset, hardware: settings.hardware) else { throw FlowError("ENCODER_UNAVAILABLE", "引擎缺少编码器。") }
        inspecting = true; defer { inspecting = false }
        var planned: [PlannedItem] = []; var reserved = Set<String>()
        for input in inputs {
            var itemSettings = settings
            let fingerprint = try FileFingerprint(input)
            let info = try await EngineService.probe(input, engine: engine, restricted: true)
            guard service.policy.enabled else { throw FlowError("MCP_DISABLED", "AI 接入已关闭。") }
            _ = try service.policy.input(input.path); _ = try service.policy.outputDirectory(output.path)
            guard try FileFingerprint(input) == fingerprint else { throw FlowError("SOURCE_CHANGED", "读取期间源文件发生变化。") }
            if sourceRate { guard let value = info.sampleRate else { throw FlowError("NO_AUDIO_STREAM", "无法读取来源采样率。") }; itemSettings.sampleRate = value }
            if sourceChannels { guard let value = info.channels else { throw FlowError("NO_AUDIO_STREAM", "无法读取来源声道数。") }; itemSettings.channels = value }
            if preset == .mp3, let channels = itemSettings.channels, channels > 2 { throw FlowError("INVALID_ARGUMENTS", "MP3 最多支持双声道。") }
            if preset == .mp3, let rate = itemSettings.sampleRate, ![8000,16000,22050,24000,32000,44100,48000].contains(rate) { throw FlowError("INVALID_ARGUMENTS", "MP3 不支持指定采样率。") }
            if preset == .webm, let rate = itemSettings.sampleRate, ![8000,16000,24000,48000].contains(rate) { throw FlowError("INVALID_ARGUMENTS", "Opus 不支持指定采样率。") }
            if preset.isAudio && info.audioCodec == nil { throw FlowError("NO_AUDIO_STREAM", "源文件没有音轨。") }
            if !preset.isAudio && info.videoCodec == nil { throw FlowError("NO_VIDEO_STREAM", "源文件没有视频。") }
            if info.isHDR && !preset.isAudio && !preset.isRemux { throw FlowError("HDR_UNSUPPORTED", "暂不支持 HDR 转码，可选择换封装。") }
            let destination = try CommandBuilder.uniqueOutput(input: input, settings: settings, createDirectory: false, reserved: reserved)
            _ = try CommandBuilder.make(input: input, info: info, settings: itemSettings, output: destination, temporary: CommandBuilder.temporaryURL(for: destination), restricted: true)
            reserved.insert(destination.path); planned.append(PlannedItem(input: input, info: info, fingerprint: fingerprint, expectedOutput: destination, settings: itemSettings))
        }
        let plan = FlowPlan(id: UUID().uuidString, client: client, items: planned, settings: settings, expiresAt: Date().addingTimeInterval(900))
        try service.storePlan(plan)
        return .object(["plan_id": .string(plan.id), "expires_at": .string(ISO8601DateFormatter().string(from: plan.expiresAt)), "requires_confirmation": .bool(service.policy.requireApproval), "settings": try .from(settings), "files": .array(try planned.map { .object(["input": .string($0.input.path), "expected_output": .string($0.expectedOutput.path), "media": try .from($0.info), "settings": try .from($0.settings)]) }), "notes": .string("输出名为预览；执行时如有新同名文件会自动编号。视频转码不输出字幕；默认 AAC/MP3 为双声道，MP3 默认为 44100 Hz，WAV/FLAC 保持来源。")])
    }
    private func requireEngine() throws -> EngineInfo { guard let engine = service.engine else { throw FlowError("ENGINE_UNAVAILABLE", "引擎尚未就绪，请在 APP 中配置或稍后重试。") }; return engine }
    private func visible(_ job: MediaJob) -> Bool { (try? service.policy.input(job.input.path)) != nil && (job.output == nil || (try? service.policy.outputDirectory(job.output!.deletingLastPathComponent().path)) != nil) }
    private func lookup(_ id: String) throws -> MediaJob { guard let uuid = UUID(uuidString: id), let job = service.jobs.first(where: { $0.id == uuid }), visible(job) else { throw FlowError("JOB_NOT_FOUND", "任务不存在或不在授权目录内。") }; return job }
    private func jobResult(_ job: MediaJob, includeLog: Bool = false) throws -> JSONValue {
        var result: [String: JSONValue] = ["job_id": .string(job.id.uuidString), "batch_id": job.batchID.map(JSONValue.string) ?? .null, "source": .string(job.isAI ? "ai" : "manual"), "client": job.sourceClient.map(JSONValue.string) ?? .null, "input": .string(job.input.path), "status": .string(job.status.rawValue), "progress": .number(job.progress), "speed": .number(job.speed), "eta_seconds": job.eta.map(JSONValue.number) ?? .null, "output_path": job.output.map { .string($0.path) } ?? .null, "output_bytes": job.outputBytes.map { .number(Double($0)) } ?? .null, "output_media": try .from(job.outputInfo), "settings": try .from(job.settings), "error": job.error.map { .object(["code": .string(job.errorCode ?? "ERROR"), "message": .string(String($0.prefix(1500)))]) } ?? .null]
        if includeLog { result["log"] = .string(String(job.log.suffix(8000))) }; return .object(result)
    }
    private func submissionResult(_ submission: Submission, duplicate: Bool) -> JSONValue { .object(["batch_id": .string(submission.batchID), "job_ids": .array(submission.jobIDs.map { .string($0.uuidString) }), "duplicate": .bool(duplicate), "message": .string("任务已保存。请用 flow_get_job 或 flow_list_jobs 查询；awaitingApproval 表示需要在 APP 中确认。")]) }
}

private func requiredString(_ args: [String: JSONValue], _ key: String) throws -> String {
    guard let value = args[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 4096 else { throw FlowError("INVALID_ARGUMENTS", "\(key) 必须是非空字符串。") }; return value
}
private func optionalString(_ args: [String: JSONValue], _ key: String) throws -> String? { guard args[key] != nil else { return nil }; return try requiredString(args, key) }
private func optionalBool(_ args: [String: JSONValue], _ key: String) throws -> Bool? { guard let value = args[key] else { return nil }; guard let boolean = value.bool else { throw FlowError("INVALID_ARGUMENTS", "\(key) 必须是布尔值。") }; return boolean }
private func optionalNumber(_ args: [String: JSONValue], _ key: String) throws -> Double? { guard let value = args[key] else { return nil }; guard let number = value.number, number.isFinite, number >= 0, number <= 1e10 else { throw FlowError("INVALID_ARGUMENTS", "\(key) 必须是有效非负数。") }; return number }
private func optionalInteger(_ args: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int? { guard let value = try optionalNumber(args, key) else { return nil }; guard value.rounded() == value, value < Double(Int.max), range.contains(Int(value)) else { throw FlowError("INVALID_ARGUMENTS", "\(key) 超出整数范围。") }; return Int(value) }
