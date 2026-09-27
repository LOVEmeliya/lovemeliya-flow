import Foundation

public struct ConversionPlan: Sendable {
    public let arguments: [String]
    public let expectedDuration: Double
    public let outputURL: URL
    public let temporaryURL: URL
}

public enum CommandBuilder {
    public static func make(input: URL, info: MediaInfo, settings: ConversionSettings, output: URL, temporary: URL, restricted: Bool = false) throws -> ConversionPlan {
        let preset = settings.preset
        guard input.standardizedFileURL != output.standardizedFileURL, input.standardizedFileURL != temporary.standardizedFileURL else {
            throw MediaFlowError.message("输出路径不能与源文件相同。")
        }
        if preset.isAudio && info.audioCodec == nil { throw MediaFlowError.message("这个文件没有音轨，无法导出音频。") }
        if !preset.isAudio && info.videoCodec == nil { throw MediaFlowError.message("这个文件没有视频画面，请选择音频预设。") }
        if info.isHDR && !preset.isAudio && !preset.isRemux {
            throw MediaFlowError.message("检测到 HDR 视频。第一版暂不进行 HDR 色调映射，请选择“仅换封装”以保留原始色彩。")
        }
        let start = try Timecode.parse(settings.startTime) ?? 0
        let end = try Timecode.parse(settings.endTime)
        if info.duration > 0 && start >= info.duration { throw MediaFlowError.message("开始时间已经超出文件时长。") }
        if let end, end <= start { throw MediaFlowError.message("结束时间必须晚于开始时间。") }
        if let end, info.duration > 0 && end > info.duration + 0.05 { throw MediaFlowError.message("结束时间已经超出文件时长。") }
        if preset.isRemux && (start > 0 || end != nil) { throw MediaFlowError.message("精确截取需要重新编码，请切换到视频或音频转换预设。") }
        let duration = max(0, (end ?? info.duration) - start)
        var args = ["-hide_banner", "-nostdin", "-n", "-progress", "pipe:1", "-nostats"]
        if restricted { args += EngineService.localInputArguments }
        if start > 0 { args += ["-ss", String(start)] }
        args += ["-i", input.path]
        if let end { args += ["-t", String(end - start)] }
        if preset.isAudio {
            args += ["-map", "0:a:0", "-vn", "-sn", "-c:a", preset.encoder]
            if preset == .mp3 || preset == .m4a { args += ["-b:a", settings.quality.audioBitrate, "-ac", String(settings.channels ?? 2)] }
            else if let channels = settings.channels { args += ["-ac", String(channels)] }
            if let rate = settings.sampleRate { args += ["-ar", String(rate)] }
            else if preset == .mp3 { args += ["-ar", "44100"] }
            if preset == .mp3 { args += ["-id3v2_version", "3"] }
        } else if preset.isRemux {
            args += ["-map", "0:v?", "-map", "0:a?"]
            if preset == .remuxMKV { args += ["-map", "0:s?", "-map", "0:t?"] }
            args += ["-c", "copy"]
        } else {
            args += ["-map", info.videoIndex.map { "0:\($0)" } ?? "0:v:0"]
            if settings.includeAudio { args += ["-map", "0:a?"] }
            args += ["-sn"]
            let hardware = settings.hardware && [.mp4, .compact, .hevc].contains(preset)
            let encoder = hardware ? (preset == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox") : preset.encoder
            args += ["-c:v", encoder]
            if hardware {
                let quality = settings.quality == .high ? "75" : settings.quality == .small ? "40" : "60"
                args += ["-q:v", preset == .compact ? "40" : quality, "-allow_sw", "0"]
            } else if preset == .webm {
                args += ["-crf", String(settings.quality.crf + 9), "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "3"]
            } else {
                args += ["-crf", String(settings.quality.crf + (preset == .compact ? 5 : 0)), "-preset", "medium"]
            }
            let resolution: Resolution = preset == .compact && settings.resolution == .source ? .fullHD : settings.resolution
            args += ["-vf", resolution.filter, "-pix_fmt", "yuv420p"]
            if preset == .hevc { args += ["-tag:v", "hvc1"] }
            if settings.includeAudio {
                args += ["-c:a", preset == .webm ? "libopus" : "aac", "-b:a", settings.quality.audioBitrate, "-ac", String(settings.channels ?? 2)]
                if let rate = settings.sampleRate { args += ["-ar", String(rate)] }
            }
        }
        args += ["-map_metadata", "0"]
        if preset.fileExtension == "mp4" || preset == .m4a { args += ["-movflags", "+faststart"] }
        args.append(temporary.path)
        return ConversionPlan(arguments: args, expectedDuration: duration, outputURL: output, temporaryURL: temporary)
    }

    public static func uniqueOutput(input: URL, settings: ConversionSettings, createDirectory: Bool = true, reserved: Set<String> = []) throws -> URL {
        let directory = settings.outputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? input.deletingLastPathComponent().appendingPathComponent("LOVEmeliya Flow 输出", isDirectory: true)
        if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let stem = input.deletingPathExtension().lastPathComponent
        for index in 0...9999 {
            let suffix = index == 0 ? "" : "_\(index + 1)"
            let url = directory.appendingPathComponent(stem + suffix).appendingPathExtension(settings.preset.fileExtension)
            if !FileManager.default.fileExists(atPath: url.path) && !reserved.contains(url.path) { return url }
        }
        throw MediaFlowError.message("输出目录存在过多重名文件，请更换目录。")
    }
    public static func temporaryURL(for output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(".mediaflow-\(UUID().uuidString)").appendingPathExtension(output.pathExtension)
    }
    public static func displayCommand(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
    }
}

public struct ProgressParser: Sendable {
    private var remainder = ""
    private var values: [String: String] = [:]
    public init() {}
    public mutating func consume(_ chunk: String) -> [ProgressSnapshot] {
        remainder += chunk
        var snapshots: [ProgressSnapshot] = []
        while let newline = remainder.firstIndex(of: "\n") {
            let line = String(remainder[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            remainder.removeSubrange(...newline)
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
            if parts.first == "progress" {
                let seconds = Double(values["out_time_us"] ?? "").map { max(0, $0 / 1_000_000) } ?? 0
                let speed = Double((values["speed"] ?? "").replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                snapshots.append(ProgressSnapshot(seconds: seconds, speed: speed, ended: parts.last == "end"))
            }
        }
        return snapshots
    }
}

public struct ProgressSnapshot: Sendable {
    public let seconds: Double
    public let speed: Double
    public let ended: Bool
}
