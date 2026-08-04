// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PiAgent",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PiAgentCore", targets: ["PiAgentCore"]),
        .executable(name: "PiAgent", targets: ["PiAgentApp"]),
        .executable(name: "PiAgentKeychainHelper", targets: ["PiAgentKeychainHelper"]),
        .executable(name: "PiAgentUninstaller", targets: ["PiAgentUninstaller"]),
    ],
    dependencies: [
        // SwiftTerm provides the native VT parser and AppKit surface. PTY
        // ownership remains in the Node session daemon; this is only the
        // renderer/input adapter.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .target(
            name: "PiAgentCore",
            path: "Sources/PiAgentCore"
        ),
        .executableTarget(
            name: "PiAgentApp",
            dependencies: [
                "PiAgentCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/PiAgentApp"
        ),
        .executableTarget(
            name: "PiAgentContractCheck",
            dependencies: ["PiAgentCore"],
            path: "Sources/PiAgentContractCheck"
        ),
        .executableTarget(
            name: "PiAgentKeychainHelper",
            path: "Sources/PiAgentKeychainHelper"
        ),
        .executableTarget(
            name: "PiAgentUninstaller",
            dependencies: ["PiAgentCore"],
            path: "Sources/PiAgentUninstaller"
        ),
    ]
)
