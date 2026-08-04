import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm

@main
struct PiAgentApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate

    var body: some Scene {
        WindowGroup("Pi Agent") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    lifecycleDelegate.model = model
                }
                .alert(
                    "Agent sessions are still active",
                    isPresented: $model.showTerminationConfirmation
                ) {
                    Button("Keep Running and Quit") {
                        model.keepRuntimeRunningAndTerminate()
                    }
                    Button("Stop Runtime and Quit", role: .destructive) {
                        model.stopOwnedRuntimeAndTerminate()
                    }
                    Button("Cancel", role: .cancel) {
                        model.cancelTermination()
                    }
                } message: {
                    Text(model.terminationConfirmationMessage)
                }
                .alert(
                    "Delete archived thread permanently?",
                    isPresented: Binding(
                        get: { model.sessionPendingPermanentDeletion != nil },
                        set: { if !$0 { model.cancelPermanentDelete() } }
                    )
                ) {
                    Button("Delete Permanently", role: .destructive) {
                        model.confirmPermanentDelete()
                    }
                    Button("Cancel", role: .cancel) {
                        model.cancelPermanentDelete()
                    }
                } message: {
                    Text("This removes the archived transcript from Pi Agent storage and cannot be undone.")
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    model.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Open Project") {
                    model.openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Reconnect Runtime") {
                    model.refreshRuntime()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var runtimeState: RuntimeConnectionState = .disconnected
    @Published var projectPath: String
    @Published var selectedSessionID: String?
    @Published var showInspector = true
    @Published var prompt = ""
    @Published var sessions: [RuntimeSession] = []
    @Published var transcriptMessages: [RuntimeMessage] = []
    @Published var statusBySession: [String: RuntimeSessionStatus] = [:]
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var isProjectExpanded = true
    @Published var terminalInfo: RuntimeTerminalInfo?
    @Published var terminalErrorMessage: String?
    @Published var showTerminationConfirmation = false
    @Published var sessionPendingPermanentDeletion: RuntimeSession?

    let runtimeClient: any RuntimeClient
    let terminalSurfaceController = TerminalSurfaceController()
    private let runtimeSupervisor: RuntimeSupervisor?
    private let projectAuthorizationStore: ProjectAuthorizationStore
    private var projectAccess: ProjectAccess?

    private var sessionStreamTask: Task<Void, Never>?
    private var sessionEventSubscription: RuntimeEventSubscription?
    private var sessionStreamGeneration = 0
    private var lastSessionSequence = 0
    private var streamingMessage: RuntimeMessage?
    private var terminalTask: Task<Void, Never>?
    private var terminalSubscription: RuntimeTerminalSubscription?
    private var terminalCWD: String?
    private var terminationCheckInFlight = false
    private var terminationActiveSessionCount: Int?
    private var terminationAbortInFlight = false
    private var terminationAbortError: String?
    private var runtimeEpoch: String?

    init(
        runtimeClient: (any RuntimeClient)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectAuthorizationStore: ProjectAuthorizationStore = ProjectAuthorizationStore()
    ) {
        self.projectAuthorizationStore = projectAuthorizationStore
        if let runtimeClient {
            self.runtimeClient = runtimeClient
            runtimeSupervisor = nil
        } else {
            let connection = AppModel.makeRuntimeConnection(environment: environment)
            self.runtimeClient = connection.client
            runtimeSupervisor = connection.supervisor
            errorMessage = connection.startupError
        }
        let configuredPath: String
        if let explicitPath = environment["PI_AGENT_PROJECT_PATH"] ?? environment["PWD"] {
            configuredPath = explicitPath
        } else if let restoredProject = projectAuthorizationStore.restore() {
            projectAccess = restoredProject
            configuredPath = restoredProject.url.path
        } else {
            configuredPath = FileManager.default.currentDirectoryPath
        }
        projectPath = URL(fileURLWithPath: configuredPath).standardizedFileURL.path
    }

    var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    var selectedSession: RuntimeSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var activeSessions: [RuntimeSession] {
        sessions.filter { $0.archived != true }
    }

    var archivedSessions: [RuntimeSession] {
        sessions.filter { $0.archived == true }
    }

    var runtimeLabel: String {
        switch runtimeState {
        case .disconnected:
            return "Runtime disconnected"
        case .connecting:
            return "Connecting…"
        case let .connected(health):
            return health.version.label
        case let .failed(message):
            return "Runtime unavailable: \(message)"
        }
    }

    var terminationConfirmationMessage: String {
		if let terminationAbortError {
			return "The Runtime could not stop every active session: \(terminationAbortError) Keep it running and quit, try stopping it again, or cancel."
		}
        if let terminationActiveSessionCount {
            return "(terminationActiveSessionCount) active session\(terminationActiveSessionCount == 1 ? " is" : "s are") still running. Keep the bundled Runtime alive, stop only the Runtime this app owns, or cancel quitting."
        }
        return "The Runtime status could not be refreshed. Keep the bundled Runtime alive, stop only the Runtime this app owns, or cancel quitting."
    }

    /// Called synchronously from `NSApplicationDelegate`. The authoritative
    /// active-session count is fetched before choosing whether App termination
    /// may proceed, so a stale UI projection cannot silently stop work.
    func requestApplicationTermination() -> NSApplication.TerminateReply {
        guard runtimeSupervisor != nil else {
            // A development or externally supplied socket is never owned by
            // the App and must survive an App quit.
            return .terminateNow
        }
        guard !terminationCheckInFlight else { return .terminateLater }
        terminationCheckInFlight = true
        let client = runtimeClient
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await client.health()
                self.runtimeState = .connected(health)
                self.terminationCheckInFlight = false
                if health.activeSessions == 0 {
                    self.stopOwnedRuntimeAndTerminate()
                } else {
                    self.terminationActiveSessionCount = health.activeSessions
                    self.showTerminationConfirmation = true
                }
            } catch {
                self.terminationCheckInFlight = false
                self.terminationActiveSessionCount = nil
                self.showTerminationConfirmation = true
            }
        }
        return .terminateLater
    }

    func keepRuntimeRunningAndTerminate() {
        clearTerminationRequest()
        // `RuntimeSupervisor` only holds a `Process` it launched; intentionally
        // not calling stop preserves ongoing work after the native UI exits.
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func stopOwnedRuntimeAndTerminate() {
        guard !terminationAbortInFlight else { return }
        terminationAbortInFlight = true
        terminationAbortError = nil
        showTerminationConfirmation = false
        let client = runtimeClient
        let commandId = UUID().uuidString
        Task { [weak self] in
            guard let self else { return }
            do {
                let epoch = try await self.currentRuntimeEpoch(using: client)
                let receipt = try await client.abortActiveWork(
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "abort-active-work",
                    expectedRuntimeEpoch: epoch
                )
                guard receipt.status == "completed" else {
                    throw RuntimeClientError.serverError(
                        500,
                        receipt.error ?? "Runtime abort command failed."
                    )
                }
                if let failures = receipt.result?.failures, !failures.isEmpty {
                    throw RuntimeClientError.serverError(
                        500,
                        failures.map(\.error).joined(separator: "; ")
                    )
                }
                self.clearTerminationRequest()
                self.runtimeSupervisor?.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                self.terminationAbortInFlight = false
                self.terminationAbortError = error.localizedDescription
                self.showTerminationConfirmation = true
            }
        }
    }

    func cancelTermination() {
        clearTerminationRequest()
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    private func clearTerminationRequest() {
        terminationCheckInFlight = false
        terminationActiveSessionCount = nil
        terminationAbortInFlight = false
        terminationAbortError = nil
        showTerminationConfirmation = false
    }

    func refreshRuntime() {
        let client = runtimeClient
        let supervisor = runtimeSupervisor
        let cwd = projectPath
        isLoading = true
        errorMessage = nil
        runtimeState = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                let health: RuntimeHealth
                if let supervisor,
                   let helloClient = client as? any RuntimeHelloClient
                {
                    health = try await supervisor.ensureRunning(using: helloClient)
                } else {
                    health = try await client.health()
                }
                if let helloClient = client as? any RuntimeHelloClient {
                    let hello = try await helloClient.hello()
                    try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
                    self.runtimeEpoch = hello.runtimeEpoch
                } else {
                    self.runtimeEpoch = nil
                }
                let sessions = try await client.listSessions(cwd: cwd)
                self.runtimeState = .connected(health)
                self.replaceSessions(sessions)
                self.isLoading = false
            } catch {
                self.runtimeState = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.runtimeEpoch = nil
                self.isLoading = false
            }
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project"
        panel.message = "Choose the checkout Pi Agent should use for new and existing sessions."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = try projectAuthorizationStore.authorize(url)
            projectAccess = access
            projectPath = access.url.path
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        selectedSessionID = nil
        transcriptMessages = []
        statusBySession = [:]
        refreshRuntime()
    }

    func selectSession(_ sessionID: String?) {
        stopSessionEventStream()
        selectedSessionID = sessionID
        transcriptMessages = []
        streamingMessage = nil
        lastSessionSequence = 0
        errorMessage = nil
        guard sessionID != nil else { return }
        loadSelectedSession()
        if selectedSession?.archived != true {
            startSessionEventStream()
        }
    }

    func startNewSession() {
        let client = runtimeClient
        let cwd = projectPath
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "Reconnect the Runtime before creating a session."
            return
        }
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.startSession(
                        cwd: cwd,
                        runtimeId: nil,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "start-session",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.created == true,
                      let createdSessionID = receipt.result?.sessionId
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime session receipt was missing its created session result."
                    )
                }
                let createdCWD = receipt.result?.cwd ?? cwd
                let sessions = try await client.listSessions(cwd: createdCWD)
                guard let session = sessions.first(where: { $0.id == createdSessionID }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime created the session, but it was not present in the session projection. Reconnect to refresh it."
                    )
                }
                self.replaceSessions(sessions)
                self.isSending = false
                self.selectSession(session.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func sendPrompt() {
        guard let session = selectedSession else {
            errorMessage = "Select a session before sending a prompt."
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
		guard session.archived != true else {
			errorMessage = "Restore this archived thread before sending a prompt."
			return
		}

        let client = runtimeClient
        let cwd = projectPath
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "Reconnect the Runtime before sending a prompt."
            return
        }
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.prompt(
                        sessionId: session.id,
                        cwd: cwd,
                        runtimeId: session.runtimeId,
                        text: text,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "prompt",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.accepted == true,
                      receipt.result?.sessionId == session.id
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime prompt receipt was missing its accepted session result."
                    )
                }
                self.prompt = ""
                self.isSending = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func archiveSession(_ session: RuntimeSession) {
        performSessionMutation(
            session,
            kind: "archive-session",
            accepted: { $0.archived == true },
            execute: { client, commandId, epoch in
                try await client.archiveSession(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
            }
        )
    }

    func restoreSession(_ session: RuntimeSession) {
        performSessionMutation(
            session,
            kind: "restore-session",
            accepted: { $0.restored == true },
            execute: { client, commandId, epoch in
                try await client.restoreSession(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
            }
        )
    }

    func requestPermanentDelete(_ session: RuntimeSession) {
        guard session.archived == true, !isSending else { return }
        sessionPendingPermanentDeletion = session
    }

    func cancelPermanentDelete() {
        sessionPendingPermanentDeletion = nil
    }

    func confirmPermanentDelete() {
        guard let session = sessionPendingPermanentDeletion else { return }
        sessionPendingPermanentDeletion = nil
        performSessionMutation(
            session,
            kind: "delete-archived-session",
            accepted: { $0.deleted == true },
            selectMutatedSession: false,
            execute: { client, commandId, epoch in
                try await client.deleteArchivedSession(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
            }
        )
    }

    private func performSessionMutation(
        _ session: RuntimeSession,
        kind: String,
        accepted: @escaping @Sendable (RuntimeCommandReceipt.Result) -> Bool,
        selectMutatedSession: Bool = true,
        execute: @escaping @Sendable (any RuntimeClient, String, String) async throws -> RuntimeCommandReceipt
    ) {
        guard !isSending else { return }
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "Reconnect the Runtime before changing a thread."
            return
        }
        let client = runtimeClient
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await execute(client, commandId, expectedRuntimeEpoch)
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: kind,
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.sessionId == session.id,
                      let result = receipt.result,
                      accepted(result)
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime thread mutation receipt was missing its completed result."
                    )
                }
                let refreshed = try await client.listSessions(cwd: session.cwd)
                self.replaceSessions(refreshed)
                self.isSending = false
                if selectMutatedSession, self.sessions.contains(where: { $0.id == session.id }) {
                    self.selectSession(session.id)
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    private func currentRuntimeEpoch(using client: any RuntimeClient) async throws -> String {
        guard let helloClient = client as? any RuntimeHelloClient else {
            throw RuntimeClientError.incompatibleRuntime(
                "The connected Runtime does not expose a native identity handshake."
            )
        }
        let hello = try await helloClient.hello()
        try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
        runtimeEpoch = hello.runtimeEpoch
        return hello.runtimeEpoch
    }

    private func commandReceiptAfterUnknownTransport(
        client: any RuntimeClient,
        commandId: String,
        originalError: Error
    ) async throws -> RuntimeCommandReceipt {
        guard isUnknownCommandTransportError(originalError) else { throw originalError }
        return try await client.commandReceipt(commandId: commandId)
    }

    private func isUnknownCommandTransportError(_ error: Error) -> Bool {
        switch error {
        case RuntimeClientError.connectionFailed, RuntimeClientError.invalidHTTPResponse:
            return true
        default:
            return false
        }
    }

    private func requireCompletedReceipt(
        _ receipt: RuntimeCommandReceipt,
        kind: String,
        expectedRuntimeEpoch: String
    ) throws {
        guard receipt.kind == kind else {
            throw RuntimeClientError.serverError(500, "Runtime returned a receipt for the wrong command kind.")
        }
        guard receipt.runtimeEpoch == expectedRuntimeEpoch else {
            throw RuntimeClientError.incompatibleRuntime(
                "Runtime restarted while this command was in flight. Reconnect before trying again."
            )
        }
        guard receipt.status == "completed" else {
            throw RuntimeClientError.serverError(
                500,
                receipt.error ?? "Runtime command failed."
            )
        }
    }

    func refreshSelectedSession() {
        loadSelectedSession()
    }

    func ensureTerminalConnection() {
        guard let client = runtimeClient as? any RuntimeTerminalClient else {
            terminalErrorMessage = "This Runtime does not expose a terminal surface."
            return
        }
        if terminalCWD == projectPath && (terminalSubscription != nil || terminalTask != nil) { return }

        terminalTask?.cancel()
        terminalSubscription?.cancel()
        terminalTask = nil
        terminalSubscription = nil
        terminalInfo = nil
        terminalCWD = projectPath
        terminalErrorMessage = nil

        let cwd = projectPath
        terminalTask = Task { [weak self] in
            do {
                let existing = try await client.listTerminals(cwd: cwd)
                let terminal: RuntimeTerminalInfo
                if let existingTerminal = existing.first {
                    terminal = existingTerminal
                } else {
                    terminal = try await client.createTerminal(
                        cwd: cwd,
                        name: "Pi Agent Terminal",
                        cols: 120,
                        rows: 32
                    )
                }
                guard let self else { return }
                self.terminalInfo = terminal
                var reconnectDelay: UInt64 = 250_000_000
                while !Task.isCancelled && self.terminalCWD == cwd {
                    let subscription = client.subscribeTerminal(id: terminal.id, cols: 120, rows: 32)
                    self.terminalSubscription = subscription
                    do {
                        var connected = false
                        for try await _ in subscription.ready {
                            connected = true
                            break
                        }
                        guard connected else { throw RuntimeClientError.connectionFailed("terminal socket closed before handshake") }
                        self.terminalErrorMessage = nil
                        reconnectDelay = 250_000_000
                        for try await event in subscription.events {
                            guard self.terminalCWD == cwd else { return }
                            switch event.type {
                            case "output":
                                if let data = event.data { self.terminalSurfaceController.feed(data) }
                            case "exit":
                                self.terminalInfo = RuntimeTerminalInfo(
                                    id: terminal.id,
                                    cwd: terminal.cwd,
                                    name: terminal.name,
                                    createdAt: terminal.createdAt,
                                    exited: true,
                                    exitCode: event.exitCode,
                                    commandRunId: terminal.commandRunId
                                )
                            case "error":
                                self.terminalErrorMessage = event.message ?? "Terminal stream failed."
                            default:
                                break
                            }
                        }
                        throw RuntimeClientError.connectionFailed("terminal socket closed")
                    } catch is CancellationError {
                        subscription.cancel()
                        return
                    } catch {
                        subscription.cancel()
                        guard self.terminalCWD == cwd else { return }
                        self.terminalSubscription = nil
                        self.terminalErrorMessage = "Terminal reconnecting: \(error.localizedDescription)"
                        do {
                            try await Task.sleep(nanoseconds: reconnectDelay)
                        } catch {
                            return
                        }
                        reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
                    }
                }
            } catch is CancellationError {
                // Selection/project changes intentionally cancel the old PTY
                // attachment; the PTY itself remains owned by sessiond.
            } catch {
                self?.terminalErrorMessage = error.localizedDescription
                if self?.terminalCWD == cwd { self?.terminalTask = nil }
            }
        }
    }

    func reconnectTerminal() {
        terminalCWD = nil
        ensureTerminalConnection()
    }

    func sendTerminalInput(_ data: String) {
        terminalSubscription?.sendInput(data)
    }

    func resizeTerminal(cols: Int, rows: Int) {
        terminalSubscription?.resize(cols: cols, rows: rows)
    }

    func continueTerminal() {
        guard let client = runtimeClient as? any RuntimeTerminalClient,
              let terminal = terminalInfo,
              terminal.exited
        else { return }
        Task { [weak self] in
            do {
                let continued = try await client.continueTerminal(id: terminal.id)
                self?.terminalInfo = continued
                self?.ensureTerminalConnection()
            } catch {
                self?.terminalErrorMessage = error.localizedDescription
            }
        }
    }

    private func loadSelectedSession() {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        let cwd = session.cwd
        Task { [weak self] in
            do {
                let page = try await client.messages(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                let status = try? await client.status(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                guard let self else { return }
                self.mergeLoadedMessages(page.messages)
                self.synchronizeStreamingMessage()
                if let status { self.statusBySession[session.id] = status }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func startSessionEventStream() {
        stopSessionEventStream()
        guard let session = selectedSession,
              session.archived != true,
              let client = runtimeClient as? any RuntimeEventStreamClient
        else { return }

        sessionStreamGeneration += 1
        let generation = sessionStreamGeneration
        lastSessionSequence = 0
        streamingMessage = nil
        let cwd = session.cwd

        sessionStreamTask = Task { [weak self] in
            guard let self else { return }
            var reconnectDelay: UInt64 = 250_000_000
            while !Task.isCancelled && self.isCurrentSessionStream(generation, sessionID: session.id) {
                let subscription = client.subscribe(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                self.sessionEventSubscription = subscription
                do {
                    var connected = false
                    for try await _ in subscription.ready {
                        connected = true
                        break
                    }
                    guard connected else { throw RuntimeClientError.connectionFailed("session event socket closed before handshake") }

                    let snapshot = try await client.streamSnapshot(
                        sessionId: session.id,
                        cwd: cwd,
                        runtimeId: session.runtimeId
                    )
                    guard self.isCurrentSessionStream(generation, sessionID: session.id) else {
                        subscription.cancel()
                        return
                    }
                    self.applyStreamSnapshot(snapshot, sessionID: session.id)
                    reconnectDelay = 250_000_000

                    for try await event in subscription.events {
                        guard self.isCurrentSessionStream(generation, sessionID: session.id) else {
                            subscription.cancel()
                            return
                        }
                        self.applySessionEvent(event, sessionID: session.id)
                    }
                    throw RuntimeClientError.connectionFailed("session event socket closed")
                } catch is CancellationError {
                    subscription.cancel()
                    return
                } catch {
                    subscription.cancel()
                    guard self.isCurrentSessionStream(generation, sessionID: session.id) else { return }
                    self.errorMessage = "Session stream reconnecting: \(error.localizedDescription)"
                    do {
                        try await Task.sleep(nanoseconds: reconnectDelay)
                    } catch {
                        return
                    }
                    reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
                }
            }
        }
    }

    private func stopSessionEventStream() {
        sessionStreamGeneration += 1
        sessionStreamTask?.cancel()
        sessionEventSubscription?.cancel()
        sessionStreamTask = nil
        sessionEventSubscription = nil
    }

    private func isCurrentSessionStream(_ generation: Int, sessionID: String) -> Bool {
        generation == sessionStreamGeneration && selectedSessionID == sessionID
    }

    private func applyStreamSnapshot(_ snapshot: RuntimeStreamSnapshot, sessionID: String) {
        // A lower watermark means the daemon/runtime epoch changed. The
        // persisted history remains authoritative, so refresh it once and then
        // continue applying events from the new epoch.
        if snapshot.seq < lastSessionSequence {
            lastSessionSequence = 0
            loadSelectedSession()
        }
        lastSessionSequence = snapshot.seq
        streamingMessage = snapshot.partial
        synchronizeStreamingMessage()
    }

    private func applySessionEvent(_ event: RuntimeSessionEvent, sessionID: String) {
        if let sequence = event.seq {
            guard sequence > lastSessionSequence else { return }
            lastSessionSequence = sequence
        }

        switch event.type {
        case "message.append":
            if let message = event.message { upsertTranscript(message) }
        case "assistant.delta":
            appendAssistantDelta(event.text ?? "")
        case "assistant.thinking.delta":
            // Thinking is intentionally not rendered as transcript content;
            // the visible assistant text still arrives through assistant.delta.
            break
        case "message.end":
            if let message = event.message {
                upsertTranscript(message)
            } else {
                synchronizeStreamingMessage()
            }
            streamingMessage = nil
        case "status.update":
            if let status = event.status { statusBySession[sessionID] = status }
        case "session.name":
            updateSessionName(sessionID: event.sessionId ?? sessionID, name: event.name)
        case "session.created":
            if let session = event.session {
                upsertSession(session)
            }
        case "session.error":
            errorMessage = event.errorMessage ?? event.text ?? "The session reported an error."
        case "tool.start":
            if let toolCallId = event.toolCallId {
                upsertTranscript(RuntimeMessage(
                    id: "tool:\(toolCallId)",
                    role: "tool",
                    text: [event.toolName, event.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                ))
            }
        case "tool.update", "tool.end":
            if let toolCallId = event.toolCallId {
                upsertTranscript(RuntimeMessage(
                    id: "tool:\(toolCallId)",
                    role: "tool",
                    text: event.text ?? event.output ?? ""
                ))
            }
        case "shell.start":
            if let command = event.command, !command.isEmpty {
                upsertTranscript(RuntimeMessage(id: "shell:\(lastSessionSequence)", role: "shell", text: "$ \(command)"))
            }
        case "shell.chunk", "command.output":
            if let text = event.chunk ?? event.text, !text.isEmpty {
                upsertTranscript(RuntimeMessage(id: "shell:\(lastSessionSequence)", role: "shell", text: text))
            }
        default:
            break
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let current = streamingMessage {
            streamingMessage = RuntimeMessage(id: current.id, role: current.role, text: current.text + delta)
        } else {
            streamingMessage = RuntimeMessage(id: "streaming-assistant", role: "assistant", text: delta)
        }
        synchronizeStreamingMessage()
    }

    private func synchronizeStreamingMessage() {
        guard let streamingMessage else { return }
        transcriptMessages.removeAll { $0.id == streamingMessage.id }
        transcriptMessages.append(streamingMessage)
    }

    private func mergeLoadedMessages(_ loaded: [RuntimeMessage]) {
        var merged = loaded
        let loadedIDs = Set(loaded.map(\.id))
        for live in transcriptMessages where !loadedIDs.contains(live.id) {
            // Keep events that arrived while the history request was in
            // flight. Persisted messages normally have stable ids; the
            // role/text fallback prevents duplication for older Pi records
            // that do not carry an id.
            guard !merged.contains(where: { $0.id == live.id || ($0.role == live.role && $0.text == live.text) }) else { continue }
            merged.append(live)
        }
        transcriptMessages = merged
    }

    private func upsertTranscript(_ message: RuntimeMessage) {
        if let index = transcriptMessages.firstIndex(where: { $0.id == message.id }) {
            transcriptMessages[index] = message
        } else if message.id == "streaming-assistant" {
            transcriptMessages.removeAll { $0.role == "assistant" && $0.id == "streaming-assistant" }
            transcriptMessages.append(message)
        } else {
            transcriptMessages.append(message)
        }
    }

    private func upsertSession(_ session: RuntimeSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    private func updateSessionName(sessionID: String, name: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[index]
        sessions[index] = RuntimeSession(
            id: session.id,
            cwd: session.cwd,
            runtimeId: session.runtimeId,
            path: session.path,
            persisted: session.persisted,
            name: name,
            created: session.created,
            modified: session.modified,
            messageCount: session.messageCount,
            firstMessage: session.firstMessage,
            archived: session.archived,
            archivedAt: session.archivedAt
        )
    }

    private func replaceSessions(_ sessions: [RuntimeSession]) {
        let ordered = sessions.sorted { $0.modified > $1.modified }
        self.sessions = ordered
        if let selectedSessionID, ordered.contains(where: { $0.id == selectedSessionID }) {
            loadSelectedSession()
            if selectedSession?.archived != true { startSessionEventStream() }
        } else {
            stopSessionEventStream()
            self.selectedSessionID = ordered.first(where: { $0.archived != true })?.id ?? ordered.first?.id
            if self.selectedSessionID != nil {
                loadSelectedSession()
                if selectedSession?.archived != true { startSessionEventStream() }
            }
        }
    }

    private struct RuntimeConnection {
        let client: any RuntimeClient
        let supervisor: RuntimeSupervisor?
        let startupError: String?
    }

    private static func makeRuntimeConnection(environment: [String: String]) -> RuntimeConnection {
        if let socket = environment["PI_AGENT_RUNTIME_SOCKET"], !socket.isEmpty {
            return RuntimeConnection(
                client: UnixSocketRuntimeClient(socketPath: socket),
                supervisor: nil,
                startupError: nil
            )
        }
        do {
            if let bundledRuntime = try BundledRuntime.discover(environment: environment) {
                return RuntimeConnection(
                    client: UnixSocketRuntimeClient(socketPath: bundledRuntime.launchPlan.socketPath),
                    supervisor: bundledRuntime.makeSupervisor(),
                    startupError: nil
                )
            }
        } catch {
            return RuntimeConnection(
                client: UnavailableRuntimeClient(message: error.localizedDescription),
                supervisor: nil,
                startupError: error.localizedDescription
            )
        }

        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            let message = "Pi Agent.app is missing its bundled Runtime. Rebuild the app instead of connecting to a global daemon."
            return RuntimeConnection(
                client: UnavailableRuntimeClient(message: message),
                supervisor: nil,
                startupError: message
            )
        }

        let developmentSocket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi-web/sessiond.sock")
            .path
        return RuntimeConnection(
            client: UnixSocketRuntimeClient(socketPath: developmentSocket),
            supervisor: nil,
            startupError: nil
        )
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        model?.requestApplicationTermination() ?? .terminateNow
    }
}

private struct UnavailableRuntimeClient: RuntimeClient {
    let message: String

    func health() async throws -> RuntimeHealth { throw RuntimeClientError.connectionFailed(message) }
    func listSessions(cwd _: String) async throws -> [RuntimeSession] { throw RuntimeClientError.connectionFailed(message) }
    func startSession(
        cwd _: String,
        runtimeId _: String?,
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func messages(sessionId _: String, cwd _: String, runtimeId _: String?) async throws -> RuntimeMessagePage { throw RuntimeClientError.connectionFailed(message) }
    func status(sessionId _: String, cwd _: String, runtimeId _: String?) async throws -> RuntimeSessionStatus { throw RuntimeClientError.connectionFailed(message) }
    func prompt(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        text _: String,
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func archiveSession(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func restoreSession(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func deleteArchivedSession(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func abortActiveWork(
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func commandReceipt(commandId _: String) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            TranscriptView(model: model)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(model.projectName)
                        .font(.subheadline.weight(.semibold))
                    Text(model.runtimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshRuntime()
                } label: {
                    Label("Reconnect Runtime", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .task {
            model.refreshRuntime()
            model.ensureTerminalConnection()
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedSessionID },
            set: { model.selectSession($0) }
        )) {
            Section("Projects") {
                DisclosureGroup(isExpanded: $model.isProjectExpanded) {
                    if model.activeSessions.isEmpty {
                        Label(
                            model.isLoading ? "Loading…" : "No active threads yet",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.activeSessions) { session in
                            SessionRow(session: session, status: model.statusBySession[session.id])
                                .padding(.leading, 12)
                                .tag(Optional(session.id))
                                .contextMenu {
                                    Button("Archive Thread") {
                                        model.archiveSession(session)
                                    }
                                    .disabled(model.isSending)
                                }
                        }
                    }
                    if !model.archivedSessions.isEmpty {
                        Divider()
                        Text("Archived")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                        ForEach(model.archivedSessions) { session in
                            SessionRow(session: session, status: nil)
                                .padding(.leading, 12)
                                .tag(Optional(session.id))
                                .contextMenu {
                                    Button("Restore Thread") {
                                        model.restoreSession(session)
                                    }
                                    .disabled(model.isSending)
                                    Divider()
                                    Button("Delete Permanently…", role: .destructive) {
                                        model.requestPermanentDelete(session)
                                    }
                                    .disabled(model.isSending)
                                }
                        }
                    }
                } label: {
                    Button {
                        model.openProject()
                    } label: {
                        Label(model.projectName, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Pi Agent")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.startNewSession) {
                    Label("New Thread", systemImage: "plus")
                }
                .disabled(model.isSending || model.projectPath.isEmpty)
            }
        }
    }
}

struct SessionRow: View {
    let session: RuntimeSession
    let status: RuntimeSessionStatus?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.runtimeId.uppercased())
                    Text("·")
                    Text(session.archived == true ? "Archived" : statusLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: session.archived == true ? "archivebox" : (status?.isStreaming == true ? "circle.dotted" : "circle"))
                .foregroundStyle(session.archived == true ? Color.secondary : (status?.isStreaming == true ? Color.orange : Color.secondary))
        }
    }

    private var statusLabel: String {
        if status?.isStreaming == true { return "Running" }
        if status?.isCompacting == true { return "Compacting" }
        return "Ready"
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { model.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .padding(12)
                .background(.yellow.opacity(0.14))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let session = model.selectedSession {
                        Text(session.displayTitle)
                            .font(.title2.weight(.semibold))
                        Text("\(session.runtimeId.uppercased()) · \(session.messageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if session.archived == true {
                            Label("Archived threads are read-only. Restore this thread to continue it.", systemImage: "archivebox")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.transcriptMessages.isEmpty {
                            Text(session.firstMessage.isEmpty ? "No transcript messages yet." : session.firstMessage)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            ForEach(Array(model.transcriptMessages.enumerated()), id: \.offset) { _, message in
                                MessageRow(message: message)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Select a session",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Choose an existing session or create a new one for this project.")
                        )
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(32)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask Pi Agent…", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) { model.sendPrompt() }
                    }
                Button(model.isSending ? "Sending…" : "Send") {
                    model.sendPrompt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedSession == nil
                        || model.selectedSession?.archived == true
                        || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSending
                )
            }
            .padding(16)
        }
    }
}

struct MessageRow: View {
    let message: RuntimeMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty ? "(non-text message)" : message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Environment") {
                LabeledContent("Project", value: model.projectName)
                LabeledContent("Path", value: model.projectPath)
                LabeledContent("Runtime", value: model.runtimeLabel)
            }
            Section("Session") {
                LabeledContent("Count", value: String(model.sessions.count))
                if let session = model.selectedSession {
                    LabeledContent("Runtime", value: session.runtimeId.uppercased())
                    LabeledContent("Messages", value: String(session.messageCount))
                    if let status = model.statusBySession[session.id] {
                        LabeledContent("State", value: status.isStreaming ? "Running" : "Ready")
                        LabeledContent("Queued", value: String(status.pendingMessageCount))
                    }
                } else {
                    Text("No session selected")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Workspace") {
                Label("Changes", systemImage: "square.and.pencil")
                Label("Files", systemImage: "doc")
            }
            Section("Terminal") {
                if let terminal = model.terminalInfo {
                    HStack {
                        Label(terminal.name, systemImage: "terminal")
                            .lineLimit(1)
                        Spacer()
                        if terminal.exited {
                            Button("Continue") { model.continueTerminal() }
                                .buttonStyle(.borderless)
                        }
                    }
                    TerminalSurfaceView(
                        controller: model.terminalSurfaceController,
                        onInput: model.sendTerminalInput,
                        onResize: model.resizeTerminal(cols:rows:)
                    )
                    .frame(minHeight: 220, idealHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Label(
                        model.terminalErrorMessage ?? "Connecting…",
                        systemImage: "terminal"
                    )
                    .foregroundStyle(.secondary)
                }
                if let terminalErrorMessage = model.terminalErrorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Text(terminalErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reconnect") { model.reconnectTerminal() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Inspector")
        .task { model.ensureTerminalConnection() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Runtime") {
                Text("The native shell connects to the existing PI WEB session daemon through its user-owned Unix socket.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: model.runtimeLabel)
                LabeledContent("Socket", value: model.runtimeClientSocketDescription)
            }
            Section("Project") {
                LabeledContent("Current", value: model.projectPath)
                Button("Choose Project…") { model.openProject() }
            }
        }
        .padding()
        .frame(width: 520)
    }
}

private extension AppModel {
    var runtimeClientSocketDescription: String {
        if let client = runtimeClient as? UnixSocketRuntimeClient { return client.socketPath }
        return "Configured Runtime client"
    }
}

@MainActor
final class TerminalSurfaceController: ObservableObject {
    weak var view: TerminalView?
    private var pendingOutput: [String] = []

    func attach(_ view: TerminalView) {
        self.view = view
        flush()
    }

    func feed(_ output: String) {
        guard !output.isEmpty else { return }
        if view == nil {
            pendingOutput.append(output)
            if pendingOutput.count > 64 { pendingOutput.removeFirst(pendingOutput.count - 64) }
            return
        }
        view?.feed(byteArray: Array(output.utf8)[...])
    }

    private func flush() {
        guard view != nil else { return }
        let output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: false)
        for chunk in output { view?.feed(byteArray: Array(chunk.utf8)[...]) }
    }
}

struct TerminalSurfaceView: NSViewRepresentable {
    @ObservedObject var controller: TerminalSurfaceController
    let onInput: (String) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = context.coordinator
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.terminalDelegate = context.coordinator
        controller.attach(nsView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let onInput: (String) -> Void
        private let onResize: (Int, Int) -> Void

        init(onInput: @escaping (String) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(String(decoding: data, as: UTF8.self))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {}
    }
}
