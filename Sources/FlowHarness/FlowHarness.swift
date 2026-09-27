import Foundation
import FlowService
import MediaCore

// Integration-test host only; never included in the distributed APP.
@main
struct FlowHarness {
    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["FLOW_SUPPORT_DIRECTORY"] != nil else {
            throw FlowError("TEST_ONLY", "FlowHarness requires an isolated FLOW_SUPPORT_DIRECTORY.")
        }
        let service = TaskService()
        service.engine = try await EngineService.detect(customPath: nil)
        let router = ToolRouter(service: service)
        let bridge = BridgeServer { request in await router.handle(request) }
        try bridge.start()
        print("READY")
        while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }
}
