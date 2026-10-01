// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WinMuxBrowserNative",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WinMuxWorkspaceHelper", targets: ["WorkspaceHelper"]),
        .library(name: "WorkspaceCore", targets: ["WorkspaceCore"]),
    ],
    targets: [
        .target(name: "WorkspaceCore"),
        .testTarget(name: "WorkspaceCoreTests", dependencies: ["WorkspaceCore"]),
        .target(name: "BridgeProtocol", publicHeadersPath: "include"),
        .target(name: "BridgeCore", dependencies: ["BridgeProtocol"]),
        .executableTarget(name: "WorkspaceHelper", dependencies: ["BridgeCore", "BridgeProtocol"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
