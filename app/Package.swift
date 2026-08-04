// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentHUD", path: "Sources/AgentHUD")
    ]
)
