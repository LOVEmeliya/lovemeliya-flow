import XCTest
@testable import MediaCore

final class MediaCoreTests: XCTestCase {
    let input = URL(fileURLWithPath: "/tmp/含 空格 ' $() ; 源视频.mov")
    let output = URL(fileURLWithPath: "/tmp/MediaFlow-test-output.mp4")
    let temporary = URL(fileURLWithPath: "/tmp/.MediaFlow-test-partial.mp4")
    let info = MediaInfo(duration: 120, bytes: 10000, videoCodec: "h264", audioCodec: "aac", width: 1920, height: 1080, videoIndex: 2)

    func testTimecodeFormsAndInvalidValues() throws {
        XCTAssertNil(try Timecode.parse(" "))
        XCTAssertEqual(try Timecode.parse("90.5"), 90.5)
        XCTAssertEqual(try Timecode.parse("01:02:03.25"), 3723.25)
        XCTAssertEqual(try Timecode.parse("02:30"), 150)
        for value in ["-1", "nan", "inf", "1:60", "1::2", "1.5:20", "1:2:3:4"] { XCTAssertThrowsError(try Timecode.parse(value), value) }
    }
    func testSafeArgumentBoundariesAndVideoStreamMapping() throws {
        let plan = try CommandBuilder.make(input: input, info: info, settings: ConversionSettings(), output: output, temporary: temporary)
        XCTAssertTrue(plan.arguments.contains(input.path))
        XCTAssertEqual(plan.arguments.last, temporary.path)
        XCTAssertTrue(plan.arguments.contains("0:2"))
        XCTAssertTrue(plan.arguments.contains("-n"))
        XCTAssertFalse(plan.arguments.contains("-y"))
        XCTAssertFalse(plan.arguments.contains("sh"))
    }
    func testTrimUsesDurationAndRejectsInvalidBoundaries() throws {
        var settings = ConversionSettings(); settings.startTime = "00:00:10"; settings.endTime = "40"
        let plan = try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary)
        XCTAssertEqual(plan.expectedDuration, 30)
        let durationIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-t"))
        XCTAssertEqual(plan.arguments[durationIndex + 1], "30.0")
        settings.endTime = "5"
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary))
        settings.endTime = "121"
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary))
        settings.endTime = ""; settings.startTime = "120"
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary))
    }
    func testCannotOverwriteInput() {
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: info, settings: ConversionSettings(), output: input, temporary: temporary))
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: info, settings: ConversionSettings(), output: output, temporary: input))
    }
    func testMissingStreamsAndHDRGuard() {
        var settings = ConversionSettings(); settings.preset = .mp3
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: MediaInfo(videoCodec: "h264"), settings: settings, output: output, temporary: temporary))
        settings.preset = .mp4
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: MediaInfo(audioCodec: "aac"), settings: settings, output: output, temporary: temporary))
        var hdr = info; hdr.isHDR = true
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: hdr, settings: settings, output: output, temporary: temporary))
        settings.preset = .remuxMKV
        XCTAssertNoThrow(try CommandBuilder.make(input: input, info: hdr, settings: settings, output: output, temporary: temporary))
    }
    func testRemuxCannotPretendToTrimPrecisely() {
        var settings = ConversionSettings(); settings.preset = .remuxMP4; settings.startTime = "1"
        XCTAssertThrowsError(try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary))
    }
    func testOutputNamesPreserveExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = ConversionSettings(); settings.outputDirectory = root.path; settings.preset = .wav
        let first = try CommandBuilder.uniqueOutput(input: input, settings: settings)
        XCTAssertEqual(first.lastPathComponent, "含 空格 ' $() ; 源视频.wav")
        try Data("existing".utf8).write(to: first)
        let second = try CommandBuilder.uniqueOutput(input: input, settings: settings)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "含 空格 ' $() ; 源视频_2.wav")
        XCTAssertEqual(try String(contentsOf: first), "existing")
        // Re-importing an output should not accumulate preset labels.
        let reconverted = try CommandBuilder.uniqueOutput(input: first, settings: settings)
        XCTAssertEqual(reconverted, second)
    }
    func testProbeIgnoresCoverArtAndRecognizesHDR() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"index":1,"codec_type":"video","codec_name":"hevc","color_transfer":"smpte2084","width":1080,"height":1920},{"index":2,"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"8.5","size":"12345"}}"#
        let info = try MediaInfo.decodeProbe(Data(json.utf8))
        XCTAssertEqual(info.videoIndex, 1); XCTAssertEqual(info.videoCodec, "hevc"); XCTAssertTrue(info.isHDR)
        XCTAssertEqual(info.duration, 8.5); XCTAssertEqual(info.bytes, 12345)
    }
    func testProgressParsingHandlesPartialLinesAndNA() {
        var parser = ProgressParser()
        XCTAssertTrue(parser.consume("out_time_us=150").isEmpty)
        let first = parser.consume("0000\nspeed= 2.5x\nprogress=continue\n")
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].seconds, 1.5); XCTAssertEqual(first[0].speed, 2.5)
        let last = parser.consume("out_time_us=2000000\nspeed=N/A\nprogress=end\n")
        XCTAssertTrue(last[0].ended); XCTAssertEqual(last[0].speed, 0)
    }
    func testAudioDoesNotAddVideoFiltersAndMutedVideoDoesNotMapAudio() throws {
        var settings = ConversionSettings(); settings.preset = .mp3
        let audio = try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary)
        XCTAssertFalse(audio.arguments.contains("-vf")); XCTAssertTrue(audio.arguments.contains("-vn"))
        settings.preset = .mp4; settings.includeAudio = false
        let video = try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temporary)
        XCTAssertFalse(video.arguments.contains("0:a?")); XCTAssertFalse(video.arguments.contains("-c:a"))
    }
}

final class IntegrationTests: XCTestCase {
    private func engine() async throws -> EngineInfo {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg") else { throw XCTSkip("Install FFmpeg to run integration tests") }
        return try await EngineService.detect(customPath: nil)
    }
    private func fixture(root: URL, engine: EngineInfo) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("测试 片段 ' $(安全).mp4")
        let result = try await ProcessRunner().run(executable: engine.ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=318x242:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "2", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", input.path], timeout: 20)
        XCTAssertEqual(result.exitCode, 0, result.errorText)
        return input
    }
    func testAllPresetsProduceReadableMediaWithoutUpscaling() async throws {
        let engine = try await engine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFlow-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await fixture(root: root, engine: engine)
        let info = try await EngineService.probe(input, engine: engine)
        for preset in Preset.allCases {
            XCTAssertTrue(engine.supports(preset), "Missing encoder for \(preset)")
            var settings = ConversionSettings(); settings.preset = preset; settings.resolution = .sd; settings.outputDirectory = root.path
            let output = try CommandBuilder.uniqueOutput(input: input, settings: settings)
            let temp = CommandBuilder.temporaryURL(for: output)
            let plan = try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temp)
            let result = try await ProcessRunner().run(executable: engine.ffmpeg, arguments: plan.arguments, timeout: 60)
            XCTAssertEqual(result.exitCode, 0, "\(preset): \(result.errorText)")
            guard result.exitCode == 0 else { continue }
            let converted = try await EngineService.probe(temp, engine: engine)
            XCTAssertGreaterThan(converted.bytes, 0); XCTAssertEqual(converted.duration, 2, accuracy: 0.2)
            if preset.isAudio { XCTAssertNil(converted.videoCodec); XCTAssertNotNil(converted.audioCodec) }
            else { XCTAssertEqual(converted.width, 318); XCTAssertEqual(converted.height, 242) }
        }
    }
    func testTrimmingAndSilentVideo() async throws {
        let engine = try await engine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFlow-trim-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await fixture(root: root, engine: engine); let info = try await EngineService.probe(input, engine: engine)
        var settings = ConversionSettings(); settings.startTime = "0.5"; settings.endTime = "1.5"; settings.includeAudio = false
        let output = root.appendingPathComponent("trim.mp4"); let temp = CommandBuilder.temporaryURL(for: output)
        let plan = try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temp)
        let result = try await ProcessRunner().run(executable: engine.ffmpeg, arguments: plan.arguments, timeout: 20)
        XCTAssertEqual(result.exitCode, 0, result.errorText)
        let converted = try await EngineService.probe(temp, engine: engine)
        XCTAssertEqual(converted.duration, 1, accuracy: 0.1); XCTAssertNil(converted.audioCodec)
    }
    func testHardwareEncodingOnThisMac() async throws {
        let engine = try await engine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFlow-hardware-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await fixture(root: root, engine: engine); let info = try await EngineService.probe(input, engine: engine)
        for preset in [Preset.mp4, .hevc] {
            var settings = ConversionSettings(); settings.preset = preset; settings.hardware = true
            let output = root.appendingPathComponent(preset.rawValue + ".mp4"); let temp = CommandBuilder.temporaryURL(for: output)
            let plan = try CommandBuilder.make(input: input, info: info, settings: settings, output: output, temporary: temp)
            let result = try await ProcessRunner().run(executable: engine.ffmpeg, arguments: plan.arguments, timeout: 20)
            XCTAssertEqual(result.exitCode, 0, result.errorText)
            if result.exitCode == 0 { let converted = try await EngineService.probe(temp, engine: engine); XCTAssertNotNil(converted.videoCodec) }
        }
    }
    func testCancellationTerminatesRunningProcessPromptly() async throws {
        let engine = try await engine(); let runner = ProcessRunner()
        let operation = Task { try await runner.run(executable: engine.ffmpeg, arguments: ["-v", "error", "-re", "-f", "lavfi", "-i", "sine", "-t", "30", "-f", "null", "-"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date(); runner.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    func testTimeoutStopsProcessAndDrainsPipes() async throws {
        let engine = try await engine()
        do {
            _ = try await ProcessRunner().run(executable: engine.ffmpeg, arguments: ["-re", "-f", "lavfi", "-i", "sine", "-t", "30", "-f", "null", "-"], timeout: 0.3)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时"), error.localizedDescription) }
    }
}
