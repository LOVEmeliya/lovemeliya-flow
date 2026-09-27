import Foundation
import MediaCore

public struct ToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
}
public enum ToolCatalog {
    public static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    public static func string(_ description: String, values: [String]? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { p["enum"] = .array(values.map(JSONValue.string)) }; return .object(p)
    }
    public static let definitions: [ToolDefinition] = {
        let path = string("Absolute local file path inside an authorized read directory. No URLs, folders or playlists.")
        let id = string("UUID returned by Flow.")
        let bool: JSONValue = .object(["type": .string("boolean")])
        let seconds: JSONValue = .object(["type": .string("number"), "minimum": .number(0), "description": .string("Non-negative time in seconds.")])
        let audio = object([
            "sample_rate": .object(["enum": .array([.string("source"), .number(8000), .number(16000), .number(22050), .number(24000), .number(32000), .number(44100), .number(48000), .number(96000)])]),
            "channels": .object(["enum": .array([.string("source"), .number(1), .number(2), .number(6), .number(8)])])
        ])
        return [
            .init(name: "flow_capabilities", description: "Read Flow version, engine/preset availability, directory permissions and execution policy. Call first. Available even when MCP is disabled. No media file contents are returned.", inputSchema: object([:]), readOnly: true),
            .init(name: "flow_inspect", description: "Inspect one authorized local media file. Returns duration, codecs, dimensions, sample rate, channels and HDR flag. Does not transcribe or upload media.", inputSchema: object(["path": path], required: ["path"]), readOnly: true),
            .init(name: "flow_plan", description: "Validate up to 20 explicitly specified input files and return a persisted conversion plan valid for 15 minutes. Does not convert or create output files. Re-run if source changed. WAV/FLAC default to source sample rate and channels. Other audio defaults are described in the returned settings.", inputSchema: object([
                "inputs": .object(["type": .string("array"), "items": path, "minItems": .number(1), "maxItems": .number(20)]),
                "preset": string("Supported preset.", values: Preset.allCases.map(\.rawValue)),
                "quality": string("Default balanced.", values: Quality.allCases.map(\.rawValue)),
                "resolution": string("source/fullHD/hd/sd. Video only.", values: Resolution.allCases.map(\.rawValue)),
                "hardware": bool, "include_audio": bool, "start_seconds": seconds, "end_seconds": seconds,
                "audio": audio, "output_directory": string("Existing authorized writable directory; required."),
                "existing_file": string("Output collisions always get numbered; overwriting is unsupported.", values: ["rename"])
            ], required: ["inputs", "preset", "output_directory"]), readOnly: false),
            .init(name: "flow_submit", description: "Submit a plan into the shared APP queue. Returns immediately with batch_id and job_ids. Use a stable request_id on retries to avoid duplicate conversions. GUI confirmation may be required. AI disconnect does not cancel submitted jobs.", inputSchema: object(["plan_id": id, "request_id": string("Unique request key, 1–128 characters. Reuse only for retrying the same plan.")], required: ["plan_id", "request_id"]), readOnly: false),
            .init(name: "flow_get_job", description: "Get a job's status, progress, output path, actual output metadata and structured error. include_log returns at most the last 8000 characters. Poll every 2–5 seconds rather than continuously.", inputSchema: object(["job_id": id, "include_log": bool], required: ["job_id"]), readOnly: true),
            .init(name: "flow_list_jobs", description: "List authorized jobs with bounded pagination. Default source is ai; manual jobs can be viewed but cannot be cancelled through MCP. next_offset is null at the end.", inputSchema: object([
                "batch_id": id, "source": string("Job source filter.", values: ["ai", "manual", "all"]),
                "status": string("Optional job state.", values: ["ready", "awaitingApproval", "queued", "probing", "running", "completed", "failed", "cancelled"]),
                "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])
            ]), readOnly: true),
            .init(name: "flow_cancel", description: "Cancel exactly one AI-created job or batch; supply job_id OR batch_id. Never deletes finished files, cancels manual jobs or stops unrelated batches.", inputSchema: object(["job_id": id, "batch_id": id]), readOnly: false)
        ]
    }()
}
