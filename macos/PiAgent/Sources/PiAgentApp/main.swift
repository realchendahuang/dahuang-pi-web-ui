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
                .alert(
                    "Delete workspace file?",
                    isPresented: Binding(
                        get: { model.workspaceFilePendingDeletion != nil },
                        set: { if !$0 { model.cancelWorkspaceFileDeletion() } }
                    )
                ) {
                    Button("Delete File", role: .destructive) {
                        model.confirmWorkspaceFileDeletion()
                    }
                    Button("Cancel", role: .cancel) {
                        model.cancelWorkspaceFileDeletion()
                    }
                } message: {
                    Text("This permanently removes the selected file from the authorized project.")
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
	private enum ProjectRuntimeAuthorization: Equatable {
		case notRequired
		case authorizing
		case authorized(path: String)
		case failed(message: String)

		var label: String {
			switch self {
			case .notRequired: return "Not required for this Runtime"
			case .authorizing: return "Authorizing…"
			case let .authorized(path): return "Authorized: \(path)"
			case let .failed(message): return "Authorization failed: \(message)"
			}
		}

		var permitsProjectOperations: Bool {
			switch self {
			case .notRequired, .authorized: return true
			case .authorizing, .failed: return false
			}
		}
	}

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
    @Published var isTerminalMutationInFlight = false
    @Published var showTerminationConfirmation = false
    @Published var sessionPendingPermanentDeletion: RuntimeSession?
    @Published var sessionPendingFork: RuntimeSession?
    @Published var forkCandidates: [RuntimeForkCandidate] = []
	@Published var gitStatus: RuntimeGitStatus?
    @Published var gitSelectedPath: String?
    @Published var gitUnstagedDiff: RuntimeGitDiff?
    @Published var gitStagedDiff: RuntimeGitDiff?
    @Published var isGitLoading = false
    @Published var isGitMutationInFlight = false
    @Published var showGitCommitSheet = false
    @Published var workspaceTree: RuntimeWorkspaceTree?
    @Published var workspacePath = ""
    @Published var workspaceFile: RuntimeWorkspaceFile?
    @Published var workspaceImagePreview: RuntimeWorkspaceImagePreview?
    @Published var workspaceImagePreviewError: String?
    @Published var isWorkspaceLoading = false
    @Published var workspaceErrorMessage: String?
    @Published var workspaceEditorText = ""
    @Published var isWorkspaceMutationInFlight = false
    @Published var workspaceFilePendingDeletion: RuntimeWorkspaceFile?
    @Published var workspaceFilePendingMove: RuntimeWorkspaceFile?
    @Published var workspaceMoveDestination = ""
    @Published var showWorkspaceNewFileSheet = false
    @Published var workspaceNewFilePath = ""
    @Published var authProviders: [RuntimeAuthProvider] = []
    @Published var isAuthLoading = false
    @Published var authErrorMessage: String?
    @Published var activeAuthFlow: RuntimeAuthFlow?
    @Published var authInput = ""
    @Published var gitCommitMessage = ""
	@Published var extensionInteractions: [RuntimeExtensionInteraction] = []
	@Published var isExtensionInteractionMutationInFlight = false
	@Published var extensionInteractionText = ""
	@Published private var projectRuntimeAuthorization: ProjectRuntimeAuthorization = .notRequired

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
    private var runtimeRefreshGeneration = RuntimeRefreshGeneration()
    private var runtimeRecovery = RuntimeLifecycleRecovery()
    private var runtimeRecoveryTask: Task<Void, Never>?
    private var workspaceRequestGeneration = 0
    private var terminationCheckInFlight = false
    private var terminationActiveSessionCount: Int?
    private var terminationAbortInFlight = false
    private var terminationAbortError: String?
    private var runtimeEpoch: String?
    private var authPollingTask: Task<Void, Never>?

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

	var activeExtensionInteraction: RuntimeExtensionInteraction? {
		guard let session = selectedSession else { return nil }
		return extensionInteractions.first { $0.sessionId == session.id && $0.cwd == session.cwd }
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

	var projectRuntimeAuthorizationLabel: String {
		projectRuntimeAuthorization.label
	}

	var canUseProjectRuntime: Bool {
		projectRuntimeAuthorization.permitsProjectOperations
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

    func refreshRuntime(cancellingScheduledRecovery: Bool = true) {
        let client = runtimeClient
        let supervisor = runtimeSupervisor
        let cwd = projectPath
        if cancellingScheduledRecovery {
            cancelOwnedRuntimeRecovery()
        }
        let refreshToken = runtimeRefreshGeneration.begin(cwd: cwd)
        isLoading = true
        errorMessage = nil
        runtimeState = .connecting
        runtimeEpoch = nil
        let capabilityClient = client as? any RuntimeProjectCapabilityClient
        projectRuntimeAuthorization = capabilityClient == nil ? .notRequired : .authorizing
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
                let epoch: String?
                if let helloClient = client as? any RuntimeHelloClient {
                    let hello = try await helloClient.hello()
                    try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
                    epoch = hello.runtimeEpoch
                } else {
                    epoch = nil
                }
                if let capabilityClient,
                   let epoch
                {
                    let commandId = UUID().uuidString
                    let receipt = try await capabilityClient.authorizeProject(
                        path: cwd,
                        commandId: commandId,
                        expectedRuntimeEpoch: epoch
                    )
                    try self.requireCompletedReceipt(
                        receipt,
                        kind: "authorize-project",
                        expectedRuntimeEpoch: epoch
                    )
                    guard receipt.result?.authorized == true,
                          let authorizedPath = receipt.result?.path,
                          !authorizedPath.isEmpty
                    else {
                        throw RuntimeClientError.serverError(
                            500,
                            "Runtime did not authorize the selected project."
                        )
                    }
                    guard self.isCurrentRuntimeRefresh(refreshToken, cwd: cwd) else { return }
                    self.projectRuntimeAuthorization = .authorized(path: authorizedPath)
                }
                let sessions = try await client.listSessions(cwd: cwd)
                guard self.isCurrentRuntimeRefresh(refreshToken, cwd: cwd) else { return }
                self.runtimeEpoch = epoch
                self.runtimeState = .connected(health)
                self.replaceSessions(sessions)
                self.isLoading = false
                // A Runtime restart invalidates any terminal WebSocket. A
                // reconnect always reads the authoritative terminal list.
                self.stopTerminalConnection()
                self.ensureTerminalConnection()
                self.refreshGit()
                self.refreshWorkspace()
                self.refreshAuthProviders()
            } catch {
                guard self.isCurrentRuntimeRefresh(refreshToken, cwd: cwd) else { return }
                if capabilityClient != nil {
                    self.projectRuntimeAuthorization = .failed(message: error.localizedDescription)
                }
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
        stopSessionEventStream()
        stopTerminalConnection()
        selectedSessionID = nil
        transcriptMessages = []
        statusBySession = [:]
		gitStatus = nil
        gitSelectedPath = nil
        gitUnstagedDiff = nil
        gitStagedDiff = nil
        workspaceTree = nil
        workspacePath = ""
        workspaceFile = nil
        workspaceEditorText = ""
        workspaceFilePendingDeletion = nil
        workspaceFilePendingMove = nil
        workspaceMoveDestination = ""
        showWorkspaceNewFileSheet = false
        workspaceNewFilePath = ""
        workspaceErrorMessage = nil
        authProviders = []
        authErrorMessage = nil
        refreshRuntime()
    }

    /// The App remains a UI client while macOS sleeps. Stop its socket readers
    /// rather than ending work; the Runtime process and its Pi sessions retain
    /// ownership and are reconciled after wake.
    func systemWillSleep() {
        guard runtimeRecovery.prepareForSleep() else { return }
        runtimeRefreshGeneration.invalidate()
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = nil
        stopSessionEventStream()
        stopTerminalConnection()
        runtimeEpoch = nil
        isLoading = false
        runtimeState = .disconnected
    }

    func systemDidWake() {
        guard runtimeRecovery.recoverAfterWake() else { return }
        refreshRuntime(cancellingScheduledRecovery: false)
    }

    func selectSession(_ sessionID: String?) {
        stopSessionEventStream()
        selectedSessionID = sessionID
        transcriptMessages = []
		extensionInteractions = []
		extensionInteractionText = ""
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
		guard canUseProjectRuntime else {
			errorMessage = "Authorize the selected project before creating a thread."
			return
		}
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
		guard canUseProjectRuntime else {
			errorMessage = "Authorize the selected project before sending a prompt."
			return
		}
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

    func requestFork(_ session: RuntimeSession) {
        guard session.archived != true, !isSending else { return }
        guard runtimeEpoch != nil else {
            errorMessage = "Reconnect the Runtime before forking a thread."
            return
        }
        let client = runtimeClient
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                // Candidate selection is read-only. The selected entry is
                // still revalidated by the Runtime when the receipt-safe fork
                // mutation runs, so a stale sheet cannot fork an arbitrary entry.
                let candidates = try await client.forkCandidates(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId
                )
                guard !candidates.isEmpty else {
                    throw RuntimeClientError.serverError(
                        400,
                        "This thread has no user message to fork from."
                    )
                }
                self.forkCandidates = candidates
                self.sessionPendingFork = session
                self.isSending = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func cancelFork() {
        sessionPendingFork = nil
        forkCandidates = []
    }

    func forkSession(_ session: RuntimeSession, from candidate: RuntimeForkCandidate) {
        guard !isSending else { return }
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "Reconnect the Runtime before forking a thread."
            return
        }
        let client = runtimeClient
        let commandId = UUID().uuidString
        sessionPendingFork = nil
        forkCandidates = []
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.forkSession(
                        sessionId: session.id,
                        cwd: session.cwd,
                        runtimeId: session.runtimeId,
                        entryId: candidate.entryId,
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
                    kind: "fork-session",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.forked == true,
                      let forked = receipt.result?.session
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime fork receipt was missing its forked session result."
                    )
                }
                let refreshed = try await client.listSessions(cwd: forked.cwd)
                guard refreshed.contains(where: { $0.id == forked.id }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime forked the thread, but it was not present in the session projection. Reconnect to refresh it."
                    )
                }
                self.replaceSessions(refreshed)
                self.isSending = false
                self.selectSession(forked.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func importSessionFromFile() {
        guard let session = selectedSession else {
            errorMessage = "Select an active thread before importing a session."
            return
        }
        guard session.archived != true else {
            errorMessage = "Restore this archived thread before importing a session."
            return
        }
        guard !isSending else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "Import Thread"
        panel.message = "Choose a Pi session JSONL file. Pi Agent imports a copy into this project's session storage."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performSessionImport(session, inputPath: url.path)
    }

    private func performSessionImport(_ session: RuntimeSession, inputPath: String) {
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "Reconnect the Runtime before importing a session."
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
                    receipt = try await client.importSession(
                        sessionId: session.id,
                        cwd: session.cwd,
                        runtimeId: session.runtimeId,
                        inputPath: inputPath,
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
                    kind: "import-session",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.imported == true,
                      let imported = receipt.result?.session
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime import receipt was missing its imported session result."
                    )
                }
                let refreshed = try await client.listSessions(cwd: imported.cwd)
                guard refreshed.contains(where: { $0.id == imported.id }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime imported the thread, but it was not present in the session projection. Reconnect to refresh it."
                    )
                }
                self.replaceSessions(refreshed)
                self.isSending = false
                self.selectSession(imported.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
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

	func refreshGit() {
		guard let client = runtimeClient as? any RuntimeGitClient else {
			gitStatus = nil
			return
		}
		let cwd = projectPath
		isGitLoading = true
		Task { [weak self] in
			guard let self else { return }
			do {
				let status = try await client.gitStatus(cwd: cwd)
				guard self.projectPath == cwd else { return }
				self.gitStatus = status
				self.isGitLoading = false
				if let selected = self.gitSelectedPath,
				   !status.files.contains(where: { $0.path == selected }) {
					self.gitSelectedPath = nil
					self.gitUnstagedDiff = nil
					self.gitStagedDiff = nil
				}
			} catch {
				guard self.projectPath == cwd else { return }
				self.isGitLoading = false
				self.errorMessage = error.localizedDescription
			}
		}
	}

	func selectGitPath(_ path: String) {
		guard let client = runtimeClient as? any RuntimeGitClient else { return }
		gitSelectedPath = path
		gitUnstagedDiff = nil
		gitStagedDiff = nil
		let cwd = projectPath
		Task { [weak self] in
			guard let self else { return }
			do {
				async let unstaged = client.gitDiff(cwd: cwd, path: path, staged: false)
				async let staged = client.gitDiff(cwd: cwd, path: path, staged: true)
				let (unstagedResult, stagedResult) = try await (unstaged, staged)
				guard self.projectPath == cwd, self.gitSelectedPath == path else { return }
				self.gitUnstagedDiff = unstagedResult
				self.gitStagedDiff = stagedResult
			} catch {
				guard self.projectPath == cwd, self.gitSelectedPath == path else { return }
				self.errorMessage = error.localizedDescription
			}
		}
	}

	func stageGitPath(_ path: String) { performGitPathMutation(path, kind: "stage-git-paths", accepted: { $0.staged == true }) { client, cwd, paths, commandId, epoch in
		try await client.stageGitPaths(cwd: cwd, paths: paths, commandId: commandId, expectedRuntimeEpoch: epoch)
	} }

	func unstageGitPath(_ path: String) { performGitPathMutation(path, kind: "unstage-git-paths", accepted: { $0.unstaged == true }) { client, cwd, paths, commandId, epoch in
		try await client.unstageGitPaths(cwd: cwd, paths: paths, commandId: commandId, expectedRuntimeEpoch: epoch)
	} }

	func requestGitCommit() {
		guard gitStatus?.isGitRepo == true, !isGitMutationInFlight else { return }
		showGitCommitSheet = true
	}

	func cancelGitCommit() {
		showGitCommitSheet = false
		gitCommitMessage = ""
	}

	func commitGit() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let expectedRuntimeEpoch = runtimeEpoch
		else { errorMessage = "Reconnect the Runtime before committing changes."; return }
		let message = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !message.isEmpty else { errorMessage = "Commit message is required."; return }
		let cwd = projectPath
		let commandId = UUID().uuidString
		isGitMutationInFlight = true
		showGitCommitSheet = false
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do { receipt = try await client.commitGit(cwd: cwd, message: message, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch) }
				catch { receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error) }
				try self.requireCompletedReceipt(receipt, kind: "commit-git", expectedRuntimeEpoch: expectedRuntimeEpoch)
				guard receipt.result?.committed == true, let status = receipt.result?.status else {
					throw RuntimeClientError.serverError(500, "Runtime commit receipt was missing its Git status projection.")
				}
				self.gitStatus = status
				self.gitCommitMessage = ""
				self.isGitMutationInFlight = false
				self.selectGitPath(self.gitSelectedPath ?? "")
			} catch {
				self.errorMessage = error.localizedDescription
				self.isGitMutationInFlight = false
			}
		}
	}

	private func performGitPathMutation(
		_ path: String,
		kind: String,
		accepted: @escaping @Sendable (RuntimeCommandReceipt.Result) -> Bool,
		execute: @escaping @Sendable (any RuntimeGitClient, String, [String], String, String) async throws -> RuntimeCommandReceipt
	) {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let expectedRuntimeEpoch = runtimeEpoch,
			  !isGitMutationInFlight
		else { errorMessage = "Reconnect the Runtime before changing Git state."; return }
		let cwd = projectPath
		let commandId = UUID().uuidString
		isGitMutationInFlight = true
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do { receipt = try await execute(client, cwd, [path], commandId, expectedRuntimeEpoch) }
				catch { receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error) }
				try self.requireCompletedReceipt(receipt, kind: kind, expectedRuntimeEpoch: expectedRuntimeEpoch)
				guard let result = receipt.result, accepted(result) else {
					throw RuntimeClientError.serverError(500, "Runtime Git receipt was missing its completion result.")
				}
				guard let status = receipt.result?.status else {
					throw RuntimeClientError.serverError(500, "Runtime Git receipt was missing its Git status projection.")
				}
				self.gitStatus = status
				self.isGitMutationInFlight = false
				self.selectGitPath(path)
			} catch {
				self.errorMessage = error.localizedDescription
				self.isGitMutationInFlight = false
			}
		}
	}

    func refreshSelectedSession() {
        loadSelectedSession()
    }

    func refreshWorkspace(path: String? = nil) {
        guard canUseProjectRuntime,
              let client = runtimeClient as? any RuntimeWorkspaceClient
        else { return }
        let cwd = projectPath
        let requestedPath = path ?? workspacePath
        workspaceRequestGeneration += 1
        let generation = workspaceRequestGeneration
        isWorkspaceLoading = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            do {
                let tree = try await client.workspaceTree(cwd: cwd, path: requestedPath)
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceTree = tree
                self.workspacePath = tree.path
                self.workspaceFile = nil
                self.workspaceImagePreview = nil
                self.workspaceImagePreviewError = nil
                self.workspaceEditorText = ""
                self.isWorkspaceLoading = false
            } catch {
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceLoading = false
            }
        }
    }

    func refreshAuthProviders() {
        guard canUseProjectRuntime,
              let client = runtimeClient as? any RuntimeAuthClient
        else { return }
        isAuthLoading = true
        authErrorMessage = nil
        Task { [weak self] in
            do {
                let response = try await client.authProviders()
                guard let self else { return }
                self.authProviders = response.providers
                self.isAuthLoading = false
            } catch {
                guard let self else { return }
                self.authErrorMessage = error.localizedDescription
                self.isAuthLoading = false
            }
        }
    }

    func startAuthFlow(_ provider: RuntimeAuthProvider) {
        guard let client = runtimeClient as? any RuntimeAuthClient, !isAuthLoading else { return }
        isAuthLoading = true
        authErrorMessage = nil
        Task { [weak self] in
            do {
                let flow = try await (provider.authType == "oauth" ? client.startOAuthLogin(providerId: provider.id) : client.startInteractiveApiKeyLogin(providerId: provider.id))
                guard let self else { return }
                self.activeAuthFlow = flow
                self.authInput = ""
                self.isAuthLoading = false
                self.startAuthPolling(flow)
            } catch {
                self?.authErrorMessage = error.localizedDescription
                self?.isAuthLoading = false
            }
        }
    }

    func refreshAuthFlow() {
        guard let flow = activeAuthFlow, let client = runtimeClient as? any RuntimeAuthClient else { return }
        Task { [weak self] in
            do { self?.applyAuthFlow(try await client.authFlow(id: flow.flowId)) }
            catch { self?.authErrorMessage = error.localizedDescription }
        }
    }

    func respondToAuthFlow(_ value: String? = nil) {
        guard let flow = activeAuthFlow, let client = runtimeClient as? any RuntimeAuthClient,
              let requestId = flow.prompt?.requestId ?? flow.select?.requestId else { return }
        let submitted = value ?? authInput
        Task { [weak self] in
            do {
                let updated = try await client.respondAuthFlow(id: flow.flowId, requestId: requestId, value: submitted)
                self?.applyAuthFlow(updated)
                self?.authInput = ""
                if updated.status == "complete" { self?.refreshAuthProviders() }
            } catch { self?.authErrorMessage = error.localizedDescription }
        }
    }

    func cancelAuthFlow() {
        authPollingTask?.cancel()
        authPollingTask = nil
        guard let flow = activeAuthFlow, let client = runtimeClient as? any RuntimeAuthClient else { activeAuthFlow = nil; return }
        Task { [weak self] in
            _ = try? await client.cancelAuthFlow(id: flow.flowId)
            self?.activeAuthFlow = nil
            self?.authInput = ""
        }
    }

    private func startAuthPolling(_ flow: RuntimeAuthFlow) {
        authPollingTask?.cancel()
        guard flow.status == "running", let client = runtimeClient as? any RuntimeAuthClient else { return }
        authPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let current = try await client.authFlow(id: flow.flowId)
                    guard let self, self.activeAuthFlow?.flowId == flow.flowId else { return }
                    self.applyAuthFlow(current)
                    if current.status != "running" { return }
                } catch { return }
            }
        }
    }

    private func applyAuthFlow(_ flow: RuntimeAuthFlow) {
        activeAuthFlow = flow
        if flow.status == "complete" {
            authPollingTask?.cancel()
            authPollingTask = nil
            refreshAuthProviders()
        } else if flow.status != "running" {
            authPollingTask?.cancel()
            authPollingTask = nil
        }
    }

    func openWorkspaceEntry(_ entry: RuntimeWorkspaceEntry) {
        if entry.isDirectory {
            refreshWorkspace(path: entry.path)
        } else {
            loadWorkspaceFile(path: entry.path)
        }
    }

    func openWorkspaceParent() {
        let components = workspacePath.split(separator: "/")
        refreshWorkspace(path: components.dropLast().joined(separator: "/"))
    }

    private func loadWorkspaceFile(path: String) {
        guard canUseProjectRuntime,
              let client = runtimeClient as? any RuntimeWorkspaceClient
        else { return }
        let cwd = projectPath
        workspaceRequestGeneration += 1
        let generation = workspaceRequestGeneration
        isWorkspaceLoading = true
        workspaceErrorMessage = nil
        workspaceImagePreview = nil
        workspaceImagePreviewError = nil
        Task { [weak self] in
            do {
                let file = try await client.workspaceFile(cwd: cwd, path: path)
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceFile = file
                self.workspaceEditorText = file.content
                if file.mediaType == "image" {
                    do {
                        let preview = try await client.workspaceImagePreview(cwd: cwd, path: file.path)
                        guard self.isCurrentWorkspaceRequest(generation, cwd: cwd) else { return }
                        self.workspaceImagePreview = preview
                    } catch {
                        guard self.isCurrentWorkspaceRequest(generation, cwd: cwd) else { return }
                        self.workspaceImagePreviewError = error.localizedDescription
                    }
                }
                guard self.isCurrentWorkspaceRequest(generation, cwd: cwd) else { return }
                self.isWorkspaceLoading = false
            } catch {
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceLoading = false
            }
        }
    }

    func saveWorkspaceFile() {
        guard let file = workspaceFile,
              !file.binary,
              !file.truncated,
              let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        let content = workspaceEditorText
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.writeWorkspaceFile(
                        cwd: cwd,
                        path: file.path,
                        content: content,
                        overwrite: true,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: self.runtimeClient,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(receipt, kind: "write-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.written == true else {
                    throw RuntimeClientError.serverError(500, "Runtime file write receipt was incomplete.")
                }
                self.isWorkspaceMutationInFlight = false
                self.loadWorkspaceFile(path: file.path)
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func requestWorkspaceFileDeletion() {
        guard workspaceFile != nil, !isWorkspaceMutationInFlight else { return }
        workspaceFilePendingDeletion = workspaceFile
    }

    func cancelWorkspaceFileDeletion() {
        workspaceFilePendingDeletion = nil
    }

    func requestWorkspaceFileMove() {
        guard let file = workspaceFile, !isWorkspaceMutationInFlight else { return }
        workspaceFilePendingMove = file
        workspaceMoveDestination = file.path
    }

    func cancelWorkspaceFileMove() {
        workspaceFilePendingMove = nil
        workspaceMoveDestination = ""
    }

    func confirmWorkspaceFileMove() {
        guard let file = workspaceFilePendingMove,
              let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let destination = workspaceMoveDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            workspaceErrorMessage = "A destination path is required."
            return
        }
        guard destination != file.path else {
            cancelWorkspaceFileMove()
            return
        }
        let cwd = projectPath
        let commandId = UUID().uuidString
        workspaceFilePendingMove = nil
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.moveWorkspaceFile(
                        cwd: cwd,
                        fromPath: file.path,
                        toPath: destination,
                        overwrite: false,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: self.runtimeClient,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(receipt, kind: "move-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.moved == true else {
                    throw RuntimeClientError.serverError(500, "Runtime file move receipt was incomplete.")
                }
                self.workspaceFile = nil
                self.workspaceEditorText = ""
                self.workspaceMoveDestination = ""
                self.isWorkspaceMutationInFlight = false
                self.refreshWorkspace()
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func startWorkspaceFileCreation() {
        guard !isWorkspaceMutationInFlight else { return }
        workspaceNewFilePath = workspacePath.isEmpty ? "" : "\(workspacePath)/"
        showWorkspaceNewFileSheet = true
    }

    func cancelWorkspaceFileCreation() {
        showWorkspaceNewFileSheet = false
        workspaceNewFilePath = ""
    }

    func createWorkspaceFile() {
        guard let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let path = workspaceNewFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            workspaceErrorMessage = "A file path is required."
            return
        }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.writeWorkspaceFile(
                        cwd: cwd,
                        path: path,
                        content: "",
                        overwrite: false,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: self.runtimeClient,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(receipt, kind: "write-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.written == true else {
                    throw RuntimeClientError.serverError(500, "Runtime file create receipt was incomplete.")
                }
                self.showWorkspaceNewFileSheet = false
                self.workspaceNewFilePath = ""
                self.isWorkspaceMutationInFlight = false
                self.refreshWorkspace()
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func confirmWorkspaceFileDeletion() {
        guard let file = workspaceFilePendingDeletion,
              let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        workspaceFilePendingDeletion = nil
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.deleteWorkspaceFile(
                        cwd: cwd,
                        path: file.path,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: self.runtimeClient,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(receipt, kind: "delete-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.deletedFile == true else {
                    throw RuntimeClientError.serverError(500, "Runtime file delete receipt was incomplete.")
                }
                self.workspaceFile = nil
                self.workspaceEditorText = ""
                self.isWorkspaceMutationInFlight = false
                self.refreshWorkspace()
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func ensureTerminalConnection() {
        guard canUseProjectRuntime else { return }
        guard let client = runtimeClient as? any RuntimeTerminalClient else {
            terminalErrorMessage = "This Runtime does not expose a terminal surface."
            return
        }
        if terminalCWD == projectPath && (terminalSubscription != nil || terminalTask != nil) { return }

        stopTerminalConnection()
        terminalCWD = projectPath
        terminalErrorMessage = nil

        let cwd = projectPath
        terminalTask = Task { [weak self] in
            do {
                guard let self else { return }
                let existing = try await client.listTerminals(cwd: cwd)
                let terminal: RuntimeTerminalInfo
                if let existingTerminal = existing.first {
                    terminal = existingTerminal
                } else {
                    guard let expectedRuntimeEpoch = self.runtimeEpoch else {
                        throw RuntimeClientError.incompatibleRuntime(
                            "Reconnect the Runtime before creating a terminal."
                        )
                    }
                    let commandId = UUID().uuidString
                    let receipt: RuntimeCommandReceipt
                    do {
                        receipt = try await client.createTerminal(
                            cwd: cwd,
                            name: "Pi Agent Terminal",
                            cols: 120,
                            rows: 32,
                            commandId: commandId,
                            expectedRuntimeEpoch: expectedRuntimeEpoch
                        )
                    } catch {
                        receipt = try await self.commandReceiptAfterUnknownTransport(
                            client: self.runtimeClient,
                            commandId: commandId,
                            originalError: error
                        )
                    }
                    try self.requireCompletedReceipt(
                        receipt,
                        kind: "create-terminal",
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                    guard receipt.result?.created == true,
                          let createdTerminal = receipt.result?.terminal
                    else {
                        throw RuntimeClientError.serverError(
                            500,
                            "Runtime terminal receipt was missing its created terminal result."
                        )
                    }
                    terminal = createdTerminal
                }
                guard self.isCurrentTerminalConnection(cwd) else { return }
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
                        self.scheduleOwnedRuntimeRecovery()
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
        stopTerminalConnection()
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
              terminal.exited,
              !isTerminalMutationInFlight,
              let expectedRuntimeEpoch = runtimeEpoch
        else { return }
        let commandId = UUID().uuidString
        isTerminalMutationInFlight = true
        terminalErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.continueTerminal(
                        id: terminal.id,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: self.runtimeClient,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "continue-terminal",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.continued == true,
                      let continuedTerminal = receipt.result?.terminal,
                      continuedTerminal.id == terminal.id
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime terminal receipt was missing its continued terminal result."
                    )
                }
                self.terminalInfo = continuedTerminal
                self.isTerminalMutationInFlight = false
                self.reconnectTerminal()
            } catch {
                self.terminalErrorMessage = error.localizedDescription
                self.isTerminalMutationInFlight = false
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
                    self.refreshExtensionInteractions(for: session)
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
                    self.scheduleOwnedRuntimeRecovery()
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

    private func stopTerminalConnection() {
        terminalTask?.cancel()
        terminalSubscription?.cancel()
        terminalTask = nil
        terminalSubscription = nil
        terminalInfo = nil
        terminalCWD = nil
        terminalErrorMessage = nil
    }

    private func scheduleOwnedRuntimeRecovery() {
        guard runtimeRecovery.scheduleRecoveryIfNeeded(ownsRuntime: runtimeSupervisor != nil) else { return }

        runtimeRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.runtimeRecovery.consumeScheduledRecovery()
            else { return }
            self.runtimeRecoveryTask = nil
            self.refreshRuntime(cancellingScheduledRecovery: false)
        }
    }

    private func cancelOwnedRuntimeRecovery() {
        runtimeRecovery.cancelScheduledRecovery()
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = nil
    }

    private func isCurrentRuntimeRefresh(
        _ token: RuntimeRefreshGeneration.Token,
        cwd: String
    ) -> Bool {
        runtimeRefreshGeneration.isCurrent(token, cwd: cwd) && cwd == projectPath
    }

    private func isCurrentTerminalConnection(_ cwd: String) -> Bool {
        terminalCWD == cwd && cwd == projectPath
    }

    private func isCurrentWorkspaceRequest(_ generation: Int, cwd: String) -> Bool {
        generation == workspaceRequestGeneration && cwd == projectPath
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
		case "extension.interaction.opened", "extension.interaction.closed":
			if let session = selectedSession, session.id == sessionID {
				refreshExtensionInteractions(for: session)
			}
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

	func refreshExtensionInteractions(for session: RuntimeSession? = nil) {
		guard let session = session ?? selectedSession,
			  session.archived != true,
			  let client = runtimeClient as? any RuntimeExtensionInteractionClient
		else {
			extensionInteractions = []
			return
		}
		Task { [weak self] in
			guard let self else { return }
			do {
				let interactions = try await client.listExtensionInteractions(
					sessionId: session.id, cwd: session.cwd, runtimeId: session.runtimeId
				)
				guard self.selectedSessionID == session.id else { return }
				self.extensionInteractions = interactions
				if let active = interactions.first, active.kind == "editor" || active.kind == "input" {
					self.extensionInteractionText = active.prefill ?? ""
				}
			} catch {
				guard self.selectedSessionID == session.id else { return }
				self.errorMessage = "Unable to refresh extension dialog: \(error.localizedDescription)"
			}
		}
	}

	func respondToExtensionInteraction(
		_ interaction: RuntimeExtensionInteraction,
		response: RuntimeExtensionInteractionResponse
	) {
		guard !isExtensionInteractionMutationInFlight,
			  let session = selectedSession,
			  session.id == interaction.sessionId,
			  let client = runtimeClient as? any RuntimeExtensionInteractionClient,
			  let expectedRuntimeEpoch = runtimeEpoch
		else {
			errorMessage = "Reconnect the Runtime before answering the extension dialog."
			return
		}
		let commandId = UUID().uuidString
		isExtensionInteractionMutationInFlight = true
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do {
					receipt = try await client.respondToExtensionInteraction(
						sessionId: session.id, cwd: session.cwd, runtimeId: session.runtimeId,
						interactionId: interaction.id, response: response,
						commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch
					)
				} catch {
					receipt = try await self.commandReceiptAfterUnknownTransport(
						client: self.runtimeClient, commandId: commandId, originalError: error
					)
				}
				try self.requireCompletedReceipt(
					receipt,
					kind: "respond-extension-interaction",
					expectedRuntimeEpoch: expectedRuntimeEpoch
				)
				guard receipt.result?.responded == true,
					  receipt.result?.interaction?.id == interaction.id
				else {
					throw RuntimeClientError.serverError(500, "Runtime interaction receipt was incomplete.")
				}
				self.isExtensionInteractionMutationInFlight = false
				self.refreshExtensionInteractions(for: session)
			} catch {
				self.errorMessage = error.localizedDescription
				self.isExtensionInteractionMutationInFlight = false
			}
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
                    client: UnixSocketRuntimeClient(socketPath: bundledRuntime.launchPlan.socketPath, projectCapabilityToken: bundledRuntime.projectCapabilityToken),
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
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model?.systemWillSleep()
            }
        }
        didWakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model?.systemDidWake()
            }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        model?.requestApplicationTermination() ?? .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let willSleepObserver {
            notificationCenter.removeObserver(willSleepObserver)
        }
        if let didWakeObserver {
            notificationCenter.removeObserver(didWakeObserver)
        }
        willSleepObserver = nil
        didWakeObserver = nil
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
    func forkCandidates(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?
    ) async throws -> [RuntimeForkCandidate] { throw RuntimeClientError.connectionFailed(message) }
    func forkSession(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        entryId _: String,
        commandId _: String,
        expectedRuntimeEpoch _: String
    ) async throws -> RuntimeCommandReceipt { throw RuntimeClientError.connectionFailed(message) }
    func importSession(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        inputPath _: String,
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
        .sheet(item: $model.sessionPendingFork, onDismiss: model.cancelFork) { session in
            ForkThreadSheet(model: model, session: session)
        }
        .sheet(isPresented: $model.showGitCommitSheet) {
			GitCommitSheet(model: model)
		}
        .sheet(item: Binding(
            get: { model.workspaceFilePendingMove },
            set: { if $0 == nil { model.cancelWorkspaceFileMove() } }
        )) { file in
            WorkspaceMoveSheet(model: model, file: file)
        }
        .sheet(isPresented: $model.showWorkspaceNewFileSheet, onDismiss: model.cancelWorkspaceFileCreation) {
            WorkspaceNewFileSheet(model: model)
        }
        .sheet(item: $model.activeAuthFlow) { flow in
            NativeAuthFlowSheet(model: model, flow: flow)
        }
		.sheet(item: Binding(
			get: { model.activeExtensionInteraction },
			set: { _ in }
		)) { interaction in
			ExtensionInteractionSheet(model: model, interaction: interaction)
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
                                    Button("Fork Thread…") {
                                        model.requestFork(session)
                                    }
                                    .disabled(model.isSending)
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
						VStack(alignment: .leading, spacing: 2) {
							Label(model.projectName, systemImage: "folder")
							Text(model.projectRuntimeAuthorizationLabel)
								.font(.caption2)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
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
                .disabled(model.isSending || model.projectPath.isEmpty || !model.canUseProjectRuntime)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.importSessionFromFile) {
                    Label("Import Thread", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isSending || !model.canUseProjectRuntime || model.selectedSession == nil || model.selectedSession?.archived == true)
            }
        }
    }
}

struct ForkThreadSheet: View {
    @ObservedObject var model: AppModel
    let session: RuntimeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fork Thread")
                .font(.title2.weight(.semibold))
            Text("Start a new Pi thread from a previous user message in \(session.displayTitle). The original thread stays unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(model.forkCandidates) { candidate in
                Button {
                    model.forkSession(session, from: candidate)
                } label: {
                    Text(candidate.label)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelFork()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
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
						|| !model.canUseProjectRuntime
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
				LabeledContent("Project access", value: model.projectRuntimeAuthorizationLabel)
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
                WorkspaceFilesView(model: model)
                Divider()
				GitChangesView(model: model)
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
                                .disabled(model.isTerminalMutationInFlight)
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

struct WorkspaceFilesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    model.workspacePath.isEmpty ? "Project files" : model.workspacePath,
                    systemImage: "folder"
                )
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                Spacer()
                if !model.workspacePath.isEmpty {
                    Button("Back") { model.openWorkspaceParent() }
                        .buttonStyle(.borderless)
                }
                Button("Refresh") { model.refreshWorkspace() }
                    .buttonStyle(.borderless)
                Button("New File…") { model.startWorkspaceFileCreation() }
                    .buttonStyle(.borderless)
                    .disabled(model.isWorkspaceMutationInFlight || !model.canUseProjectRuntime)
            }

            if model.isWorkspaceLoading {
                ProgressView("Loading files…")
                    .controlSize(.small)
            } else if let tree = model.workspaceTree {
                if tree.entries.isEmpty {
                    Text("This folder is empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tree.entries) { entry in
                        Button {
                            model.openWorkspaceEntry(entry)
                        } label: {
                            Label(entry.name, systemImage: iconName(for: entry))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if tree.truncated {
                    Text("Only the first 1,000 entries are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Files will load when the Runtime connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.workspaceErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let file = model.workspaceFile {
                Divider()
                LabeledContent("File", value: file.path)
                    .font(.caption)
                HStack {
                    Button("Move/Rename…") { model.requestWorkspaceFileMove() }
                    Button("Delete…", role: .destructive) {
                        model.requestWorkspaceFileDeletion()
                    }
                    Spacer()
                }
                .disabled(model.isWorkspaceMutationInFlight)
                if file.mediaType == "image" {
                    WorkspaceImagePreviewView(
                        file: file,
                        preview: model.workspaceImagePreview,
                        errorMessage: model.workspaceImagePreviewError
                    )
                } else if file.binary {
                    Label("Binary or image preview is not available yet.", systemImage: "doc.richtext")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if file.truncated {
                        ScrollView([.horizontal, .vertical]) {
                            Text(file.content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        Text("Preview is truncated at 512 KB.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $model.workspaceEditorText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 160, maxHeight: 260)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Button("Save") { model.saveWorkspaceFile() }
                                .buttonStyle(.borderedProminent)
                            Spacer()
                        }
                        .disabled(model.isWorkspaceMutationInFlight)
                    }
                }
            }
        }
        .task { model.refreshWorkspace() }
    }

    private func iconName(for entry: RuntimeWorkspaceEntry) -> String {
        if entry.isDirectory { return "folder" }
        if entry.type == "symlink" { return "arrow.triangle.branch" }
        return "doc"
    }
}

private struct WorkspaceImagePreviewView: View {
    let file: RuntimeWorkspaceFile
    let preview: RuntimeWorkspaceImagePreview?
    let errorMessage: String?

    var body: some View {
        if let preview, preview.path == file.path,
           let data = preview.imageData,
           let image = NSImage(data: data)
        {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .accessibilityLabel("Image preview for \(file.path)")
                Text("\(preview.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if preview != nil {
            Label("macOS cannot render this image format.", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ProgressView("Loading image preview…")
                .controlSize(.small)
        }
    }
}

struct GitChangesView: View {
	@ObservedObject var model: AppModel

	var body: some View {
		if model.isGitLoading {
			ProgressView("Loading changes…")
		} else if let status = model.gitStatus, status.isGitRepo {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Label(status.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
						.font(.caption.weight(.semibold))
					Spacer()
					Button("Refresh") { model.refreshGit() }
						.buttonStyle(.borderless)
				}
				if status.files.isEmpty {
					Text("Working tree clean")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else {
					ForEach(status.files) { file in
						VStack(alignment: .leading, spacing: 4) {
							HStack(spacing: 6) {
								Button {
									model.selectGitPath(file.path)
								} label: {
									Text(file.path)
										.lineLimit(1)
										.frame(maxWidth: .infinity, alignment: .leading)
								}
								.buttonStyle(.plain)
								Text(gitFileStateLabel(file))
									.font(.caption.monospaced())
									.foregroundStyle(.secondary)
							}
							HStack(spacing: 8) {
								if file.index == "unmodified" || file.index == "untracked" {
									Button("Stage") { model.stageGitPath(file.path) }
								} else {
									Button("Unstage") { model.unstageGitPath(file.path) }
								}
								Spacer()
							}
							.buttonStyle(.borderless)
							.disabled(model.isGitMutationInFlight)
						}
					}
				}
				if let selectedPath = model.gitSelectedPath {
					GitDiffView(path: selectedPath, unstaged: model.gitUnstagedDiff, staged: model.gitStagedDiff)
				}
				Button("Commit Staged Changes…") { model.requestGitCommit() }
					.disabled(model.isGitMutationInFlight || !status.files.contains(where: { $0.index != "unmodified" && $0.index != "untracked" }))
			}
		} else if model.gitStatus?.isGitRepo == false {
			Label("This project is not a Git repository", systemImage: "exclamationmark.triangle")
				.foregroundStyle(.secondary)
		} else {
			Label("Git changes will load when the Runtime connects", systemImage: "arrow.triangle.branch")
				.foregroundStyle(.secondary)
		}
	}
}

private func gitFileStateLabel(_ file: RuntimeGitFile) -> String {
	let index = file.index == "unmodified" ? "" : "I:\(file.index)"
	let worktree = file.workingTree == "unmodified" ? "" : "W:\(file.workingTree)"
	return [index, worktree].filter { !$0.isEmpty }.joined(separator: " ")
}

struct GitDiffView: View {
	let path: String
	let unstaged: RuntimeGitDiff?
	let staged: RuntimeGitDiff?

	var body: some View {
		let diffs = [staged, unstaged].compactMap { $0 }.filter { !$0.diff.isEmpty }
		if diffs.isEmpty {
			Text("No textual diff for \(path)")
				.font(.caption)
				.foregroundStyle(.secondary)
		} else {
			ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
				VStack(alignment: .leading, spacing: 4) {
					Text(diff.staged ? "Staged diff" : "Unstaged diff")
						.font(.caption.weight(.semibold))
					ScrollView(.horizontal) {
						Text(diff.diff)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
					}
					.frame(maxHeight: 180)
				}
			}
		}
	}
}

struct ExtensionInteractionSheet: View {
	@ObservedObject var model: AppModel
	let interaction: RuntimeExtensionInteraction

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(interaction.title)
				.font(.title3.weight(.semibold))
			if let message = interaction.message, !message.isEmpty {
				Text(message)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			switch interaction.kind {
			case "select":
				ScrollView {
					VStack(alignment: .leading, spacing: 8) {
						ForEach(interaction.options ?? [], id: \.self) { option in
							Button(option) {
								model.respondToExtensionInteraction(interaction, response: .selected(option))
							}
							.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
				}
				.frame(minHeight: 100, maxHeight: 300)
			case "input":
				TextField(interaction.placeholder ?? "", text: $model.extensionInteractionText)
					.textFieldStyle(.roundedBorder)
			case "editor":
				TextEditor(text: $model.extensionInteractionText)
					.font(.body.monospaced())
					.frame(minHeight: 180)
					.overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
			default:
				EmptyView()
			}
			HStack {
				Spacer()
				Button("Cancel") {
					model.respondToExtensionInteraction(interaction, response: .cancelled)
				}
				.keyboardShortcut(.cancelAction)
				if interaction.kind == "confirm" {
					Button("Confirm") {
						model.respondToExtensionInteraction(interaction, response: .confirmed(true))
					}
					.buttonStyle(.borderedProminent)
				} else if interaction.kind == "input" || interaction.kind == "editor" {
					Button("Submit") {
						model.respondToExtensionInteraction(interaction, response: .text(model.extensionInteractionText))
					}
					.buttonStyle(.borderedProminent)
				}
			}
		}
		.padding(20)
		.frame(minWidth: 380, idealWidth: 480, minHeight: 160)
		.disabled(model.isExtensionInteractionMutationInFlight)
	}
}

struct GitCommitSheet: View {
	@ObservedObject var model: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Commit Staged Changes")
				.font(.title2.weight(.semibold))
			Text("Only the files already staged by the Runtime will be committed. Git hooks remain enabled.")
				.foregroundStyle(.secondary)
			TextEditor(text: $model.gitCommitMessage)
				.font(.body)
				.frame(minHeight: 120)
				.overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
			HStack {
				Spacer()
				Button("Cancel") { model.cancelGitCommit() }
				Button("Commit") { model.commitGit() }
					.buttonStyle(.borderedProminent)
					.disabled(model.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
		.padding(24)
		.frame(width: 520)
	}
}

struct WorkspaceMoveSheet: View {
    @ObservedObject var model: AppModel
    let file: RuntimeWorkspaceFile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move or Rename File")
                .font(.title2.weight(.semibold))
            Text("Move \(file.path) within the authorized project. Existing files will not be overwritten.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Destination relative path", text: $model.workspaceMoveDestination)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelWorkspaceFileMove() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") { model.confirmWorkspaceFileMove() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.workspaceMoveDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(model.isWorkspaceMutationInFlight)
    }
}

struct WorkspaceNewFileSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New File")
                .font(.title2.weight(.semibold))
            Text("Create an empty UTF-8 text file inside the authorized project. Existing files will not be overwritten.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Relative path", text: $model.workspaceNewFilePath)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelWorkspaceFileCreation() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { model.createWorkspaceFile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.workspaceNewFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(model.isWorkspaceMutationInFlight)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Runtime") {
                Text("The native shell connects to its App-managed Runtime through a private Unix socket.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: model.runtimeLabel)
                LabeledContent("Socket", value: model.runtimeClientSocketDescription)
            }
            Section("Project") {
                LabeledContent("Current", value: model.projectPath)
				LabeledContent("Runtime access", value: model.projectRuntimeAuthorizationLabel)
                Button("Choose Project…") { model.openProject() }
            }
            Section("Providers") {
                if model.isAuthLoading {
                    ProgressView("Loading provider status…")
                } else if model.authProviders.isEmpty {
                    Text("No interactive provider configuration is available from this Runtime.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.authProviders, id: \.displayID) { provider in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.name)
                                Text(providerStatusLabel(provider)).font(.caption).foregroundStyle(provider.status.configured ? .green : .secondary)
                            }
                            Spacer()
                            Button(provider.status.configured ? "Reconfigure…" : "Configure…") { model.startAuthFlow(provider) }
                        }
                    }
                }
                if let error = model.authErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Refresh Provider Status") { model.refreshAuthProviders() }
                    .disabled(model.isAuthLoading || !model.canUseProjectRuntime)
            }
        }
        .padding()
        .frame(width: 520)
    }
}

struct NativeAuthFlowSheet: View {
    @ObservedObject var model: AppModel
    let flow: RuntimeAuthFlow
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(flow.providerName)").font(.title2.weight(.semibold))
            if let auth = flow.auth {
                Button("Open authorization in browser") { openURL(URL(string: auth.url)!) }
                if let instructions = auth.instructions { Text(instructions).foregroundStyle(.secondary) }
                if let code = auth.deviceCode?.userCode { Text("Device code: \(code)").textSelection(.enabled) }
            }
            ForEach(flow.progress, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if let prompt = flow.prompt {
                if prompt.promptType == "secret" { SecureField(prompt.message, text: $model.authInput).textFieldStyle(.roundedBorder) }
                else { TextField(prompt.message, text: $model.authInput).textFieldStyle(.roundedBorder) }
                Button("Continue") { model.respondToAuthFlow() }.buttonStyle(.borderedProminent)
            }
            if let select = flow.select {
                Text(select.message)
                ForEach(select.options) { option in Button(option.label) { model.respondToAuthFlow(option.value) } }
            }
            if let error = flow.error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Refresh") { model.refreshAuthFlow() }; Button("Cancel") { model.cancelAuthFlow() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: flow.prompt?.requestId) { _, _ in model.authInput = "" }
    }
}

private func providerStatusLabel(_ provider: RuntimeAuthProvider) -> String {
    guard provider.status.configured else { return "Not configured" }
    if let label = provider.status.label, !label.isEmpty { return label }
    if let source = provider.status.source, !source.isEmpty { return "Configured via \(source)" }
    return "Configured"
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
