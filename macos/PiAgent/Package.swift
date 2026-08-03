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
    ],
    targets: [
        .target(
            name: "PiAgentCore",
            path: "Sources/PiAgentCore"
        ),
        .executableTarget(
            name: "PiAgentApp",
            dependencies: ["PiAgentCore"],
            path: "Sources/PiAgentApp"
        ),
        .executableTarget(
            name: "PiAgentContractCheck",
            dependencies: ["PiAgentCore"],
            path: "Sources/PiAgentContractCheck"
        ),
    ]
)
