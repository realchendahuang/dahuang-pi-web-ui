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

/// Provider credential metadata only. The Runtime never exposes a credential
/// value to the native product contract.
public struct RuntimeAuthProviderStatus: Codable, Equatable, Sendable {
    public let configured: Bool
    public let source: String?
    public let label: String?
}

public struct RuntimeAuthProvider: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let authType: String
    public let status: RuntimeAuthProviderStatus
    public let loginFlow: String?

    /// A provider can offer both OAuth and API-key login, so the upstream
    /// provider id alone is not a stable SwiftUI collection identity.
    public var displayID: String { "\(id):\(authType)" }
}

public struct RuntimeAuthProviders: Codable, Equatable, Sendable {
    public let providers: [RuntimeAuthProvider]
}

/// A redacted projection of credentials found in Pi's legacy auth.json. The
/// Runtime never serializes token or API-key values across the native contract.
public struct RuntimeLegacyAuthCredential: Codable, Equatable, Identifiable, Sendable {
    public let providerId: String
    public let type: String
    public let status: String
    public var id: String { providerId }
}

public struct RuntimeLegacyAuthMigrationPreview: Codable, Equatable, Sendable {
    public let available: Bool
    public let source: String
    public let sourceExists: Bool
    public let eligible: Bool
    public let credentials: [RuntimeLegacyAuthCredential]
    public let issue: String?
}

public struct RuntimeLegacyAuthMigration: Codable, Equatable, Identifiable, Sendable {
    public struct Credential: Codable, Equatable, Identifiable, Sendable {
        public let providerId: String
        public let type: String
        public let created: Bool
        public var id: String { providerId }
    }
    public let id: String
    public let source: String
    public let createdAt: Date
    public let completedAt: Date?
    public let state: String
    public let credentials: [Credential]
    public let rollbackEligible: Bool
    public let error: String?
}

public struct RuntimeAuthChoice: Codable, Equatable, Identifiable, Sendable {
    public let value: String
    public let label: String
    public let description: String?
    public var id: String { value }
}

public struct RuntimeAuthPrompt: Codable, Equatable, Sendable {
    public let requestId: String
    public let message: String
    public let placeholder: String?
    public let allowEmpty: Bool?
    public let promptType: String?
    public let kind: String
}

public struct RuntimeAuthSelect: Codable, Equatable, Sendable {
    public let requestId: String
    public let message: String
    public let options: [RuntimeAuthChoice]
}

public struct RuntimeAuthLink: Codable, Equatable, Sendable {
    public let url: String
    public let label: String?
}

public struct RuntimeAuthFlow: Codable, Equatable, Identifiable, Sendable {
    public struct Authorization: Codable, Equatable, Sendable {
        public let url: String
        public let instructions: String?
        public let deviceCode: DeviceCode?
    }
    public struct DeviceCode: Codable, Equatable, Sendable {
        public let userCode: String
        public let intervalSeconds: Int?
        public let expiresInSeconds: Int?
    }
    public struct Info: Codable, Equatable, Sendable {
        public let message: String
        public let links: [RuntimeAuthLink]?
    }
    public let flowId: String
    public let providerId: String
    public let providerName: String
    public let status: String
    public let auth: Authorization?
    public let prompt: RuntimeAuthPrompt?
    public let select: RuntimeAuthSelect?
    public let progress: [String]
    public let info: [Info]?
    public let error: String?
    public var id: String { flowId }
}

public protocol RuntimeAuthClient: Sendable {
    func authProviders() async throws -> RuntimeAuthProviders
    func startOAuthLogin(providerId: String) async throws -> RuntimeAuthFlow
    func startInteractiveApiKeyLogin(providerId: String) async throws -> RuntimeAuthFlow
    func authFlow(id: String) async throws -> RuntimeAuthFlow
    func respondAuthFlow(id: String, requestId: String, value: String) async throws -> RuntimeAuthFlow
    func cancelAuthFlow(id: String) async throws -> RuntimeAuthFlow
    func legacyAuthMigrationPreview() async throws -> RuntimeLegacyAuthMigrationPreview
    func migrateLegacyAuth(providerIds: [String], commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func rollbackLegacyAuthMigration(id: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
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

/// A Runtime-owned entry choice used to fork a Pi thread. `entryId` is opaque
/// to Swift; the App presents the supplied label and returns the id unchanged.
public struct RuntimeForkCandidate: Codable, Equatable, Identifiable, Sendable {
    public let entryId: String
    public let label: String

    public var id: String { entryId }

    public init(entryId: String, label: String) {
        self.entryId = entryId
        self.label = label
    }
}

/// Model descriptor reported by the runtime's session model catalog and by
/// the session status projection. Every field is optional because providers
/// differ in what they report.
public struct RuntimeSessionModel: Decodable, Equatable, Sendable {
    public let provider: String?
    public let id: String?
    public let name: String?
    public let contextWindow: Int?
    public let reasoning: Bool?

    public init(
        provider: String? = nil,
        id: String? = nil,
        name: String? = nil,
        contextWindow: Int? = nil,
        reasoning: Bool? = nil
    ) {
        self.provider = provider
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.reasoning = reasoning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        // The wire type is `unknown`; accept the common boolean form and
        // ignore anything richer rather than failing the whole decode.
        reasoning = try? container.decode(Bool.self, forKey: .reasoning)
    }

    private enum CodingKeys: String, CodingKey {
        case provider, id, name, contextWindow, reasoning
    }
}

/// Minimal status projection used to know when a prompt has settled.
public struct RuntimeSessionStatus: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let runtimeId: String?
    public let model: RuntimeSessionModel?
    public let thinkingLevel: String?
    public let isStreaming: Bool
    public let isCompacting: Bool
    public let isBashRunning: Bool
    public let pendingMessageCount: Int
    public let messageCount: Int?

    public init(
        sessionId: String,
        runtimeId: String? = nil,
        model: RuntimeSessionModel? = nil,
        thinkingLevel: String? = nil,
        isStreaming: Bool,
        isCompacting: Bool,
        isBashRunning: Bool,
        pendingMessageCount: Int,
        messageCount: Int? = nil
    ) {
        self.sessionId = sessionId
        self.runtimeId = runtimeId
        self.model = model
        self.thinkingLevel = thinkingLevel
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
    public let images: [RuntimeMessageImage]

    public init(id: String, role: String, text: String, images: [RuntimeMessageImage] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            id = UUID().uuidString
            role = "message"
            text = value.transcriptText
            images = []
            return
        }
        id = fields["id"]?.stringValue ?? UUID().uuidString
        role = fields["role"]?.stringValue ?? fields["type"]?.stringValue ?? "message"
        let content = fields["content"]
        text = content?.transcriptText
            ?? fields["text"]?.stringValue
            ?? fields["message"]?.stringValue
            ?? ""
        images = content?.messageImages ?? []
    }
}

/// A Pi-inline image carried by a persisted transcript entry. The Runtime
/// delivers this through the existing session contract; Swift does not reopen
/// a workspace URL or receive a filesystem capability for it.
public struct RuntimeMessageImage: Decodable, Equatable, Sendable {
    public let mimeType: String
    public let data: String

    public var imageData: Data? { Data(base64Encoded: data) }
}

/// A user-selected Composer image. Its custom encoding deliberately matches
/// Pi's prompt attachment schema and omits the UI-only local id and byte count.
public struct RuntimePromptImageAttachment: Encodable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: String
    public let size: Int

    public init(id: UUID = UUID(), name: String, mimeType: String, data: String, size: Int) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.size = size
    }

    enum CodingKeys: String, CodingKey { case kind, name, mimeType, data }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("image", forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(data, forKey: .data)
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

/// Runtime-owned notification metadata. The message is supplied by a Pi
/// extension's explicit notify call; the native App never derives notification
/// text from a transcript or provider-private event payload.
public struct RuntimeSessionNotification: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let message: String
    public let truncated: Bool
    public let severity: String
    public let receivedAt: String
    public let order: Int
}

/// Bounded Runtime projection used to fetch the message behind a notification
/// summary. Its daemon instance id namespaces local OS-notification dedupe.
public struct RuntimeSessionNotificationInbox: Codable, Equatable, Sendable {
    public let daemonInstanceId: String
    public let catalogRevision: Int
    public let summary: Summary
    public let notifications: [RuntimeSessionNotification]

    public struct Summary: Codable, Equatable, Sendable {
        public let sessionId: String
        public let cwd: String
        public let inboxRevision: Int
        public let retainedCount: Int
        public let discardedCount: Int
        public let highestSeverity: String?
    }
}

/// The deliberately narrow event sent to the native notification subscriber.
/// It carries no transcript, tool, prompt, or provider data. The App uses it
/// only as a signal to reread the bounded inbox through the Runtime contract.
public struct RuntimeNotificationSummaryEvent: Codable, Equatable, Sendable {
    public let type: String
    public let daemonInstanceId: String
    public let catalogRevision: Int
    public let summary: RuntimeSessionNotificationInbox.Summary
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

    fileprivate var messageImages: [RuntimeMessageImage] {
        switch self {
        case let .array(values):
            return values.compactMap(\.asMessageImage)
        case .object:
            return asMessageImage.map { [$0] } ?? []
        default:
            return []
        }
    }

    private var asMessageImage: RuntimeMessageImage? {
        guard case let .object(fields) = self,
              fields["type"]?.stringValue == "image",
              let mimeType = fields["mimeType"]?.stringValue,
              let data = fields["data"]?.stringValue,
              !mimeType.isEmpty,
              !data.isEmpty
        else { return nil }
        return RuntimeMessageImage(mimeType: mimeType, data: data)
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
    /// Model catalog for this session's provider. Unlike the receipt-based
    /// mutations, model/thinking-level changes are direct calls that return
    /// the updated session status.
    func listModels(sessionId: String, cwd: String, runtimeId: String?) async throws -> [RuntimeSessionModel]
    func setModel(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        provider: String,
        modelId: String
    ) async throws -> RuntimeSessionStatus
    func listThinkingLevels(sessionId: String, cwd: String, runtimeId: String?) async throws -> [String]
    func setThinkingLevel(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        level: String
    ) async throws -> RuntimeSessionStatus
    /// Cycles to the next/previous model the provider offers. Direct call.
    func cycleModel(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        direction: String
    ) async throws -> RuntimeSessionStatus
    /// Cycles to the next thinking level (when the model supports it).
    func cycleThinkingLevel(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeSessionStatus
    /// Cancels the agent's in-flight work (prompt queue + current operation)
    /// without closing the session. Direct call, no receipt.
    func abort(sessionId: String, cwd: String, runtimeId: String?) async throws
    func prompt(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        text: String,
        attachments: [RuntimePromptImageAttachment],
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
    func forkCandidates(sessionId: String, cwd: String, runtimeId: String?) async throws -> [RuntimeForkCandidate]
    func forkSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        entryId: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func importSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        inputPath: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func abortActiveWork(commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func commandReceipt(commandId: String) async throws -> RuntimeCommandReceipt
}

/// Native Git projection. Node remains the only process that starts Git and
/// owns its credential/process environment; Swift only renders these values.
public struct RuntimeGitFile: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let oldPath: String?
    public let index: String
    public let workingTree: String
    public let submoduleFromCommit: String?
    public let submoduleToCommit: String?

    public var id: String { path }
}

public struct RuntimeGitStatus: Codable, Equatable, Sendable {
    public let isGitRepo: Bool
    public let hash: String
    public let branch: String?
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    public let files: [RuntimeGitFile]
    public let submodules: [String]
}

public struct RuntimeGitDiff: Codable, Equatable, Sendable {
    public let path: String?
    public let staged: Bool
    public let hash: String
    public let diff: String
    public let truncated: Bool
}

/// Fresh Runtime-owned policy for the only native push shape: the selected
/// branch to its existing tracking upstream. Swift cannot select a remote,
/// refspec, force option, tag, or set-upstream behavior.
public struct RuntimeGitPushPreview: Codable, Equatable, Sendable {
    public let status: RuntimeGitStatus
    public let canPush: Bool
    public let reason: String?
}

/// Runtime-owned policy for a history-preserving undo of exactly the latest
/// non-merge commit. Swift cannot choose an arbitrary ref or reset history.
public struct RuntimeGitRevertPreview: Codable, Equatable, Sendable {
    public struct Commit: Codable, Equatable, Sendable {
        public let hash: String
        public let subject: String
    }

    public let status: RuntimeGitStatus
    public let canRevert: Bool
    public let reason: String?
    public let commit: Commit?
}

/// A bounded review snapshot owned by the Runtime. It intentionally carries no
/// restore operation: viewing a Thread checkpoint must never mutate Git state.
public struct RuntimeGitCheckpointDiff: Codable, Equatable, Sendable {
    public let hash: String
    public let diff: String
    public let truncated: Bool
}

public struct RuntimeGitCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let cwd: String
    public let createdAt: Date
    public let status: RuntimeGitStatus
    public let unstaged: RuntimeGitCheckpointDiff
    public let staged: RuntimeGitCheckpointDiff
}

public protocol RuntimeGitClient: Sendable {
    func gitStatus(cwd: String) async throws -> RuntimeGitStatus
    func gitDiff(cwd: String, path: String?, staged: Bool) async throws -> RuntimeGitDiff
    func stageGitPaths(cwd: String, paths: [String], commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func unstageGitPaths(cwd: String, paths: [String], commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func commitGit(cwd: String, message: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func discardGitPaths(cwd: String, paths: [String], confirmed: Bool, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func gitPushPreview(cwd: String) async throws -> RuntimeGitPushPreview
    func pushGit(cwd: String, confirmed: Bool, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func gitRevertPreview(cwd: String) async throws -> RuntimeGitRevertPreview
    func revertGitHead(cwd: String, confirmed: Bool, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func gitCheckpoints(cwd: String, sessionId: String) async throws -> [RuntimeGitCheckpoint]
    func createGitCheckpoint(cwd: String, sessionId: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
}

/// Runtime-owned, read-only file projection for the explicitly authorized
/// project. Paths are workspace-relative and must never grant Swift direct
/// filesystem access outside the Native Contract.
public struct RuntimeWorkspaceTree: Codable, Equatable, Sendable {
    public let path: String
    public let entries: [RuntimeWorkspaceEntry]
    public let scannedAt: Date
    public let truncated: Bool
}

public struct RuntimeWorkspaceEntry: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let type: String
    public let size: Int
    public let modifiedAt: Date

    public var id: String { path }
    public var isDirectory: Bool { type == "directory" }
}

public struct RuntimeWorkspaceFile: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let language: String?
    public let mediaType: String?
    public let mimeType: String?
    public let encoding: String
    public let size: Int
    public let modifiedAt: Date
    public let content: String
    public let truncated: Bool
    public let binary: Bool

    public var id: String { path }
}

/// Bounded image data returned by the Runtime for an already-authorized
/// workspace path. The App receives bytes, not a filesystem URL, so image
/// rendering never expands Swift's filesystem authority.
public struct RuntimeWorkspaceImagePreview: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let mimeType: String
    public let size: Int
    public let modifiedAt: Date
    public let data: String

    public var id: String { path }
    public var imageData: Data? { Data(base64Encoded: data) }
}

public protocol RuntimeWorkspaceClient: Sendable {
    func workspaceTree(cwd: String, path: String?) async throws -> RuntimeWorkspaceTree
    func workspaceFile(cwd: String, path: String) async throws -> RuntimeWorkspaceFile
    func workspaceImagePreview(cwd: String, path: String) async throws -> RuntimeWorkspaceImagePreview
    func writeWorkspaceFile(cwd: String, path: String, content: String, overwrite: Bool, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func deleteWorkspaceFile(cwd: String, path: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
    func moveWorkspaceFile(cwd: String, fromPath: String, toPath: String, overwrite: Bool, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
}

public protocol RuntimeProjectCapabilityClient: Sendable {
    func authorizeProject(path: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt
}

public struct RuntimeLegacyProjectCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let createdAt: Date
}

public struct RuntimeLegacyProjectPreview: Codable, Equatable, Sendable {
    public let source: String
    public let sourceExists: Bool
    public let candidates: [RuntimeLegacyProjectCandidate]
    public let issue: String?
}

public protocol RuntimeLegacyProjectMigrationClient: Sendable {
    func legacyProjectMigrationPreview() async throws -> RuntimeLegacyProjectPreview
}

/// Redacted inventory of legacy PI WEB state and the native App action that is
/// safe for each item. It deliberately contains no machine token, unread
/// payload, project bookmark, or legacy file content.
public struct RuntimeLegacyMigrationOverviewItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let source: String
    public let sourceExists: Bool
    public let action: String
    public let itemCount: Int?
    public let issue: String?
}

public struct RuntimeLegacyMigrationOverview: Codable, Equatable, Sendable {
    public let legacyDataDir: String
    public let items: [RuntimeLegacyMigrationOverviewItem]
}

public protocol RuntimeLegacyMigrationOverviewClient: Sendable {
    func legacyMigrationOverview() async throws -> RuntimeLegacyMigrationOverview
}

/// Product projection of a pending Pi extension dialog. The App does not see
/// the SDK callback; it renders this data and returns a kind-compatible value.
public struct RuntimeExtensionInteraction: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let cwd: String
    public let kind: String
    public let title: String
    public let message: String?
    public let options: [String]?
    public let placeholder: String?
    public let prefill: String?
    public let createdAt: Date
    public let timeoutAt: Date?
}

public enum RuntimeExtensionInteractionResponse: Encodable, Equatable, Sendable {
    case cancelled
    case selected(String)
    case confirmed(Bool)
    case text(String)

    private enum CodingKeys: String, CodingKey { case cancelled, selected, confirmed, text }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cancelled: try container.encode(true, forKey: .cancelled)
        case let .selected(value): try container.encode(value, forKey: .selected)
        case let .confirmed(value): try container.encode(value, forKey: .confirmed)
        case let .text(value): try container.encode(value, forKey: .text)
        }
    }
}

public protocol RuntimeExtensionInteractionClient: Sendable {
    func listExtensionInteractions(sessionId: String, cwd: String, runtimeId: String?) async throws -> [RuntimeExtensionInteraction]
    func respondToExtensionInteraction(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        interactionId: String,
        response: RuntimeExtensionInteractionResponse,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
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
        public let forked: Bool?
        public let imported: Bool?
        public let session: RuntimeSession?
        public let promptDraft: String?
        public let continued: Bool?
        public let staged: Bool?
        public let unstaged: Bool?
        public let discarded: Bool?
        public let committed: Bool?
        public let reverted: Bool?
        public let pushed: Bool?
        public let paths: [String]?
        public let hash: String?
        public let subject: String?
        public let status: RuntimeGitStatus?
        public let checkpointed: Bool?
        public let checkpoint: RuntimeGitCheckpoint?
        public let responded: Bool?
        public let interaction: RuntimeExtensionInteraction?
        public let authorized: Bool?
        public let written: Bool?
        public let deletedFile: Bool?
        public let moved: Bool?
        public let migrated: Bool?
        public let rolledBack: Bool?
        public let migration: RuntimeLegacyAuthMigration?
        public let existed: Bool?
        public let fromPath: String?
        public let toPath: String?
        public let size: Int?
        public let modifiedAt: Date?
        /// Canonical real path returned only by the Runtime after it has accepted
        /// the App-selected project capability. This is never a capability token.
        public let path: String?
        public let terminal: RuntimeTerminalInfo?
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
    /// A terminal receipt recovered by the Runtime's private command ledger
    /// after a new epoch began. It proves the same command was not replayed.
    public let recoveredAfterRuntimeRestart: Bool?
}

/// Session event transport kept separate from the request client so tests and
/// future runtimes can provide only the capabilities they support.
public protocol RuntimeEventStreamClient: Sendable {
    func streamSnapshot(sessionId: String, cwd: String, runtimeId: String?) async throws -> RuntimeStreamSnapshot
    func subscribe(sessionId: String, cwd: String, runtimeId: String?) -> RuntimeEventSubscription
}

public protocol RuntimeNotificationClient: Sendable {
    func notificationInbox(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeSessionNotificationInbox
    func subscribeNotificationSummaries(cwd: String) -> RuntimeNotificationSubscription
}

public protocol RuntimeTerminalClient: Sendable {
    func listTerminals(cwd: String) async throws -> [RuntimeTerminalInfo]
    func createTerminal(
        cwd: String,
        name: String,
        cols: Int,
        rows: Int,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
    func continueTerminal(
        id: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt
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

/// A cancellable project-scoped notification summary stream. Runtime route
/// filtering and the App capability token ensure it cannot observe another
/// project's global events.
public final class RuntimeNotificationSubscription: @unchecked Sendable {
    public let events: AsyncThrowingStream<RuntimeNotificationSummaryEvent, Error>
    public let ready: AsyncThrowingStream<Void, Error>
    private let cancelAction: @Sendable () -> Void

    public init(
        events: AsyncThrowingStream<RuntimeNotificationSummaryEvent, Error>,
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
