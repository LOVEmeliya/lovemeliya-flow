// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MediaFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaFlow", targets: ["MediaFlow"]),
        .executable(name: "lovemeliya-flow-mcp", targets: ["FlowMCP"])
    ],
    dependencies: [.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")],
    targets: [
        .target(name: "MediaCore"),
        .target(name: "FlowService", dependencies: ["MediaCore"]),
        .executableTarget(name: "MediaFlow", dependencies: ["MediaCore", "FlowService"]),
        .executableTarget(name: "FlowMCP", dependencies: ["FlowService", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "FlowHarness", dependencies: ["FlowService"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "FlowService"])
    ]
)
