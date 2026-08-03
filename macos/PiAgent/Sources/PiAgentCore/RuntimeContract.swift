import Foundation

/// The health projection exposed by the existing PI WEB session daemon.
///
/// The native shell treats this as a read-only projection. Session ownership,
/// event ordering, PTYs, and persistence remain in the Node runtime.
public struct RuntimeHealth: Codable, Equatable, Sendable {
    public struct Version: Codable, Equatable, Sendable {
        public let component: String
        public let label: String
        public let runtimeVersion: String?
        public let stale: Bool
        public let available: Bool

        public init(
            component: String,
            label: String,
            runtimeVersion: String? = nil,
            stale: Bool,
            available: Bool
        ) {
            self.component = component
            self.label = label
            self.runtimeVersion = runtimeVersion
            self.stale = stale
            self.available = available
        }
    }

    public let ok: Bool
    public let activeSessions: Int
    public let checkedAt: Date
    public let version: Version

    public init(ok: Bool, activeSessions: Int, checkedAt: Date, version: Version) {
        self.ok = ok
        self.activeSessions = activeSessions
        self.checkedAt = checkedAt
        self.version = version
    }
}

public enum RuntimeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(RuntimeHealth)
    case failed(String)
}

public struct RuntimeLaunchPlan: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let socketPath: String

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        socketPath: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.socketPath = socketPath
    }

    /// Creates a launch plan only when the caller explicitly opts into starting
    /// a process. The native shell must not invent a runtime command from PATH.
    public static func fromEnvironment(
        _ environment: [String: String],
        defaultSocketPath: String
    ) -> RuntimeLaunchPlan? {
        guard let rawExecutable = environment["PI_AGENT_RUNTIME_EXECUTABLE"], !rawExecutable.isEmpty else {
            return nil
        }

        let script = environment["PI_AGENT_RUNTIME_SCRIPT"]
        let arguments = script.map { [$0] } ?? []
        let socketPath = environment["PI_AGENT_RUNTIME_SOCKET"] ?? defaultSocketPath
        return RuntimeLaunchPlan(
            executable: URL(fileURLWithPath: rawExecutable),
            arguments: arguments,
            environment: environment,
            workingDirectory: environment["PI_AGENT_RUNTIME_WORKING_DIRECTORY"].map(URL.init(fileURLWithPath:)),
            socketPath: socketPath
        )
    }
}

public protocol RuntimeHealthClient: Sendable {
    func health() async throws -> RuntimeHealth
}

public enum RuntimeClientError: LocalizedError, Equatable, Sendable {
    case invalidSocketPath
    case connectionFailed(String)
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            return "The Runtime socket path is invalid."
        case let .connectionFailed(message):
            return "Could not connect to the Runtime: \(message)"
        case .invalidHTTPResponse:
            return "The Runtime returned an invalid HTTP response."
        case let .unexpectedHTTPStatus(status):
            return "The Runtime returned HTTP status \(status)."
        case let .invalidJSON(message):
            return "The Runtime returned invalid health JSON: \(message)"
        }
    }
}
