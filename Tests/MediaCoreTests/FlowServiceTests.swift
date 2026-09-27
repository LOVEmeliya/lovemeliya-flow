import XCTest
import Foundation
import MediaCore
@testable import FlowService

@MainActor
final class FlowServiceTests: XCTestCase {
    func fixture(approval: Bool = true) async throws -> (TaskService, ToolRouter, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flow-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = try await EngineService.detect(customPath: nil)
        let media = root.appendingPathComponent("录音 ' $(test).wav")
        let generated = try await ProcessRunner().run(executable: engine.ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "sine=sample_rate=16000", "-t", "1", "-c:a", "pcm_s16le", media.path])
        XCTAssertEqual(generated.exitCode, 0)
        let service = TaskService(support: root.appendingPathComponent("support")); service.engine = engine
        var policy = AccessPolicy(); policy.enabled = true; policy.requireApproval = approval; policy.readDirectories = [root.path]; policy.writeDirectories = [root.path]
        try service.setPolicy(policy)
        return (service, ToolRouter(service: service), root, media)
    }
    func call(_ router: ToolRouter, _ name: String, _ args: [String: JSONValue] = [:]) async -> BridgeResponse {
        await router.handle(BridgeRequest(name: name, arguments: .object(args), client: "Tests", session: "session"))
    }
    func plan(_ router: ToolRouter, root: URL, input: URL) async throws -> String {
        let result = await call(router, "flow_plan", ["inputs": .array([.string(input.path)]), "preset": .string("wav"), "output_directory": .string(root.path)])
        XCTAssertTrue(result.ok, result.error?.message ?? "")
        return try XCTUnwrap(result.data?.object?["plan_id"]?.string)
    }
    func testDirectoryAuthorizationRejectsTraversalPrefixAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed"); let outside = root.appendingPathComponent("allowed-sibling")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("private.wav"); try Data([1]).write(to: file)
        let link = allowed.appendingPathComponent("link.wav"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        var policy = AccessPolicy(); policy.readDirectories = [allowed.path]; policy.writeDirectories = [allowed.path]
        XCTAssertThrowsError(try policy.input(file.path))
        XCTAssertThrowsError(try policy.input(link.path))
        XCTAssertThrowsError(try policy.input(allowed.path + "/../allowed-sibling/private.wav"))
        XCTAssertThrowsError(try policy.input("relative.wav"))
        XCTAssertThrowsError(try policy.outputDirectory(outside.path))
    }
    func testDisabledMCPAndInvalidArguments() async throws {
        let (service, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = service.policy; policy.enabled = false; try service.setPolicy(policy)
        let disabled = await call(router, "flow_inspect", ["path": .string(input.path)])
        XCTAssertEqual(disabled.error?.code, "MCP_DISABLED")
        let capabilities = await call(router, "flow_capabilities")
        XCTAssertEqual(capabilities.data?.object?["enabled"], .bool(false))
        policy.enabled = true; try service.setPolicy(policy)
        let unknown = await call(router, "flow_plan", ["command": .string("anything")])
        XCTAssertEqual(unknown.error?.code, "INVALID_ARGUMENTS")
        let badLimit = await call(router, "flow_list_jobs", ["limit": .number(1.5)])
        XCTAssertEqual(badLimit.error?.code, "INVALID_ARGUMENTS")
        let ambiguous = await call(router, "flow_cancel", ["job_id": .string("x"), "batch_id": .string("y")])
        XCTAssertEqual(ambiguous.error?.code, "INVALID_ARGUMENTS")
    }
    func testPlanDoesNotConvertAndSubmitNeedsApprovalAndIsDurable() async throws {
        let (service, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let planID = try await plan(router, root: root, input: input)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before.sorted())
        XCTAssertTrue(service.jobs.isEmpty)
        let submitted = await call(router, "flow_submit", ["plan_id": .string(planID), "request_id": .string("first")])
        XCTAssertTrue(submitted.ok); XCTAssertEqual(service.jobs.first?.status, .awaitingApproval); XCTAssertFalse(service.isRunning)
        let duplicate = await call(router, "flow_submit", ["plan_id": .string(planID), "request_id": .string("first")])
        XCTAssertEqual(duplicate.data?.object?["duplicate"], .bool(true)); XCTAssertEqual(service.jobs.count, 1)
        let duplicatePlan = await call(router, "flow_submit", ["plan_id": .string(planID), "request_id": .string("other-key")])
        XCTAssertEqual(duplicatePlan.data?.object?["duplicate"], .bool(true)); XCTAssertEqual(service.jobs.count, 1)
        let restored = TaskService(support: service.support); restored.engine = service.engine
        let response = await call(ToolRouter(service: restored), "flow_submit", ["plan_id": .string(planID), "request_id": .string("first")])
        XCTAssertEqual(response.data?.object?["duplicate"], .bool(true)); XCTAssertEqual(restored.jobs.count, 1)
    }
    func testApprovalCompletesAndReturnsActualOutputMetadata() async throws {
        let (service, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let planID = try await plan(router, root: root, input: input)
        _ = await call(router, "flow_submit", ["plan_id": .string(planID), "request_id": .string("approved")])
        let id = try XCTUnwrap(service.jobs.first?.id)
        service.approve(id)
        let deadline = Date().addingTimeInterval(10)
        while service.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(service.jobs.first?.status, .completed, service.jobs.first?.error ?? "")
        let result = await call(router, "flow_get_job", ["job_id": .string(id.uuidString)])
        XCTAssertEqual(result.data?.object?["output_media"]?.object?["sampleRate"], .number(16000))
        XCTAssertEqual(result.data?.object?["output_media"]?.object?["channels"], .number(1))
        XCTAssertTrue(service.jobs.first?.output?.lastPathComponent.hasSuffix("_2.wav") ?? false)
    }
    func testAIQueueDoesNotStartManualJobsAndCancelIsScoped() async throws {
        let (service, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manual = MediaJob(input: input); service.jobs.append(manual)
        let planID = try await plan(router, root: root, input: input)
        _ = await call(router, "flow_submit", ["plan_id": .string(planID), "request_id": .string("ai")])
        let ai = try XCTUnwrap(service.jobs.last)
        let blocked = await call(router, "flow_cancel", ["job_id": .string(manual.id.uuidString)])
        XCTAssertEqual(blocked.error?.code, "MANUAL_JOB_PROTECTED")
        let cancelled = await call(router, "flow_cancel", ["batch_id": .string(ai.batchID!)])
        XCTAssertTrue(cancelled.ok); XCTAssertEqual(service.jobs.last?.status, .cancelled); XCTAssertEqual(service.jobs.first?.status, .ready)
        var policy = service.policy; policy.requireApproval = false; try service.setPolicy(policy)
        let second = try await plan(router, root: root, input: input)
        _ = await call(router, "flow_submit", ["plan_id": .string(second), "request_id": .string("ai-2")])
        let deadline = Date().addingTimeInterval(10)
        while service.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(service.jobs.last?.status, .completed); XCTAssertEqual(service.jobs.first?.status, .ready)
    }
    func testChangedSourceInvalidatesPlan() async throws {
        let (service, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = try await plan(router, root: root, input: input)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: input.path)
        let result = await call(router, "flow_submit", ["plan_id": .string(id), "request_id": .string("changed")])
        XCTAssertEqual(result.error?.code, "SOURCE_CHANGED"); XCTAssertTrue(service.jobs.isEmpty)
    }
    func testRevokedPolicyRejectsExistingPlan() async throws {
        let (service, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = try await plan(router, root: root, input: input)
        var policy = service.policy; policy.writeDirectories = []; try service.setPolicy(policy)
        let result = await call(router, "flow_submit", ["plan_id": .string(id), "request_id": .string("revoked")])
        XCTAssertEqual(result.error?.code, "ACCESS_DENIED"); XCTAssertTrue(service.jobs.isEmpty)
    }
    func testPlaylistNotAcceptedEvenInsideAllowedDirectory() async throws {
        let (_, router, root, input) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let playlist = root.appendingPathComponent("bad.ffconcat")
        try "ffconcat version 1.0\nfile '\(input.path)'\n".write(to: playlist, atomically: true, encoding: .utf8)
        let response = await call(router, "flow_inspect", ["path": .string(playlist.path)])
        XCTAssertFalse(response.ok)
    }
    func testLegacyQueueAndSettingsMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = #"[{"id":"00000000-0000-0000-0000-000000000001","input":"file:///tmp/a.wav","status":"ready","progress":0,"speed":0,"log":"","createdAt":0}]"#
        try Data(old.utf8).write(to: root.appendingPathComponent("queue.json"))
        let service = TaskService(support: root)
        XCTAssertEqual(service.jobs.count, 1); XCTAssertFalse(service.jobs[0].isAI)
        let oldSettings = #"{"preset":"wav","quality":"balanced","resolution":"source","hardware":false,"includeAudio":true,"startTime":"","endTime":""}"#
        let settings = try JSONDecoder().decode(ConversionSettings.self, from: Data(oldSettings.utf8))
        XCTAssertNil(settings.sampleRate); XCTAssertNil(settings.channels)
    }
    func testLocalBridgeAndSingleInstanceLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = BridgeServer(support: root) { request in .success(.object(["received": .string(request.name)])) }
        try server.start(); defer { server.stop(); try? FileManager.default.removeItem(at: LocalBridge.directory(support: root)) }
        let other = BridgeServer(support: root) { _ in .success(.null) }
        XCTAssertThrowsError(try other.start())
        let response = try await LocalBridge.request(BridgeRequest(name: "test", arguments: .object([:]), client: "test", session: "test"), support: root)
        XCTAssertEqual(response.data?.object?["received"], .string("test"))
    }
}
