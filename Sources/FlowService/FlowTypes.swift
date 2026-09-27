import Foundation
import MediaCore

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
}

public struct FlowError: LocalizedError, Codable, Sendable {
    public var code: String
    public var message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public struct BridgeRequest: Codable, Sendable {
    public var name: String
    public var arguments: JSONValue
    public var client: String
    public var session: String
    public init(name: String, arguments: JSONValue, client: String, session: String) { self.name = name; self.arguments = arguments; self.client = client; self.session = session }
}
public struct BridgeResponse: Codable, Sendable {
    public var ok: Bool
    public var data: JSONValue?
    public var error: FlowError?
    public static func success(_ data: JSONValue) -> Self { Self(ok: true, data: data, error: nil) }
    public static func failure(_ error: Error) -> Self {
        Self(ok: false, data: nil, error: error as? FlowError ?? FlowError("INTERNAL_ERROR", String(error.localizedDescription.prefix(1500))))
    }
}

public enum JobStatus: String, Codable, Sendable {
    case ready, awaitingApproval, queued, probing, running, completed, failed, cancelled
    public var title: String {
        switch self { case .ready: return "待转换"; case .awaitingApproval: return "待确认"; case .queued: return "已排队"; case .probing: return "读取中"; case .running: return "转换中"; case .completed: return "已完成"; case .failed: return "转换失败"; case .cancelled: return "已取消" }
    }
    public var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
}

public struct MediaJob: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var input: URL
    public var info: MediaInfo?
    public var status: JobStatus = .ready
    public var progress = 0.0
    public var speed = 0.0
    public var eta: Double?
    public var output: URL?
    public var outputBytes: Int64?
    public var error: String?
    public var log = ""
    public var settings: ConversionSettings?
    public var createdAt = Date()
    public var sourceClient: String?
    public var batchID: String?
    public var errorCode: String?
    public var outputInfo: MediaInfo?
    public var fingerprint: FileFingerprint?
    public var isAI: Bool { sourceClient != nil }
    public init(input: URL) { self.input = input }
}

public struct FileFingerprint: Codable, Equatable, Sendable {
    public var bytes: Int64
    public var modified: Date
    public var inode: UInt64
    public init(_ url: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        bytes = (a[.size] as? NSNumber)?.int64Value ?? 0
        modified = a[.modificationDate] as? Date ?? .distantPast
        inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

public struct AccessPolicy: Codable, Equatable, Sendable {
    public var enabled = false
    public var requireApproval = true
    public var readDirectories: [String] = []
    public var writeDirectories: [String] = []
    public init() {}
    public func input(_ path: String) throws -> URL {
        let url = try permitted(path, roots: readDirectories)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw FlowError("INVALID_INPUT", "请指定一个现有的普通媒体文件。") }
        return url
    }
    public func outputDirectory(_ path: String) throws -> URL {
        let url = try permitted(path, roots: writeDirectories)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path) else { throw FlowError("INVALID_OUTPUT_DIRECTORY", "输出目录必须存在且可写。请在 APP 中选择或创建目录。") }
        return url
    }
    private func permitted(_ path: String, roots: [String]) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw FlowError("INVALID_PATH", "文件路径必须是绝对本地路径。") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = roots.contains { root in
            let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return url.path == base || url.path.hasPrefix(base == "/" ? "/" : base + "/")
        }
        guard allowed else { throw FlowError("ACCESS_DENIED", "路径不在 APP 的授权目录内，请在“AI 接入”中授权。") }
        return url
    }
}

public struct PlannedItem: Codable, Sendable {
    public var input: URL
    public var info: MediaInfo
    public var fingerprint: FileFingerprint
    public var expectedOutput: URL
    public var settings: ConversionSettings
}
public struct FlowPlan: Codable, Sendable {
    public var id: String
    public var client: String
    public var items: [PlannedItem]
    public var settings: ConversionSettings
    public var expiresAt: Date
}
public struct Submission: Codable, Sendable {
    public var client: String
    public var key: String
    public var planID: String
    public var batchID: String
    public var jobIDs: [UUID]
}
public struct AuditEntry: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var client: String
    public var tool: String
    public var outcome: String
}
public enum FlowPaths {
    public static var support: URL {
        if let path = ProcessInfo.processInfo.environment["FLOW_SUPPORT_DIRECTORY"], path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaFlow", isDirectory: true)
    }
}
