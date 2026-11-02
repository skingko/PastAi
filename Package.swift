// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PastAiKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .library(name: "ClipEnrich", targets: ["ClipEnrich"]),
        .library(name: "ClipExtensions", targets: ["ClipExtensions"]),
        .library(name: "ClipAgent", targets: ["ClipAgent"]),
        .library(name: "QuickPanel", targets: ["QuickPanel"]),
        .library(name: "SelectionBar", targets: ["SelectionBar"]),
        .library(name: "Workspace", targets: ["Workspace"]),
        .executable(name: "PastAi", targets: ["PastAi"]),
    ],
    targets: [
        .target(name: "ClipCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ClipEnrich", dependencies: ["ClipCore"]),
        .target(name: "ClipExtensions", dependencies: ["ClipCore"]),
        .target(name: "ClipAgent", dependencies: ["ClipCore", "ClipEnrich", "ClipExtensions"]),
        // QuickPanel must never depend on ClipAgent: copy and paste keep working when AI is broken.
        .target(name: "QuickPanel", dependencies: ["ClipCore"]),
        // AI reaches the selection bar through a closure from the app, so it links no model code either.
        .target(name: "SelectionBar", dependencies: ["ClipCore", "ClipExtensions"]),
        .target(name: "Workspace", dependencies: ["ClipCore", "ClipAgent", "ClipExtensions"]),
        .executableTarget(
            name: "PastAi",
            dependencies: ["ClipCore", "ClipEnrich", "ClipAgent", "ClipExtensions", "QuickPanel", "SelectionBar", "Workspace"],
            path: "App",
            exclude: ["Info.plist", "PastAi.entitlements", "Resources"]
        ),
        .executableTarget(name: "PastAiBench", dependencies: ["ClipCore", "ClipEnrich"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipEnrichTests", dependencies: ["ClipEnrich", "ClipCore"]),
        .testTarget(name: "ClipExtensionsTests", dependencies: ["ClipExtensions", "ClipCore"]),
        .testTarget(name: "ClipAgentTests", dependencies: ["ClipAgent", "ClipCore", "ClipExtensions"]),
    ]
)
