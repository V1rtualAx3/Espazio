// swift-tools-version: 6.0
import PackageDescription

// Cross-platform targets hold every piece of testable logic and also build on
// Linux (CI + cloud development). macOS-only targets are thin adapters over
// AppKit / SwiftUI / EventKit / CoreAudio and are only declared on macOS.

var products: [Product] = [
    .library(name: "EspazioCore", targets: ["EspazioCore"]),
    .executable(name: "espazio-hook", targets: ["EspazioHook"]),
]

var targets: [Target] = [
    .target(name: "EspazioCore"),
    .target(name: "EspazioBridge", dependencies: ["EspazioCore"]),
    .target(name: "AgentIntegrations", dependencies: ["EspazioCore", "EspazioBridge"]),
    .target(name: "GoogleProvider", dependencies: ["EspazioCore", "EspazioBridge"]),
    .executableTarget(name: "EspazioHook", dependencies: ["EspazioBridge", "AgentIntegrations"]),

    .testTarget(name: "EspazioCoreTests", dependencies: ["EspazioCore"]),
    .testTarget(name: "EspazioBridgeTests", dependencies: ["EspazioBridge"]),
    .testTarget(name: "AgentIntegrationsTests", dependencies: ["AgentIntegrations"]),
    .testTarget(name: "GoogleProviderTests", dependencies: ["GoogleProvider"]),
]

#if os(macOS)
products.append(.executable(name: "Espazio", targets: ["Espazio"]))
targets += [
    .target(name: "SystemServices", dependencies: ["EspazioCore"]),
    .target(name: "ProductivityProviders", dependencies: ["EspazioCore"]),
    .target(name: "EspazioUI", dependencies: ["EspazioCore"]),
    .executableTarget(
        name: "Espazio",
        dependencies: [
            "EspazioCore", "EspazioBridge", "AgentIntegrations", "GoogleProvider",
            "SystemServices", "ProductivityProviders", "EspazioUI",
        ]
    ),
    .testTarget(name: "EspazioUITests", dependencies: ["EspazioUI", "EspazioCore"]),
]
#endif

let package = Package(
    name: "Espazio",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
