import CryptoKit
import Foundation

public struct RuntimeProtocolVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

/// Product-level handshake returned by a bundled Node Runtime. It deliberately
/// contains no Pi SDK objects, session data, or provider credentials.
public struct RuntimeHello: Codable, Equatable, Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let appVersion: String
        public let runtimeVersion: String
        public let piSdkVersion: String
    }

    public let kind: String
    public let protocolVersion: RuntimeProtocolVersion
    public let runtimeEpoch: String
    public let nodeVersion: String
    public let architecture: String
    public let manifest: Manifest?

    private enum CodingKeys: String, CodingKey {
        case kind
        case protocolVersion = "protocol"
        case runtimeEpoch
        case nodeVersion
        case architecture
        case manifest
    }

    public init(
        kind: String,
        protocolVersion: RuntimeProtocolVersion,
        runtimeEpoch: String,
        nodeVersion: String,
        architecture: String,
        manifest: Manifest?
    ) {
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.runtimeEpoch = runtimeEpoch
        self.nodeVersion = nodeVersion
        self.architecture = architecture
        self.manifest = manifest
    }

    public func requireCompatibleProtocol(major: Int) throws {
        guard kind == "pi-agent-runtime" else {
            throw RuntimeClientError.incompatibleRuntime("Unexpected Runtime kind: \(kind)")
        }
        guard protocolVersion.major == major else {
            throw RuntimeClientError.incompatibleRuntime(
                "Runtime protocol \(protocolVersion.major).\(protocolVersion.minor) is incompatible with protocol \(major).x"
            )
        }
    }
}

public protocol RuntimeHelloClient: RuntimeHealthClient {
    func hello() async throws -> RuntimeHello
}

public struct BundledRuntime: Sendable {
    public static let protocolMajor = 1

    public let launchPlan: RuntimeLaunchPlan
    private let verification: RuntimeBundleVerification

    private init(launchPlan: RuntimeLaunchPlan, verification: RuntimeBundleVerification) {
        self.launchPlan = launchPlan
        self.verification = verification
    }

    /// Returns nil outside an assembled `.app` so `swift run` and explicit
    /// development sockets retain their existing behavior.
    public static func discover(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> BundledRuntime? {
        guard let resourcesURL = bundle.resourceURL else { return nil }
        let runtimeRoot = resourcesURL.appendingPathComponent("AgentRuntime", isDirectory: true)
        let manifestURL = runtimeRoot.appendingPathComponent("runtime-manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let manifest: BundledRuntimeManifest
        do {
            manifest = try JSONDecoder().decode(BundledRuntimeManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw BundledRuntimeError.invalidManifest("Could not decode \(manifestURL.path): \(error.localizedDescription)")
        }
        guard manifest.schemaVersion == 1 else {
            throw BundledRuntimeError.invalidManifest("Unsupported Runtime manifest schema \(manifest.schemaVersion)")
        }
        guard manifest.protocolVersion.major == protocolMajor else {
            throw BundledRuntimeError.invalidManifest(
                "Runtime manifest protocol \(manifest.protocolVersion.major).\(manifest.protocolVersion.minor) is incompatible with protocol \(protocolMajor).x"
            )
        }

        let nodeURL = try runtimeURL(root: runtimeRoot, relativePath: manifest.node.executablePath)
        let launcherURL = try runtimeURL(root: runtimeRoot, relativePath: "runtime-launcher.mjs")
        guard fileManager.isExecutableFile(atPath: nodeURL.path) else {
            throw BundledRuntimeError.invalidManifest("Bundled Node executable is missing or not executable: \(nodeURL.path)")
        }
        guard fileManager.fileExists(atPath: launcherURL.path) else {
            throw BundledRuntimeError.invalidManifest("Bundled Runtime launcher is missing: \(launcherURL.path)")
        }

        let applicationSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pi Agent", isDirectory: true)
        let runtimeState = applicationSupport.appendingPathComponent("Runtime", isDirectory: true)
        let socketPath = runtimeState.appendingPathComponent("sessiond.sock").path
        var runtimeEnvironment = environment
        runtimeEnvironment["PI_WEB_DATA_DIR"] = applicationSupport.appendingPathComponent("State", isDirectory: true).path
        runtimeEnvironment["PI_WEB_SESSIOND_SOCKET"] = socketPath
        runtimeEnvironment["PI_AGENT_RUNTIME_MANIFEST"] = manifestURL.path
        runtimeEnvironment["PI_AGENT_RUNTIME_EPOCH"] = UUID().uuidString

        let verification = RuntimeBundleVerification(
            root: runtimeRoot,
            manifest: manifest,
            nodeURL: nodeURL
        )
        return BundledRuntime(
            launchPlan: RuntimeLaunchPlan(
                executable: nodeURL,
                arguments: [launcherURL.path],
                environment: runtimeEnvironment,
                workingDirectory: runtimeRoot,
                socketPath: socketPath
            ),
            verification: verification
        )
    }

    public func makeSupervisor() -> RuntimeSupervisor {
        RuntimeSupervisor(plan: launchPlan, validateBeforeStart: { try verification.validate() })
    }
}

public enum BundledRuntimeError: LocalizedError, Equatable, Sendable {
    case invalidManifest(String)
    case integrityFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidManifest(message):
            return "The bundled Runtime manifest is invalid: \(message)"
        case let .integrityFailure(message):
            return "The bundled Runtime failed its local integrity check: \(message)"
        }
    }
}

private struct BundledRuntimeManifest: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        let version: String
        let architecture: String
        let executablePath: String
        let sha256: String
    }

    struct File: Decodable, Sendable {
        let path: String
        let sha256: String
        let bytes: Int
        let kind: String?
        let target: String?
    }

    let schemaVersion: Int
    let appVersion: String
    let runtimeVersion: String
    let protocolVersion: RuntimeProtocolVersion
    let node: Node
    let piSdkVersion: String
    let files: [File]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case appVersion
        case runtimeVersion
        case protocolVersion = "protocol"
        case node
        case piSdkVersion
        case files
    }
}

private struct RuntimeBundleVerification: @unchecked Sendable {
    let root: URL
    let manifest: BundledRuntimeManifest
    let nodeURL: URL

    func validate() throws {
        guard !manifest.node.version.isEmpty, !manifest.node.architecture.isEmpty else {
            throw BundledRuntimeError.invalidManifest("Runtime manifest has incomplete Node metadata")
        }
        // The launcher performs the authoritative Node-version and architecture
        // check after launch. Swift validates the exact resource bytes first.
        try verifyFile(url: nodeURL, expectedHash: manifest.node.sha256, expectedBytes: nil)
        for entry in manifest.files {
            let url = try runtimeURL(root: root, relativePath: entry.path)
            if entry.kind == "symlink" {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard target == entry.target else {
                    throw BundledRuntimeError.integrityFailure("Symlink target changed: \(entry.path)")
                }
                guard sha256(Data(target.utf8)) == entry.sha256 else {
                    throw BundledRuntimeError.integrityFailure("Symlink hash changed: \(entry.path)")
                }
                let resolvedTarget = url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                guard isInside(root, resolvedTarget) else {
                    throw BundledRuntimeError.integrityFailure("Symlink escapes Runtime bundle: \(entry.path)")
                }
                continue
            }
            try verifyFile(url: url, expectedHash: entry.sha256, expectedBytes: entry.bytes)
        }
    }

    private func verifyFile(url: URL, expectedHash: String, expectedBytes: Int?) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw BundledRuntimeError.integrityFailure("Expected a regular Runtime file: \(url.lastPathComponent)")
        }
        if let expectedBytes, values.fileSize != expectedBytes {
            throw BundledRuntimeError.integrityFailure("Runtime file size changed: \(url.lastPathComponent)")
        }
        guard sha256(try Data(contentsOf: url)) == expectedHash.lowercased() else {
            throw BundledRuntimeError.integrityFailure("Runtime file hash changed: \(url.lastPathComponent)")
        }
    }
}

private func runtimeURL(root: URL, relativePath: String) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
        throw BundledRuntimeError.invalidManifest("Runtime path must be bundle-relative")
    }
    let url = root.appendingPathComponent(relativePath).standardizedFileURL
    guard isInside(root, url) else {
        throw BundledRuntimeError.invalidManifest("Runtime path escapes bundle: \(relativePath)")
    }
    return url
}

private func isInside(_ root: URL, _ candidate: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path.hasSuffix("/")
        ? root.standardizedFileURL.path
        : root.standardizedFileURL.path + "/"
    return candidate.standardizedFileURL.path.hasPrefix(rootPath)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
