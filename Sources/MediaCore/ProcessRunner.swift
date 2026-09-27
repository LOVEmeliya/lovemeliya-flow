import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Launches executables directly, drains both pipes concurrently, and never invokes a shell.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        stop(current)
    }
    private func stop(_ current: Process?) {
        guard let current, current.isRunning else { return }
        current.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if current.isRunning { kill(current.processIdentifier, SIGKILL) }
        }
    }

    public func run(executable: URL, arguments: [String], timeout: TimeInterval? = nil, environment: [String: String]? = nil,
                    onOutput: @escaping @Sendable (String) -> Void = { _ in },
                    onError: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let task = Process(); let out = Pipe(); let err = Pipe()
                task.executableURL = executable; task.arguments = arguments
                task.standardOutput = out; task.standardError = err; task.standardInput = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                env["LC_ALL"] = "C"
                if let environment { env.merge(environment) { _, new in new } }
                task.environment = env
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                process = task
                do { try task.run(); lock.unlock() }
                catch { process = nil; lock.unlock(); continuation.resume(throwing: error); return }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak task] in
                        guard let self, let task, task.isRunning else { return }
                        self.lock.lock(); self.timedOut = true; self.lock.unlock(); self.stop(task)
                    }
                }
                let group = DispatchGroup()
                let stdout = DataBox(); let stderr = DataBox()
                for (pipe, storage, callback) in [(out, stdout, onOutput), (err, stderr, onError)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { group.leave() }
                        while true {
                            let data = pipe.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            storage.append(data); callback(String(decoding: data, as: UTF8.self))
                        }
                        try? pipe.fileHandleForReading.close()
                    }
                }
                task.waitUntilExit(); group.wait()
                lock.lock(); let wasCancelled = cancelled; let wasTimedOut = timedOut; process = nil; lock.unlock()
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
                else if wasTimedOut { continuation.resume(throwing: MediaFlowError.message("进程响应超时，请检查引擎或文件。")) }
                else { continuation.resume(returning: CommandResult(exitCode: task.terminationStatus, stdout: stdout.data, stderr: stderr.data)) }
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
    func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > 4 * 1024 * 1024 { data.removeFirst(data.count - 4 * 1024 * 1024) }
    }
}

public struct EngineInfo: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL
    public let version: String
    public let encoders: Set<String>
    public func supports(_ preset: Preset, hardware: Bool = false) -> Bool {
        if preset.isRemux { return true }
        let primary = hardware && [.mp4, .compact, .hevc].contains(preset)
            ? (preset == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox") : preset.encoder
        return encoders.contains(primary) && (preset.isAudio || encoders.contains(preset == .webm ? "libopus" : "aac"))
    }
}

public enum EngineService {
    // Restrict MCP inputs to self-contained local media demuxers, excluding playlists,
    // concat, subtitle sidecars, image sequences and network protocols.
    public static let localInputArguments = ["-protocol_whitelist", "file,pipe", "-format_whitelist", "mov,matroska,webm,avi,mpeg,mpegts,flv,asf,ogg,wav,aiff,caf,mp3,flac,aac,ac3,eac3,amr,au,wv,ape,mpc,mpc8"]
    public static func candidates(customPath: String?) -> [URL] {
        if let customPath, !customPath.isEmpty { return [URL(fileURLWithPath: customPath)] }
        var paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/ffmpeg" }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }
    public static func detect(customPath: String?) async throws -> EngineInfo {
        let fm = FileManager.default
        guard let executable = candidates(customPath: customPath).first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw MediaFlowError.message("尚未找到 FFmpeg。可以使用 Homebrew 安装，或选择已有的 ffmpeg 可执行文件。")
        }
        let probe = executable.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard fm.isExecutableFile(atPath: probe.path) else { throw MediaFlowError.message("同一目录中缺少 ffprobe，请选择完整的 FFmpeg 安装。") }
        let version = try await ProcessRunner().run(executable: executable, arguments: ["-version"], timeout: 10)
        guard version.exitCode == 0 else { throw MediaFlowError.message("FFmpeg 无法运行：\(version.errorText.suffix(600))") }
        let probeVersion = try await ProcessRunner().run(executable: probe, arguments: ["-version"], timeout: 10)
        guard probeVersion.exitCode == 0 else { throw MediaFlowError.message("ffprobe 无法运行，请检查安装。") }
        let result = try await ProcessRunner().run(executable: executable, arguments: ["-hide_banner", "-encoders"], timeout: 10)
        guard result.exitCode == 0 else { throw MediaFlowError.message("无法读取 FFmpeg 编码器列表。") }
        let encoders = Set(result.output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].count == 6, ["V", "A", "S"].contains(String(fields[0].prefix(1))), fields[1] != "=" else { return nil }
            return String(fields[1])
        })
        return EngineInfo(ffmpeg: executable, ffprobe: probe, version: String(version.output.split(separator: "\n").first ?? "FFmpeg"), encoders: encoders)
    }
    public static func probe(_ url: URL, engine: EngineInfo, restricted: Bool = false) async throws -> MediaInfo {
        let result = try await ProcessRunner().run(executable: engine.ffprobe, arguments: ["-v", "error"] + (restricted ? localInputArguments : []) + ["-show_format", "-show_streams", "-of", "json", url.path], timeout: 30)
        guard result.exitCode == 0 else { throw MediaFlowError.message("无法读取媒体：\(result.errorText.suffix(600))") }
        return try MediaInfo.decodeProbe(result.stdout)
    }
}
