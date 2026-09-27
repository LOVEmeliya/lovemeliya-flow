import Foundation
import MCP
import FlowService
import AppKit

actor AppConnection {
    let session = UUID().uuidString
    var clientName = "MCP client"
    private var launchAttempted = false
    func identify(_ name: String) { clientName = String(name.prefix(80)) }
    func call(_ name: String, arguments: JSONValue = .object([:]), allowLaunch: Bool = true) async -> BridgeResponse {
        let request = BridgeRequest(name: name, arguments: arguments, client: clientName, session: session)
        do { return try await LocalBridge.request(request) }
        catch let error as FlowError where error.code == "APP_NOT_RUNNING" {
            guard allowLaunch, !launchAttempted, ProcessInfo.processInfo.environment["FLOW_NO_AUTO_LAUNCH"] != "1" else { return .failure(error) }
            launchAttempted = true
            defer { launchAttempted = false }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard app.pathExtension == "app" else { return .failure(FlowError("APP_NOT_RUNNING", "开发模式请先启动 Flow APP 或测试服务。")) }
            do {
                await MainActor.run {
                    let config = NSWorkspace.OpenConfiguration(); config.activates = false
                    NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in }
                }
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if let response = try? await LocalBridge.request(request) { return response }
                }
                return .failure(FlowError("APP_NOT_RUNNING", "APP 未能就绪，请手动打开应用后重试。"))
            } catch { return .failure(error) }
        } catch { return .failure(error) }
    }
}

@main
struct FlowMCPMain {
    static func main() async {
        if CommandLine.arguments.contains("--version") { print("LOVEmeliya Flow MCP 1.1.0"); return }
        if CommandLine.arguments.contains("--help") {
            print("LOVEmeliya Flow MCP 1.1.0\nUsage: lovemeliya-flow-mcp [--stdio]\nConfigure this executable as a local stdio MCP server. Enable AI access and directories in the APP first."); return
        }
        do {
            let connection = AppConnection()
            let server = Server(name: "lovemeliya-flow", version: "1.1.0", capabilities: .init(tools: .init()), configuration: .strict)
            await server.withMethodHandler(ListTools.self) { _ in
                let definitions = try ToolCatalog.definitions.map { definition in
                    Tool(name: definition.name, description: definition.description,
                         inputSchema: try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(definition.inputSchema)),
                         annotations: .init(readOnlyHint: definition.readOnly, destructiveHint: false, idempotentHint: definition.name != "flow_plan", openWorldHint: false),
                         outputSchema: .object(["type": .string("object")]))
                }
                return .init(tools: definitions)
            }
            await server.withMethodHandler(CallTool.self) { params in
                let args = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params.arguments ?? [:]))
                let response = await connection.call(params.name, arguments: args)
                let payload: JSONValue = response.ok ? (response.data ?? .object([:])) : .object(["error": try .from(response.error)])
                let data = try JSONEncoder().encode(payload)
                return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: Optional.some(try JSONDecoder().decode(Value.self, from: data)), isError: !response.ok)
            }
            try await server.start(transport: StdioTransport(), initializeHook: { info, _ in
                await connection.identify(info.name)
                _ = await connection.call("_connect")
            })
            let heartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
                    _ = await connection.call("_connect", allowLaunch: false)
                }
            }
            await server.waitUntilCompleted()
            heartbeat.cancel()
            _ = await connection.call("_disconnect", allowLaunch: false)
        } catch {
            FileHandle.standardError.write(Data("Flow MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
