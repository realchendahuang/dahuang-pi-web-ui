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

/// Stable, UI-facing projection of one session returned by sessiond.
///
/// This deliberately mirrors only the fields the native shell needs. The
/// underlying Pi/OMP session objects remain private to the Node runtime.
public struct RuntimeSession: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let runtimeId: String
    public let path: String
    public let persisted: Bool?
    public let name: String?
    public let created: Date
    public let modified: Date
    public let messageCount: Int
    public let firstMessage: String
    public let archived: Bool?
    public let archivedAt: Date?

    public init(
        id: String,
        cwd: String,
        runtimeId: String,
        path: String,
        persisted: Bool? = nil,
        name: String? = nil,
        created: Date,
        modified: Date,
        messageCount: Int,
        firstMessage: String,
        archived: Bool? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.runtimeId = runtimeId
        self.path = path
        self.persisted = persisted
        self.name = name
        self.created = created
        self.modified = modified
        self.messageCount = messageCount
        self.firstMessage = firstMessage
        self.archived = archived
        self.archivedAt = archivedAt
    }

    public var displayTitle: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedFirstMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFirstMessage.isEmpty {
            return String(trimmedFirstMessage.prefix(72))
        }
        return "Untitled session"
    }
}

/// Minimal status projection used to know when a prompt has settled.
public struct RuntimeSessionStatus: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let runtimeId: String?
    public let isStreaming: Bool
    public let isCompacting: Bool
    public let isBashRunning: Bool
    public let pendingMessageCount: Int
    public let messageCount: Int?

    public init(
        sessionId: String,
        runtimeId: String? = nil,
        isStreaming: Bool,
        isCompacting: Bool,
        isBashRunning: Bool,
        pendingMessageCount: Int,
        messageCount: Int? = nil
    ) {
        self.sessionId = sessionId
        self.runtimeId = runtimeId
        self.isStreaming = isStreaming
        self.isCompacting = isCompacting
        self.isBashRunning = isBashRunning
        self.pendingMessageCount = pendingMessageCount
        self.messageCount = messageCount
    }
}

/// Decodes the browser-projected message without copying the provider's
/// private schema into Swift. Message content is rendered from the stable
/// text-bearing fields used by Pi-compatible runtimes.
public struct RuntimeMessage: Decodable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let text: String

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            id = UUID().uuidString
            role = "message"
            text = value.renderedText
            return
        }
        id = fields["id"]?.stringValue ?? UUID().uuidString
        role = fields["role"]?.stringValue ?? fields["type"]?.stringValue ?? "message"
        text = fields["content"]?.renderedText
            ?? fields["text"]?.stringValue
            ?? fields["message"]?.stringValue
            ?? ""
    }
}

public struct RuntimeMessagePage: Decodable, Sendable {
    public let messages: [RuntimeMessage]
    public let start: Int
    public let total: Int

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let messages = try? single.decode([RuntimeMessage].self) {
            self.messages = messages
            self.start = 0
            self.total = messages.count
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.messages = try keyed.decode([RuntimeMessage].self, forKey: .messages)
        self.start = try keyed.decodeIfPresent(Int.self, forKey: .start) ?? 0
        self.total = try keyed.decodeIfPresent(Int.self, forKey: .total) ?? self.messages.count
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case start
        case total
    }
}

/// Small JSON decoder used at the message boundary. Keeping it in the core
/// package lets the native UI survive additive provider fields without
/// importing a provider SDK.
public indirect enum JSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    fileprivate var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    fileprivate var renderedText: String {
        switch self {
        case .null:
            return ""
        case let .bool(value):
            return String(value)
        case let .number(value):
            return String(value)
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.renderedText).filter { !$0.isEmpty }.joined(separator: "\n")
        case let .object(fields):
            for key in ["text", "thinking", "output", "summary", "message"] {
                if let value = fields[key]?.renderedText, !value.isEmpty { return value }
            }
            return ""
        }
    }
}

public protocol RuntimeClient: RuntimeHealthClient {
    func listSessions(cwd: String) async throws -> [RuntimeSession]
    func startSession(cwd: String, runtimeId: String?) async throws -> RuntimeSession
    func messages(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeMessagePage
    func status(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeSessionStatus
    func prompt(sessionId: String, cwd: String, runtimeId: String?, text: String) async throws
}

public enum RuntimeClientError: LocalizedError, Equatable, Sendable {
    case invalidSocketPath
    case connectionFailed(String)
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case serverError(Int, String)
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
        case let .serverError(status, message):
            return "The Runtime returned HTTP \(status): \(message)"
        case let .invalidJSON(message):
            return "The Runtime returned invalid health JSON: \(message)"
        }
    }
}
