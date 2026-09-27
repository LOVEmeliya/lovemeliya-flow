import Foundation

public enum MediaFlowError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum Preset: String, CaseIterable, Codable, Identifiable, Sendable {
    case mp4, compact, hevc, webm, mp3, m4a, wav, flac, remuxMP4, remuxMKV
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mp4: return "MP4 · 通用视频"
        case .compact: return "MP4 · 轻量压缩"
        case .hevc: return "HEVC · 高效视频"
        case .webm: return "WebM · 网页视频"
        case .mp3: return "MP3 · 通用音频"
        case .m4a: return "M4A · 高效音频"
        case .wav: return "WAV · 无压缩音频"
        case .flac: return "FLAC · 无损音频"
        case .remuxMP4: return "MP4 · 仅换封装"
        case .remuxMKV: return "MKV · 仅换封装"
        }
    }
    public var subtitle: String {
        switch self {
        case .mp4: return "H.264 + AAC，适合播放、分享和日常保存。"
        case .compact: return "更小的 H.264 视频，默认限制在 1080p 以内。"
        case .hevc: return "H.265 + AAC，节省空间；旧设备兼容性较弱。"
        case .webm: return "VP9 + Opus，适合网页使用，软件编码较慢。"
        case .mp3: return "从视频提取声音，或将音频转换为 MP3。"
        case .m4a: return "AAC 音频，兼顾体积与音质。"
        case .wav: return "16-bit PCM，适合音频编辑；文件较大。"
        case .flac: return "无损压缩，不会恢复原文件已经损失的音质。"
        case .remuxMP4: return "复制音视频流，不重新编码；编码须兼容 MP4。"
        case .remuxMKV: return "复制音视频与字幕流，不重新编码。"
        }
    }
    public var isAudio: Bool { [.mp3, .m4a, .wav, .flac].contains(self) }
    public var isRemux: Bool { [.remuxMP4, .remuxMKV].contains(self) }
    public var fileExtension: String {
        switch self {
        case .mp4, .compact, .hevc, .remuxMP4: return "mp4"
        case .remuxMKV: return "mkv"
        default: return rawValue
        }
    }
    public var icon: String { isAudio ? "waveform" : isRemux ? "shippingbox" : "film" }
    public var encoder: String {
        switch self {
        case .mp4, .compact: return "libx264"
        case .hevc: return "libx265"
        case .webm: return "libvpx-vp9"
        case .mp3: return "libmp3lame"
        case .m4a: return "aac"
        case .wav: return "pcm_s16le"
        case .flac: return "flac"
        case .remuxMP4, .remuxMKV: return "copy"
        }
    }
}

public enum Quality: String, CaseIterable, Codable, Sendable {
    case small, balanced, high
    public var title: String { switch self { case .small: return "体积优先"; case .balanced: return "均衡"; case .high: return "画质 / 音质优先" } }
    public var crf: Int { switch self { case .small: return 28; case .balanced: return 23; case .high: return 18 } }
    public var audioBitrate: String { switch self { case .small: return "128k"; case .balanced: return "192k"; case .high: return "256k" } }
}

public enum Resolution: String, CaseIterable, Codable, Sendable {
    case source, fullHD, hd, sd
    public var title: String { switch self { case .source: return "保持原尺寸"; case .fullHD: return "最大 1920 × 1080"; case .hd: return "最大 1280 × 720"; case .sd: return "最大 854 × 480" } }
    public var filter: String {
        let size: (Int, Int)
        switch self {
        case .source: return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        case .fullHD: size = (1920, 1080)
        case .hd: size = (1280, 720)
        case .sd: size = (854, 480)
        }
        return "scale=w='min(\(size.0),iw)':h='min(\(size.1),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    }
}

public struct ConversionSettings: Codable, Equatable, Sendable {
    public var preset: Preset = .mp4
    public var quality: Quality = .balanced
    public var resolution: Resolution = .source
    public var hardware = false
    public var includeAudio = true
    public var startTime = ""
    public var endTime = ""
    public var outputDirectory: String?
    public var sampleRate: Int?
    public var channels: Int?
    public init() {}
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public var duration: Double
    public var bytes: Int64
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var videoIndex: Int?
    public var isHDR: Bool
    public var sampleRate: Int?
    public var channels: Int?
    public init(duration: Double = 0, bytes: Int64 = 0, videoCodec: String? = nil, audioCodec: String? = nil, width: Int? = nil, height: Int? = nil, videoIndex: Int? = nil, isHDR: Bool = false) {
        self.duration = duration; self.bytes = bytes; self.videoCodec = videoCodec; self.audioCodec = audioCodec
        self.width = width; self.height = height; self.videoIndex = videoIndex; self.isHDR = isHDR
    }
    public static func decodeProbe(_ data: Data) throws -> MediaInfo {
        struct Probe: Decodable {
            struct Stream: Decodable {
                var index: Int; var codec_type: String?; var codec_name: String?
                var width: Int?; var height: Int?; var duration: String?; var color_transfer: String?
                var sample_rate: String?; var channels: Int?
                struct Disposition: Decodable { var attached_pic: Int? }
                var disposition: Disposition?
            }
            struct Format: Decodable { var duration: String?; var size: String? }
            var streams: [Stream]?; var format: Format?
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        let streams = probe.streams ?? []
        let video = streams.first { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }
        let audio = streams.first { $0.codec_type == "audio" }
        guard video != nil || audio != nil else { throw MediaFlowError.message("未找到可处理的音视频流。") }
        let rawDuration = Double(probe.format?.duration ?? "") ?? streams.compactMap { Double($0.duration ?? "") }.max() ?? 0
        var info = MediaInfo(duration: rawDuration.isFinite ? max(0, rawDuration) : 0, bytes: Int64(probe.format?.size ?? "") ?? 0,
                         videoCodec: video?.codec_name, audioCodec: audio?.codec_name, width: video?.width, height: video?.height,
                         videoIndex: video?.index, isHDR: ["smpte2084", "arib-std-b67"].contains(video?.color_transfer ?? ""))
        info.sampleRate = audio?.sample_rate.flatMap(Int.init); info.channels = audio?.channels
        return info
    }
}

public enum Timecode {
    public static func parse(_ text: String) throws -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return nil }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { throw MediaFlowError.message("时间格式应为秒数或 HH:MM:SS，例如 90 或 00:01:30。") }
        var result: Double = 0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value.isFinite, value >= 0,
                  (parts.count == 1 || index == 0 || value < 60),
                  (index == parts.count - 1 || value.rounded(.down) == value) else {
                throw MediaFlowError.message("时间无效，请使用非负秒数或 HH:MM:SS。")
            }
            result = result * 60 + value
        }
        guard result.isFinite else { throw MediaFlowError.message("时间超出有效范围。") }
        return result
    }
    public static func display(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "—" }
        let total = Int(min(seconds, Double(Int.max / 2)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
