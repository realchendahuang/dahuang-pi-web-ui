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

    public init(id: String, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            id = UUID().uuidString
            role = "message"
            text = value.transcriptText
            return
        }
        id = fields["id"]?.stringValue ?? UUID().uuidString
        role = fields["role"]?.stringValue ?? fields["type"]?.stringValue ?? "message"
        text = fields["content"]?.transcriptText
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

/// Join-time watermark and the assistant message that was in flight when the
/// snapshot was captured. The runtime owns the canonical message object; this
/// is intentionally only the browser/native text projection.
public struct RuntimeStreamSnapshot: Decodable, Sendable {
    public let seq: Int
    public let partial: RuntimeMessage?

    public init(seq: Int, partial: RuntimeMessage?) {
        self.seq = seq
        self.partial = partial
    }
}

/// A decoded, additive session event from `/sessions/:id/events`.
///
/// The server deliberately keeps the wire event union open as Pi gains new
/// event types. Native code therefore decodes the stable fields it can render
/// and preserves the original type for forward-compatible handling.
public struct RuntimeSessionEvent: Decodable, Sendable {
    public let type: String
    public let seq: Int?
    public let text: String?
    public let message: RuntimeMessage?
    public let status: RuntimeSessionStatus?
    public let session: RuntimeSession?
    public let sessionId: String?
    public let name: String?
    public let command: String?
    public let chunk: String?
    public let output: String?
    public let exitCode: Int?
    public let cancelled: Bool?
    public let isError: Bool?
    public let toolName: String?
    public let toolCallId: String?
    public let summary: String?
    public let errorMessage: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        message = try container.decodeIfPresent(RuntimeMessage.self, forKey: .message)
        status = try container.decodeIfPresent(RuntimeSessionStatus.self, forKey: .status)
        session = try container.decodeIfPresent(RuntimeSession.self, forKey: .session)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        chunk = try container.decodeIfPresent(String.self, forKey: .chunk)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        errorMessage = (try? container.decode(String.self, forKey: .message))
            ?? (type == "session.error" ? text : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case type, seq, text, message, status, session, sessionId, name
        case command, chunk, output, exitCode, cancelled, isError
        case toolName, toolCallId, summary
    }
}

/// A terminal record returned by the Node PTY owner.
public struct RuntimeTerminalInfo: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let name: String
    public let createdAt: Date
    public let exited: Bool
    public let exitCode: Int?
    public let commandRunId: String?

    public init(
        id: String,
        cwd: String,
        name: String,
        createdAt: Date,
        exited: Bool,
        exitCode: Int? = nil,
        commandRunId: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.name = name
        self.createdAt = createdAt
        self.exited = exited
        self.exitCode = exitCode
        self.commandRunId = commandRunId
    }
}

/// Terminal WebSocket messages. PTY bytes remain owned by the Node terminal
/// service; the native surface only consumes output and sends input/resize.
public struct RuntimeTerminalEvent: Decodable, Sendable {
    public let type: String
    public let data: String?
    public let replay: Bool?
    public let exitCode: Int?
    public let message: String?

    public init(type: String, data: String? = nil, replay: Bool? = nil, exitCode: Int? = nil, message: String? = nil) {
        self.type = type
        self.data = data
        self.replay = replay
        self.exitCode = exitCode
        self.message = message
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

    /// Text safe to show in the native transcript. Provider thinking blocks
    /// can be present in the browser projection for compatibility, but they
    /// are private reasoning and must never be rendered as assistant text.
    fileprivate var transcriptText: String {
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
            return values.map(\.transcriptText).filter { !$0.isEmpty }.joined(separator: "\n")
        case let .object(fields):
            // A thinking block may also carry provider-specific fields. Check
            // its semantic type before looking at generic text-like keys.
            if fields["type"]?.stringValue == "thinking" { return "" }
            for key in ["text", "output", "summary", "message", "content"] {
                if let value = fields[key]?.transcriptText, !value.isEmpty { return value }
            }
            return ""
        }
    }
}

public protocol RuntimeClient: RuntimeHealthClient {
    func listSessions(cwd: String) async throws -> [RuntimeSession]
    func startSession(
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func messages(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeMessagePage
    func status(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeSessionStatus
    func prompt(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        text: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func archiveSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func restoreSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func deleteArchivedSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func abortActiveWork(commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func commandReceipt(commandId: String) async throws -> RuntimeCommandReceipt
}

/// Epoch-bound response for a native Runtime mutation. Repeating the same
/// command id returns this same receipt, letting the App safely recover from a
/// socket timeout without sending a second agent-level mutation.
public struct RuntimeCommandReceipt: Decodable, Equatable, Sendable {
    public struct AbortTarget: Decodable, Equatable, Sendable {
        public let sessionId: String
        public let runtimeId: String
    }

    public struct AbortFailure: Decodable, Equatable, Sendable {
        public let sessionId: String
        public let runtimeId: String
        public let error: String
    }

    /// The result is intentionally an open product projection: an abort has
    /// target counts while prompt, session lifecycle, and archive mutations
    /// carry their product-level completion state. Unknown future fields
    /// remain harmless to an older native shell.
    public struct Result: Decodable, Equatable, Sendable {
        public let requested: Int?
        public let aborted: [AbortTarget]?
        public let failures: [AbortFailure]?
        public let accepted: Bool?
        public let created: Bool?
        public let archived: Bool?
        public let restored: Bool?
        public let deleted: Bool?
        public let sessionId: String?
        public let cwd: String?
        public let runtimeId: String?
    }

    public let commandId: String
    public let kind: String
    public let runtimeEpoch: String
    public let status: String
    public let startedAt: Date
    public let completedAt: Date
    public let result: Result?
    public let error: String?
}

/// Session event transport kept separate from the request client so tests and
/// future runtimes can provide only the capabilities they support.
public protocol RuntimeEventStreamClient: Sendable {
    func streamSnapshot(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeStreamSnapshot
    func subscribe(sessionId: String, cwd: String, runtimeId: String?) -> RuntimeEventSubscription
}

public protocol RuntimeTerminalClient: Sendable {
    func listTerminals(cwd: String) async throws -> [RuntimeTerminalInfo]
    func createTerminal(cwd: String, name: String, cols: Int, rows: Int) async throws -> RuntimeTerminalInfo
    func continueTerminal(id: String) async throws -> RuntimeTerminalInfo
    func subscribeTerminal(id: String, cols: Int, rows: Int) -> RuntimeTerminalSubscription
}

/// A cancellable, reconnectable unit of session event delivery. Cancellation
/// closes the underlying Unix socket rather than merely stopping a consumer.
public final class RuntimeEventSubscription: @unchecked Sendable {
    public let events: AsyncThrowingStream<RuntimeSessionEvent, Error>
    public let ready: AsyncThrowingStream<Void, Error>
    private let cancelAction: @Sendable () -> Void

    public init(
        events: AsyncThrowingStream<RuntimeSessionEvent, Error>,
        ready: AsyncThrowingStream<Void, Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.ready = ready
        self.cancelAction = cancel
    }

    public func cancel() {
        cancelAction()
    }
}

/// A cancellable terminal byte/event stream. Outgoing input is buffered until
/// the WebSocket handshake finishes, so a freshly-created surface cannot lose
/// the first resize or keystroke.
public final class RuntimeTerminalSubscription: @unchecked Sendable {
    public let events: AsyncThrowingStream<RuntimeTerminalEvent, Error>
    public let ready: AsyncThrowingStream<Void, Error>
    private let sendInputAction: @Sendable (String) -> Void
    private let resizeAction: @Sendable (Int, Int) -> Void
    private let cancelAction: @Sendable () -> Void

    public init(
        events: AsyncThrowingStream<RuntimeTerminalEvent, Error>,
        ready: AsyncThrowingStream<Void, Error>,
        sendInput: @escaping @Sendable (String) -> Void,
        resize: @escaping @Sendable (Int, Int) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.ready = ready
        self.sendInputAction = sendInput
        self.resizeAction = resize
        self.cancelAction = cancel
    }

    public func sendInput(_ data: String) {
        sendInputAction(data)
    }

    public func resize(cols: Int, rows: Int) {
        resizeAction(cols, rows)
    }

    public func cancel() {
        cancelAction()
    }
}

public enum RuntimeClientError: LocalizedError, Equatable, Sendable {
    case invalidSocketPath
    case connectionFailed(String)
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case serverError(Int, String)
    case invalidJSON(String)
    case incompatibleRuntime(String)

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
        case let .incompatibleRuntime(message):
            return message
        }
    }
}
