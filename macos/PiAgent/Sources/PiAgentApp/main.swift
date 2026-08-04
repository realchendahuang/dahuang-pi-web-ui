import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

private let nativeInlineImageLimit = Int(4.5 * 1024 * 1024)
private let nativePromptAttachmentLimit = 16
private let nativePromptImageContentTypes: [UTType] = [.png, .jpeg, .gif]
    + (UTType(filenameExtension: "webp").map { [$0] } ?? [])

private func nativeImageMimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return nil
    }
}

/// One App process must supervise at most one bundled Runtime. Each window
/// receives this immutable connection but owns its own project/thread/UI state.
@MainActor
private final class SharedRuntimeConnection: ObservableObject {
    let connection: AppModel.RuntimeConnection

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        connection = AppModel.makeRuntimeConnection(environment: environment)
    }
}

private struct PiAgentWindowRoot: View {
    @StateObject private var model: AppModel
    private let lifecycle: AppLifecycleDelegate

    init(connection: AppModel.RuntimeConnection, lifecycle: AppLifecycleDelegate) {
        let windowIdentifier = UUID().uuidString
        _model = StateObject(wrappedValue: AppModel(
            projectAuthorizationStore: ProjectAuthorizationStore(
                key: "com.realchendahuang.pi-agent.authorized-project.\(windowIdentifier)"
            ),
            connection: connection,
            taskNotifications: lifecycle.taskNotifications
        ))
        self.lifecycle = lifecycle
    }

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 980, minHeight: 680)
            .onAppear { lifecycle.register(model) }
            .onDisappear { lifecycle.unregister(model) }
            .alert(
                "Agent sessions are still active",
                isPresented: $model.showTerminationConfirmation
            ) {
                Button("Keep Running and Quit") { model.keepRuntimeRunningAndTerminate() }
                Button("Stop Runtime and Quit", role: .destructive) { model.stopOwnedRuntimeAndTerminate() }
                Button("Cancel", role: .cancel) { model.cancelTermination() }
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
                Button("Delete Permanently", role: .destructive) { model.confirmPermanentDelete() }
                Button("Cancel", role: .cancel) { model.cancelPermanentDelete() }
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
                Button("Delete File", role: .destructive) { model.confirmWorkspaceFileDeletion() }
                Button("Cancel", role: .cancel) { model.cancelWorkspaceFileDeletion() }
            } message: {
                Text("This permanently removes the selected file from the authorized project.")
            }
    }
}

@main
struct PiAgentApp: App {
    @StateObject private var runtime = SharedRuntimeConnection()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Pi Agent", id: "pi-agent-main") {
            PiAgentWindowRoot(connection: runtime.connection, lifecycle: lifecycleDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "pi-agent-main")
                }
                .keyboardShortcut("n", modifiers: [.command])
                Divider()
                Button("New Thread") {
                    lifecycleDelegate.activeModel?.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Open Project") {
                    lifecycleDelegate.activeModel?.openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Reconnect Runtime") {
                    lifecycleDelegate.activeModel?.refreshRuntime()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            if let model = lifecycleDelegate.activeModel {
                SettingsView(model: model)
            } else {
                Text("Open a Pi Agent window to configure its project and Runtime.")
                    .padding()
            }
        }

        // A visible background affordance: closing all document windows never
        // implies stopping the Runtime, and this menu gives users a way back.
        MenuBarExtra("Pi Agent", systemImage: "sparkles") {
            Button("Open Pi Agent") {
                openWindow(id: "pi-agent-main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Pi Agent") {
                NSApp.terminate(nil)
            }
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
    @Published var knownProjects: [NativeProjectBookmark] = []
	@Published var legacyProjectPreview: RuntimeLegacyProjectPreview?
	@Published var isLegacyProjectPreviewLoading = false
	@Published var legacyMigrationOverview: RuntimeLegacyMigrationOverview?
	@Published var isLegacyMigrationOverviewLoading = false
	@Published var legacyMigrationOverviewError: String?
	@Published var legacyProjectMigration: NativeProjectMigrationRecord?
	@Published var isLegacyProjectMigrationInFlight = false
	@Published var showLegacyProjectMigrationRollbackConfirmation = false
    @Published var selectedSessionID: String?
    @Published var showInspector = true
    @Published var prompt = ""
    @Published var promptImageAttachments: [RuntimePromptImageAttachment] = []
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
	@Published var gitPushPreview: RuntimeGitPushPreview?
	@Published var gitRevertPreview: RuntimeGitRevertPreview?
    @Published var gitSelectedPath: String?
    @Published var gitUnstagedDiff: RuntimeGitDiff?
    @Published var gitStagedDiff: RuntimeGitDiff?
    @Published var isGitLoading = false
    @Published var isGitMutationInFlight = false
    @Published var showGitCommitSheet = false
	@Published var showGitPushConfirmation = false
	@Published var gitPathPendingDiscard: RuntimeGitFile?
	@Published var showGitRevertConfirmation = false
    @Published var gitCheckpoints: [RuntimeGitCheckpoint] = []
    @Published var isGitCheckpointLoading = false
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
    @Published var legacyAuthMigrationPreview: RuntimeLegacyAuthMigrationPreview?
    @Published var legacyAuthMigration: RuntimeLegacyAuthMigration?
    @Published var isLegacyAuthMigrationLoading = false
    @Published var showLegacyAuthMigrationConfirmation = false
	@Published var isSupportReportExporting = false
	@Published var supportReportMessage: String?
	@Published var isUninstallPreparing = false
	@Published var showUninstallConfirmation = false
	@Published var uninstallMessage: String?
	@Published var isDataErasePreparing = false
	@Published var showDataEraseConfirmation = false
	@Published var dataEraseConfirmationText = ""
	@Published var dataEraseMessage: String?
    @Published var gitCommitMessage = ""
	@Published var extensionInteractions: [RuntimeExtensionInteraction] = []
	@Published var isExtensionInteractionMutationInFlight = false
	@Published var extensionInteractionText = ""
	@Published private var projectRuntimeAuthorization: ProjectRuntimeAuthorization = .notRequired

    let runtimeClient: any RuntimeClient
    let terminalSurfaceController = TerminalSurfaceController()
    private let runtimeSupervisor: RuntimeSupervisor?
    private let projectAuthorizationStore: ProjectAuthorizationStore
	private let projectCatalog: NativeProjectCatalog
	private let legacyProjectMigrationCoordinator: NativeLegacyProjectMigrationCoordinator
    let taskNotifications: NativeTaskNotificationCoordinator?
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
    private var uninstallPlan: NativeAppUninstallPlan?
    private var dataErasePlan: NativeAppDataErasePlan?
    private var maintenanceHelperLaunched = false
    private var runtimeEpoch: String?
    private var authPollingTask: Task<Void, Never>?

    init(
        runtimeClient: (any RuntimeClient)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectAuthorizationStore: ProjectAuthorizationStore = ProjectAuthorizationStore(),
		projectCatalog: NativeProjectCatalog = NativeProjectCatalog(),
		projectMigrationJournal: NativeProjectMigrationJournal = NativeProjectMigrationJournal(),
        connection: RuntimeConnection? = nil,
        taskNotifications: NativeTaskNotificationCoordinator? = nil
    ) {
        self.projectAuthorizationStore = projectAuthorizationStore
		self.projectCatalog = projectCatalog
		legacyProjectMigrationCoordinator = NativeLegacyProjectMigrationCoordinator(
			catalog: projectCatalog,
			journal: projectMigrationJournal
		)
		legacyProjectMigration = try? legacyProjectMigrationCoordinator.latestMigration()
		let restoredCatalog = projectCatalog.list()
		knownProjects = restoredCatalog
        self.taskNotifications = taskNotifications
        if let connection {
            self.runtimeClient = connection.client
            runtimeSupervisor = connection.supervisor
            errorMessage = connection.startupError
        } else if let runtimeClient {
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
		} else if let firstProject = restoredCatalog.first,
				  let restoredProject = try? projectCatalog.access(firstProject) {
			projectAccess = restoredProject
			configuredPath = restoredProject.url.path
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

	var nativeAppDataPath: String {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/Pi Agent", isDirectory: true)
			.path
	}

	static let dataEraseConfirmationPhrase = "ERASE PI AGENT DATA"

	var canConfirmDataErase: Bool {
		dataEraseConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == Self.dataEraseConfirmationPhrase
	}

    /// Called synchronously from `NSApplicationDelegate`. The authoritative
    /// active-session count is fetched before choosing whether App termination
    /// may proceed, so a stale UI projection cannot silently stop work.
    func requestApplicationTermination() -> NSApplication.TerminateReply {
		if maintenanceHelperLaunched {
			runtimeSupervisor?.stop()
			return .terminateNow
		}
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
				self.refreshGitCheckpoints()
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
			let activation = try projectCatalog.rememberAndAccess(url)
			activateProject(activation.access)
			knownProjects = projectCatalog.list()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
	}

	func openKnownProject(_ project: NativeProjectBookmark) {
		do {
			activateProject(try projectCatalog.access(project))
			knownProjects = projectCatalog.list()
		} catch {
			errorMessage = "Re-authorize \(project.displayName) to use this project: \(error.localizedDescription)"
		}
	}

    func removeKnownProject(_ project: NativeProjectBookmark) {
		do {
			try projectCatalog.remove(id: project.id)
			knownProjects = projectCatalog.list()
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func activateProject(_ access: ProjectAccess) {
		projectAccess = access
		projectPath = access.url.path
		stopSessionEventStream()
        stopTerminalConnection()
        selectedSessionID = nil
        transcriptMessages = []
        statusBySession = [:]
		gitStatus = nil
		gitPushPreview = nil
		gitRevertPreview = nil
        gitSelectedPath = nil
        gitUnstagedDiff = nil
        gitStagedDiff = nil
		gitCheckpoints = []
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

	func refreshLegacyProjectPreview() {
		guard let client = runtimeClient as? any RuntimeLegacyProjectMigrationClient else { return }
		isLegacyProjectPreviewLoading = true
		Task { [weak self] in
			do {
				let preview = try await client.legacyProjectMigrationPreview()
				guard let self else { return }
				self.legacyProjectPreview = preview
				self.isLegacyProjectPreviewLoading = false
			} catch {
				guard let self else { return }
				self.errorMessage = error.localizedDescription
				self.isLegacyProjectPreviewLoading = false
			}
		}
	}

	func refreshLegacyMigrationOverview() {
		guard let client = runtimeClient as? any RuntimeLegacyMigrationOverviewClient else { return }
		isLegacyMigrationOverviewLoading = true
		legacyMigrationOverviewError = nil
		Task { [weak self] in
			do {
				let overview = try await client.legacyMigrationOverview()
				guard let self else { return }
				self.legacyMigrationOverview = overview
				self.isLegacyMigrationOverviewLoading = false
			} catch {
				guard let self else { return }
				self.legacyMigrationOverview = nil
				self.legacyMigrationOverviewError = error.localizedDescription
				self.isLegacyMigrationOverviewLoading = false
			}
		}
	}

	func reauthorizeLegacyProject(_ candidate: RuntimeLegacyProjectCandidate) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.directoryURL = URL(fileURLWithPath: candidate.path)
		panel.prompt = "Authorize Project"
		panel.message = "Choose the original directory for \(candidate.name). Pi Agent will only add it if this is the exact same path."
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard url.standardizedFileURL.path == URL(fileURLWithPath: candidate.path).standardizedFileURL.path else {
			errorMessage = "Choose the original legacy project path exactly: \(candidate.path)"
			return
		}
		isLegacyProjectMigrationInFlight = true
		do {
			legacyProjectMigration = try legacyProjectMigrationCoordinator.migrate(
				legacyProjectID: candidate.id,
				legacyPath: candidate.path,
				selectedURL: url
			)
			knownProjects = projectCatalog.list()
			isLegacyProjectMigrationInFlight = false
		} catch {
			knownProjects = projectCatalog.list()
			isLegacyProjectMigrationInFlight = false
			errorMessage = error.localizedDescription
		}
	}

	func requestLegacyProjectMigrationRollback() {
		guard legacyProjectMigration?.rollbackEligible == true, !isLegacyProjectMigrationInFlight else { return }
		showLegacyProjectMigrationRollbackConfirmation = true
	}

	func cancelLegacyProjectMigrationRollback() {
		showLegacyProjectMigrationRollbackConfirmation = false
	}

	func rollbackLegacyProjectMigration() {
		guard !isLegacyProjectMigrationInFlight else { return }
		showLegacyProjectMigrationRollbackConfirmation = false
		isLegacyProjectMigrationInFlight = true
		do {
			legacyProjectMigration = try legacyProjectMigrationCoordinator.rollbackLatest()
			knownProjects = projectCatalog.list()
			isLegacyProjectMigrationInFlight = false
		} catch {
			legacyProjectMigration = try? legacyProjectMigrationCoordinator.latestMigration()
			knownProjects = projectCatalog.list()
			isLegacyProjectMigrationInFlight = false
			errorMessage = error.localizedDescription
		}
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
        taskNotifications?.pauseStreams()
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
		refreshGitCheckpoints()
        if selectedSession?.archived != true {
            startSessionEventStream()
        }
    }

    /// A notification may select only an already-authorized project already
    /// represented by this window. Its userInfo never grants a new filesystem
    /// path or opens an arbitrary session.
    @discardableResult
    func selectNotificationSession(sessionID: String, cwd: String) -> Bool {
        guard cwd == projectPath,
              sessions.contains(where: { $0.id == sessionID && $0.cwd == cwd })
        else { return false }
        selectSession(sessionID)
        return true
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
        let attachments = promptImageAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isSending else { return }
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
                        attachments: attachments,
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
                self.promptImageAttachments = []
                self.isSending = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func choosePromptImages() {
        guard !isSending else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = nativePromptImageContentTypes
        panel.prompt = "Attach Images"
        panel.message = "Pi Agent sends supported images inline to the selected Thread. Each image must be at most 4.5 MB."
        guard panel.runModal() == .OK else { return }

        var accepted: [RuntimePromptImageAttachment] = []
        var rejected: [String] = []
        for url in panel.urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count > 0 else { throw RuntimeClientError.serverError(400, "Image is empty.") }
                guard data.count <= nativeInlineImageLimit else {
                    throw RuntimeClientError.serverError(400, "Image exceeds Pi's 4.5 MB inline limit.")
                }
                guard let mimeType = nativeImageMimeType(for: url) else {
                    throw RuntimeClientError.serverError(400, "Only PNG, JPEG, GIF, and WebP images are supported.")
                }
                accepted.append(RuntimePromptImageAttachment(
                    name: url.lastPathComponent,
                    mimeType: mimeType,
                    data: data.base64EncodedString(),
                    size: data.count
                ))
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        let capacity = max(0, nativePromptAttachmentLimit - promptImageAttachments.count)
        promptImageAttachments.append(contentsOf: accepted.prefix(capacity))
        if accepted.count > capacity { rejected.append("more than \(nativePromptAttachmentLimit) images") }
        if !rejected.isEmpty {
            errorMessage = "Could not attach: \(rejected.joined(separator: ", "))."
        }
    }

    func removePromptImage(_ attachment: RuntimePromptImageAttachment) {
        promptImageAttachments.removeAll { $0.id == attachment.id }
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
        guard receipt.runtimeEpoch == expectedRuntimeEpoch || receipt.recoveredAfterRuntimeRestart == true else {
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
			gitPushPreview = nil
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
				self.refreshGitPushPreview()
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

	func refreshGitPushPreview() {
		guard let client = runtimeClient as? any RuntimeGitClient else {
			gitPushPreview = nil
			return
		}
		let cwd = projectPath
		Task { [weak self] in
			guard let self else { return }
			do {
				let preview = try await client.gitPushPreview(cwd: cwd)
				guard self.projectPath == cwd else { return }
				self.gitPushPreview = preview
			} catch {
				guard self.projectPath == cwd else { return }
				self.gitPushPreview = nil
			}
		}
	}

	func refreshGitCheckpoints() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let session = selectedSession
		else { gitCheckpoints = []; return }
		let cwd = session.cwd
		let sessionId = session.id
		isGitCheckpointLoading = true
		Task { [weak self] in
			guard let self else { return }
			do {
				let checkpoints = try await client.gitCheckpoints(cwd: cwd, sessionId: sessionId)
				guard self.selectedSessionID == sessionId, self.projectPath == cwd else { return }
				self.gitCheckpoints = checkpoints
				self.isGitCheckpointLoading = false
			} catch {
				guard self.selectedSessionID == sessionId, self.projectPath == cwd else { return }
				self.isGitCheckpointLoading = false
				self.errorMessage = error.localizedDescription
			}
		}
	}

	func createGitCheckpoint() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let session = selectedSession,
			  let expectedRuntimeEpoch = runtimeEpoch,
			  !isGitMutationInFlight
		else { errorMessage = "Select a thread and reconnect the Runtime before creating a checkpoint."; return }
		let commandId = UUID().uuidString
		let cwd = session.cwd
		let sessionId = session.id
		isGitMutationInFlight = true
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do {
					receipt = try await client.createGitCheckpoint(cwd: cwd, sessionId: sessionId, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
				} catch {
					receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
				}
				try self.requireCompletedReceipt(receipt, kind: "create-git-checkpoint", expectedRuntimeEpoch: expectedRuntimeEpoch)
				guard receipt.result?.checkpointed == true, let checkpoint = receipt.result?.checkpoint else {
					throw RuntimeClientError.serverError(500, "Runtime checkpoint receipt was missing its review snapshot.")
				}
				guard self.selectedSessionID == sessionId, self.projectPath == cwd else { return }
				self.gitCheckpoints = [checkpoint] + self.gitCheckpoints.filter { $0.id != checkpoint.id }
				self.isGitMutationInFlight = false
			} catch {
				self.errorMessage = error.localizedDescription
				self.isGitMutationInFlight = false
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

	func canDiscardGitFile(_ file: RuntimeGitFile) -> Bool {
		guard let status = gitStatus else { return false }
		// A direct submodule pointer has recovery semantics different from a
		// contained file. The Runtime may safely restore the latter in its own
		// worktree, but never changes a submodule HEAD through this action.
		return file.index == "unmodified" &&
			file.workingTree != "unmodified" &&
			file.workingTree != "untracked" &&
			file.oldPath == nil &&
			!status.submodules.contains(file.path)
	}

	func requestGitDiscard(_ file: RuntimeGitFile) {
		guard canDiscardGitFile(file), !isGitMutationInFlight else { return }
		gitPathPendingDiscard = file
	}

	func cancelGitDiscard() { gitPathPendingDiscard = nil }

	func discardGitPath(_ file: RuntimeGitFile) {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let expectedRuntimeEpoch = runtimeEpoch,
			  canDiscardGitFile(file),
			  !isGitMutationInFlight
		else { errorMessage = "Reconnect the Runtime before discarding a Git change."; return }
		let cwd = projectPath
		let commandId = UUID().uuidString
		isGitMutationInFlight = true
		gitPathPendingDiscard = nil
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do {
					receipt = try await client.discardGitPaths(cwd: cwd, paths: [file.path], confirmed: true, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
				} catch {
					receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
				}
				try self.requireCompletedReceipt(receipt, kind: "discard-git-paths", expectedRuntimeEpoch: expectedRuntimeEpoch)
				guard receipt.result?.discarded == true, let status = receipt.result?.status else {
					throw RuntimeClientError.serverError(500, "Runtime discard receipt was missing its Git status projection.")
				}
				guard self.projectPath == cwd else { return }
				self.gitStatus = status
				self.gitSelectedPath = nil
				self.gitUnstagedDiff = nil
				self.gitStagedDiff = nil
				self.isGitMutationInFlight = false
				self.refreshGitPushPreview()
			} catch {
				self.errorMessage = error.localizedDescription
				self.isGitMutationInFlight = false
			}
		}
	}

	func requestGitCommit() {
		guard gitStatus?.isGitRepo == true, !isGitMutationInFlight else { return }
		showGitCommitSheet = true
	}

	func requestGitPush() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  !isGitMutationInFlight
		else { errorMessage = "Reconnect the Runtime before pushing changes."; return }
		let cwd = projectPath
		Task { [weak self] in
			guard let self else { return }
			do {
				let preview = try await client.gitPushPreview(cwd: cwd)
				guard self.projectPath == cwd else { return }
				self.gitPushPreview = preview
				guard preview.canPush else {
					self.errorMessage = preview.reason ?? "The current branch cannot be pushed."
					return
				}
				self.showGitPushConfirmation = true
			} catch {
				guard self.projectPath == cwd else { return }
				self.errorMessage = error.localizedDescription
			}
		}
	}

	func cancelGitPush() {
		showGitPushConfirmation = false
	}

	func requestGitRevert() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  !isGitMutationInFlight
		else { errorMessage = "Reconnect the Runtime before undoing a Git commit."; return }
		let cwd = projectPath
		Task { [weak self] in
			guard let self else { return }
			do {
				let preview = try await client.gitRevertPreview(cwd: cwd)
				guard self.projectPath == cwd else { return }
				self.gitRevertPreview = preview
				guard preview.canRevert else {
					self.errorMessage = preview.reason ?? "The latest commit cannot be undone."
					return
				}
				self.showGitRevertConfirmation = true
			} catch {
				guard self.projectPath == cwd else { return }
				self.errorMessage = error.localizedDescription
			}
		}
	}

	func cancelGitRevert() { showGitRevertConfirmation = false }

	func revertGitHead() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let expectedRuntimeEpoch = runtimeEpoch,
			  gitRevertPreview?.canRevert == true,
			  !isGitMutationInFlight
		else { errorMessage = "Refresh the latest-commit undo preview before continuing."; return }
		let cwd = projectPath
		let commandId = UUID().uuidString
		isGitMutationInFlight = true
		showGitRevertConfirmation = false
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do {
					receipt = try await client.revertGitHead(cwd: cwd, confirmed: true, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
				} catch {
					receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
				}
				try self.requireCompletedReceipt(receipt, kind: "revert-git-head", expectedRuntimeEpoch: expectedRuntimeEpoch)
				guard receipt.result?.reverted == true, let status = receipt.result?.status else {
					throw RuntimeClientError.serverError(500, "Runtime revert receipt was missing its Git status projection.")
				}
				guard self.projectPath == cwd else { return }
				self.gitStatus = status
				self.gitSelectedPath = nil
				self.gitUnstagedDiff = nil
				self.gitStagedDiff = nil
				self.isGitMutationInFlight = false
				self.refreshGitPushPreview()
			} catch {
				self.errorMessage = error.localizedDescription
				self.isGitMutationInFlight = false
			}
		}
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

	func pushGit() {
		guard let client = runtimeClient as? any RuntimeGitClient,
			  let expectedRuntimeEpoch = runtimeEpoch,
			  let preview = gitPushPreview,
			  preview.canPush,
			  !isGitMutationInFlight
		else { errorMessage = "Refresh the Git push preview before pushing changes."; return }
		let cwd = projectPath
		let commandId = UUID().uuidString
		isGitMutationInFlight = true
		showGitPushConfirmation = false
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do {
					receipt = try await client.pushGit(
						cwd: cwd,
						confirmed: true,
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
				try self.requireCompletedReceipt(receipt, kind: "push-git", expectedRuntimeEpoch: expectedRuntimeEpoch)
				guard receipt.result?.pushed == true, let status = receipt.result?.status else {
					throw RuntimeClientError.serverError(500, "Runtime push receipt was missing its Git status projection.")
				}
				guard self.projectPath == cwd else { return }
				self.gitStatus = status
				self.isGitMutationInFlight = false
				self.refreshGitPushPreview()
			} catch {
				self.errorMessage = error.localizedDescription
				self.isGitMutationInFlight = false
				self.refreshGitPushPreview()
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
                self.refreshLegacyAuthMigrationPreview()
            } catch {
                guard let self else { return }
                self.authErrorMessage = error.localizedDescription
                self.isAuthLoading = false
            }
        }
    }

	/// Exports an App-owned, redacted diagnostic report only after the user picks
	/// an output path. Runtime/session authority and project filesystem access do
	/// not move into Swift as part of this support operation.
	func exportSupportReport() {
		guard !isSupportReportExporting else { return }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.json]
		panel.canCreateDirectories = true
		panel.nameFieldStringValue = "Pi-Agent-Support-Report.json"
		panel.message = "The report includes app and Runtime version/status metadata only. It never includes prompts, transcripts, project file contents, credentials, or capability tokens."
		guard panel.runModal() == .OK, let url = panel.url else { return }
		isSupportReportExporting = true
		supportReportMessage = nil
		Task { [weak self] in
			guard let self else { return }
			let health: RuntimeHealth?
			let hello: RuntimeHello?
			var errors: [String] = []
			do { health = try await self.runtimeClient.health() }
			catch { health = nil; errors.append("health: \(error.localizedDescription)") }
			if let helloClient = self.runtimeClient as? any RuntimeHelloClient {
				do { hello = try await helloClient.hello() }
				catch { hello = nil; errors.append("hello: \(error.localizedDescription)") }
			} else {
				hello = nil
				errors.append("hello: unavailable from this Runtime client")
			}
			let bundle = Bundle.main
			let report = NativeSupportReport(
				application: .init(
					bundleIdentifier: bundle.bundleIdentifier,
					version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
					build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
					bundlePath: bundle.bundleURL.path
				),
				runtime: .init(
					socket: self.runtimeClientSocketDescription,
					connectionState: self.runtimeLabel,
					health: health,
					hello: hello,
					diagnosticError: errors.isEmpty ? nil : errors.joined(separator: "; ")
				),
				project: .init(path: self.projectPath, authorization: self.projectRuntimeAuthorizationLabel),
				providers: self.authProviders.map {
					.init(id: $0.id, authType: $0.authType, configured: $0.status.configured, source: $0.status.source)
				}
			)
			do {
				try report.encodedJSON().write(to: url, options: .atomic)
				self.supportReportMessage = "Saved redacted report to \(url.path)"
			} catch {
				self.supportReportMessage = "Could not save support report: \(error.localizedDescription)"
			}
			self.isSupportReportExporting = false
		}
	}

	/// Opens only the App-owned data folder. Project checkouts, legacy PI WEB
	/// state and Keychain credentials are intentionally outside this operation.
	func revealNativeAppData() {
		let dataURL = URL(fileURLWithPath: nativeAppDataPath, isDirectory: true)
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: dataURL.path) {
			NSWorkspace.shared.activateFileViewerSelecting([dataURL])
		} else {
			NSWorkspace.shared.open(dataURL.deletingLastPathComponent())
		}
	}

	func requestUninstallKeepingData() {
		guard !isUninstallPreparing, !maintenanceHelperLaunched else { return }
		guard runtimeSupervisor != nil else {
			uninstallMessage = "Automatic uninstall is available only from the bundled Pi Agent.app Runtime. This connection is external, so Pi Agent will not stop or remove it."
			return
		}
		do {
			let bundleURL = Bundle.main.bundleURL
			let helperURL = bundleURL
				.appendingPathComponent("Contents/Helpers", isDirectory: true)
				.appendingPathComponent(NativeAppUninstallPlan.helperName)
			uninstallPlan = try NativeAppUninstallPlan.prepare(
				appBundleURL: bundleURL,
				helperURL: helperURL,
				waitForProcessID: ProcessInfo.processInfo.processIdentifier
			)
		} catch {
			uninstallMessage = error.localizedDescription
			return
		}

		isUninstallPreparing = true
		uninstallMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let health = try await self.runtimeClient.health()
				guard health.activeSessions == 0 else {
					throw RuntimeClientError.serverError(409, "Finish or stop the \(health.activeSessions) active session\(health.activeSessions == 1 ? "" : "s") before uninstalling Pi Agent.")
				}
				self.isUninstallPreparing = false
				self.showUninstallConfirmation = true
			} catch {
				self.isUninstallPreparing = false
				self.uninstallMessage = "Pi Agent did not begin uninstalling: \(error.localizedDescription)"
			}
		}
	}

	func cancelUninstallKeepingData() {
		showUninstallConfirmation = false
		uninstallPlan = nil
	}

	func confirmUninstallKeepingData() {
		guard let uninstallPlan, !isUninstallPreparing, !maintenanceHelperLaunched else { return }
		showUninstallConfirmation = false
		isUninstallPreparing = true
		Task { [weak self] in
			guard let self else { return }
			do {
				let health = try await self.runtimeClient.health()
				guard health.activeSessions == 0 else {
					throw RuntimeClientError.serverError(409, "An active session started before uninstall. Pi Agent left the app bundle untouched.")
				}
				let process = Process()
				process.executableURL = uninstallPlan.helperURL
				process.arguments = uninstallPlan.helperArguments
				try process.run()
				self.maintenanceHelperLaunched = true
				self.isUninstallPreparing = false
				NSApp.terminate(nil)
			} catch {
				self.isUninstallPreparing = false
				self.uninstallMessage = "Pi Agent did not begin uninstalling: \(error.localizedDescription)"
			}
		}
	}

	func requestDataErase() {
		guard !isDataErasePreparing, !maintenanceHelperLaunched else { return }
		guard runtimeSupervisor != nil else {
			dataEraseMessage = "Automatic data erase is available only from the bundled Pi Agent.app Runtime. This connection is external, so Pi Agent will not remove any data."
			return
		}
		do {
			let bundleURL = Bundle.main.bundleURL
			let helperURL = bundleURL
				.appendingPathComponent("Contents/Helpers", isDirectory: true)
				.appendingPathComponent(NativeAppDataErasePlan.helperName)
			dataErasePlan = try NativeAppDataErasePlan.prepare(
				appBundleURL: bundleURL,
				helperURL: helperURL,
				waitForProcessID: ProcessInfo.processInfo.processIdentifier
			)
		} catch {
			dataEraseMessage = error.localizedDescription
			return
		}

		isDataErasePreparing = true
		dataEraseMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let health = try await self.runtimeClient.health()
				guard health.activeSessions == 0 else {
					throw RuntimeClientError.serverError(409, "An active session is running. Pi Agent left all data unchanged.")
				}
				self.isDataErasePreparing = false
				self.dataEraseConfirmationText = ""
				self.showDataEraseConfirmation = true
			} catch {
				self.isDataErasePreparing = false
				self.dataEraseMessage = "Pi Agent did not begin data erase: \(error.localizedDescription)"
			}
		}
	}

	func cancelDataErase() {
		showDataEraseConfirmation = false
		dataEraseConfirmationText = ""
		dataErasePlan = nil
	}

	func confirmDataErase() {
		guard let dataErasePlan,
			  canConfirmDataErase,
			  !isDataErasePreparing,
			  !maintenanceHelperLaunched
		else { return }
		showDataEraseConfirmation = false
		isDataErasePreparing = true
		Task { [weak self] in
			guard let self else { return }
			do {
				let health = try await self.runtimeClient.health()
				guard health.activeSessions == 0 else {
					throw RuntimeClientError.serverError(409, "An active session started before data erase. Pi Agent left all data unchanged.")
				}
				let process = Process()
				process.executableURL = dataErasePlan.helperURL
				process.arguments = dataErasePlan.helperArguments
				try process.run()
				self.maintenanceHelperLaunched = true
				self.isDataErasePreparing = false
				NSApp.terminate(nil)
			} catch {
				self.isDataErasePreparing = false
				self.dataEraseMessage = "Pi Agent did not begin data erase: \(error.localizedDescription)"
			}
		}
	}

    /// Inspection is read-only and its projection contains provider/type only.
    func refreshLegacyAuthMigrationPreview() {
        guard let client = runtimeClient as? any RuntimeAuthClient, runtimeEpoch != nil else { return }
        isLegacyAuthMigrationLoading = true
        Task { [weak self] in
            do {
                let preview = try await client.legacyAuthMigrationPreview()
                guard let self else { return }
                self.legacyAuthMigrationPreview = preview
                self.isLegacyAuthMigrationLoading = false
            } catch {
                guard let self else { return }
                // Older/non-bundled Runtimes do not expose this optional capability.
                self.legacyAuthMigrationPreview = nil
                self.isLegacyAuthMigrationLoading = false
            }
        }
    }

    func requestLegacyAuthMigration() {
        guard legacyAuthMigrationPreview?.eligible == true else { return }
        showLegacyAuthMigrationConfirmation = true
    }

    func migrateLegacyAuth() {
        guard let client = runtimeClient as? any RuntimeAuthClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              let preview = legacyAuthMigrationPreview,
              preview.eligible,
              !isLegacyAuthMigrationLoading
        else { return }
        let commandId = UUID().uuidString
        isLegacyAuthMigrationLoading = true
        authErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.migrateLegacyAuth(
                        providerIds: preview.credentials.map(\.providerId),
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
                }
                try self.requireCompletedReceipt(receipt, kind: "migrate-legacy-auth", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.migrated == true, let migration = receipt.result?.migration else {
                    throw RuntimeClientError.serverError(500, "Runtime migration receipt was missing its completed result.")
                }
                self.legacyAuthMigration = migration
                self.isLegacyAuthMigrationLoading = false
                self.refreshAuthProviders()
            } catch {
                self.authErrorMessage = error.localizedDescription
                self.isLegacyAuthMigrationLoading = false
                self.refreshLegacyAuthMigrationPreview()
            }
        }
    }

    func rollbackLegacyAuthMigration() {
        guard let client = runtimeClient as? any RuntimeAuthClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              let migration = legacyAuthMigration,
              migration.rollbackEligible,
              !isLegacyAuthMigrationLoading
        else { return }
        let commandId = UUID().uuidString
        isLegacyAuthMigrationLoading = true
        authErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.rollbackLegacyAuthMigration(id: migration.id, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
                }
                try self.requireCompletedReceipt(receipt, kind: "rollback-legacy-auth-migration", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.rolledBack == true, let updated = receipt.result?.migration else {
                    throw RuntimeClientError.serverError(500, "Runtime rollback receipt was missing its completed result.")
                }
                self.legacyAuthMigration = updated
                self.isLegacyAuthMigrationLoading = false
                self.refreshAuthProviders()
            } catch {
                self.authErrorMessage = error.localizedDescription
                self.isLegacyAuthMigrationLoading = false
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
        if canUseProjectRuntime,
           let client = runtimeClient as? any RuntimeNotificationClient
        {
            taskNotifications?.reconcile(client: client, cwd: projectPath, sessions: ordered)
        }
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

    struct RuntimeConnection {
        let client: any RuntimeClient
        let supervisor: RuntimeSupervisor?
        let startupError: String?
    }

    static func makeRuntimeConnection(environment: [String: String]) -> RuntimeConnection {
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
                    client: UnixSocketRuntimeClient(
						socketPath: bundledRuntime.launchPlan.socketPath,
					projectCapabilityToken: bundledRuntime.projectCapabilityToken,
					socketSecurity: .bundled,
                    launchNonce: bundledRuntime.launchNonce
					),
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

/// App-lifetime bridge from Runtime-owned explicit notifications to macOS.
/// It deliberately owns one project subscription per authorized project, not
/// one per window, so reconnecting or opening another window cannot duplicate
/// alerts. Notification text comes only from the bounded Runtime inbox.
@MainActor
final class NativeTaskNotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private static let enabledDefaultsKey = "com.realchendahuang.pi-agent.task-notifications.enabled"
    private static let maximumSeenNotificationIDs = 2_048

    @Published private(set) var enabled: Bool
    @Published private(set) var authorizationLabel = "Not requested"

    var onOpenSession: ((String, String) -> Void)?

    private let notificationCenter: UNUserNotificationCenter
    private var projects: [String: ProjectState] = [:]
    private var seenNotificationIDs = Set<String>()
    private var seenNotificationOrder: [String] = []

    override init() {
        notificationCenter = UNUserNotificationCenter.current()
        enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        super.init()
        notificationCenter.delegate = self
        refreshAuthorizationStatus()
    }

    func setEnabled(_ requested: Bool) {
        guard requested else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            pauseStreams()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                let settings = await notificationCenter.notificationSettings()
                authorizationLabel = Self.authorizationLabel(for: settings.authorizationStatus)
                enabled = granted && Self.permitsDelivery(settings.authorizationStatus)
                UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
                if enabled {
                    projects.values.forEach { startStreamIfNeeded(for: $0) }
                }
            } catch {
                enabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                authorizationLabel = "Unavailable"
            }
        }
    }

    func reconcile(
        client: any RuntimeNotificationClient,
        cwd: String,
        sessions: [RuntimeSession]
    ) {
        let state: ProjectState
        if let existing = projects[cwd] {
            state = existing
            state.client = client
            state.sessions = sessions
        } else {
            state = ProjectState(client: client, cwd: cwd, sessions: sessions)
            projects[cwd] = state
        }
        if enabled { startStreamIfNeeded(for: state) }
    }

    func pauseStreams() {
        for state in projects.values {
            state.generation += 1
            state.task?.cancel()
            state.subscription?.cancel()
            state.task = nil
            state.subscription = nil
        }
    }

    func stop() {
        pauseStreams()
        projects.removeAll()
    }

    private func refreshAuthorizationStatus() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await notificationCenter.notificationSettings()
            authorizationLabel = Self.authorizationLabel(for: settings.authorizationStatus)
            if enabled, !Self.permitsDelivery(settings.authorizationStatus) {
                enabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                pauseStreams()
            }
        }
    }

    private func startStreamIfNeeded(for state: ProjectState) {
        guard enabled, state.task == nil else { return }
        state.generation += 1
        let generation = state.generation
        state.task = Task { [weak self, weak state] in
            guard let self, let state else { return }
            var reconnectDelay: UInt64 = 250_000_000
            while !Task.isCancelled, isCurrent(state, generation: generation) {
                let subscription = state.client.subscribeNotificationSummaries(cwd: state.cwd)
                state.subscription = subscription
                do {
                    var connected = false
                    for try await _ in subscription.ready {
                        connected = true
                        break
                    }
                    guard connected else {
                        throw RuntimeClientError.connectionFailed("notification socket closed before handshake")
                    }
                    try await seedExistingNotifications(for: state)
                    reconnectDelay = 250_000_000
                    for try await event in subscription.events {
                        guard isCurrent(state, generation: generation) else {
                            subscription.cancel()
                            return
                        }
                        try await consume(event, from: state)
                    }
                    throw RuntimeClientError.connectionFailed("notification socket closed")
                } catch is CancellationError {
                    subscription.cancel()
                    return
                } catch {
                    subscription.cancel()
                    state.subscription = nil
                    guard isCurrent(state, generation: generation) else { return }
                    do {
                        try await Task.sleep(nanoseconds: reconnectDelay)
                    } catch {
                        return
                    }
                    reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
                }
            }
            if state.generation == generation {
                state.task = nil
                state.subscription = nil
            }
        }
    }

    private func isCurrent(_ state: ProjectState, generation: Int) -> Bool {
        enabled && state.generation == generation && projects[state.cwd] === state
    }

    private func seedExistingNotifications(for state: ProjectState) async throws {
        for session in state.sessions where session.cwd == state.cwd {
            let inbox = try await state.client.notificationInbox(
                sessionId: session.id,
                cwd: state.cwd,
                runtimeId: session.runtimeId
            )
            guard inbox.summary.cwd == state.cwd, inbox.summary.sessionId == session.id else { continue }
            for notification in inbox.notifications {
                _ = remember(notificationID(inbox: inbox, notification: notification))
            }
        }
    }

    private func consume(
        _ event: RuntimeNotificationSummaryEvent,
        from state: ProjectState
    ) async throws {
        guard event.type == "notifications.summary",
              event.summary.cwd == state.cwd,
              let session = state.sessions.first(where: {
                  $0.id == event.summary.sessionId && $0.cwd == state.cwd
              })
        else { return }
        let inbox = try await state.client.notificationInbox(
            sessionId: session.id,
            cwd: state.cwd,
            runtimeId: session.runtimeId
        )
        guard inbox.summary.cwd == state.cwd, inbox.summary.sessionId == session.id else { return }
        for notification in inbox.notifications {
            let identifier = notificationID(inbox: inbox, notification: notification)
            guard remember(identifier) else { continue }
            guard !NSApp.isActive else { continue }
            deliver(notification, sessionID: session.id, cwd: state.cwd, identifier: identifier)
        }
    }

    /// Returns false for an already-seen Runtime item. The bounded cache makes
    /// reconnects idempotent without retaining a transcript or notification body.
    private func remember(_ identifier: String) -> Bool {
        guard seenNotificationIDs.insert(identifier).inserted else { return false }
        seenNotificationOrder.append(identifier)
        if seenNotificationOrder.count > Self.maximumSeenNotificationIDs {
            let removed = seenNotificationOrder.removeFirst()
            seenNotificationIDs.remove(removed)
        }
        return true
    }

    private func notificationID(
        inbox: RuntimeSessionNotificationInbox,
        notification: RuntimeSessionNotification
    ) -> String {
        "\(inbox.daemonInstanceId):\(inbox.summary.cwd):\(inbox.summary.sessionId):\(notification.id)"
    }

    private func deliver(
        _ notification: RuntimeSessionNotification,
        sessionID: String,
        cwd: String,
        identifier: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Pi Agent task needs attention"
        content.body = notification.message
        content.sound = .default
        // Keep userInfo capability-free. The callback may only select an
        // already-open model for this exact project/session pair.
        content.userInfo = ["version": 1, "sessionId": sessionID, "cwd": cwd]
        notificationCenter.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionID = userInfo["sessionId"] as? String,
              let cwd = userInfo["cwd"] as? String
        else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            self?.onOpenSession?(sessionID, cwd)
        }
        completionHandler()
    }

    private static func permitsDelivery(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    private static func authorizationLabel(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied in System Settings"
        case .authorized: return "Allowed"
        case .provisional: return "Provisional"
        @unknown default: return "Unknown"
        }
    }

    private final class ProjectState {
        var client: any RuntimeNotificationClient
        let cwd: String
        var sessions: [RuntimeSession]
        var subscription: RuntimeNotificationSubscription?
        var task: Task<Void, Never>?
        var generation = 0

        init(client: any RuntimeNotificationClient, cwd: String, sessions: [RuntimeSession]) {
            self.client = client
            self.cwd = cwd
            self.sessions = sessions
        }
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let models = NSHashTable<AppModel>.weakObjects()
    weak var activeModel: AppModel?
    let taskNotifications = NativeTaskNotificationCoordinator()
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        taskNotifications.onOpenSession = { [weak self] sessionID, cwd in
            guard let self else { return }
            if let model = self.allModels.first(where: {
                $0.selectNotificationSession(sessionID: sessionID, cwd: cwd)
            }) {
                self.activeModel = model
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.allModels.forEach { $0.systemWillSleep() }
            }
        }
        didWakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.allModels.forEach { $0.systemDidWake() }
            }
        }
    }

    func register(_ model: AppModel) {
        models.add(model)
        activeModel = model
    }

    func unregister(_ model: AppModel) {
        models.remove(model)
        if activeModel === model {
            activeModel = allModels.last
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        activeModel?.requestApplicationTermination() ?? .terminateNow
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
        taskNotifications.stop()
    }

    private var allModels: [AppModel] { models.allObjects }
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
        attachments _: [RuntimePromptImageAttachment],
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
		.sheet(isPresented: $model.showGitPushConfirmation) {
			GitPushConfirmationSheet(model: model)
		}
		.sheet(item: Binding(
			get: { model.gitPathPendingDiscard },
			set: { if $0 == nil { model.cancelGitDiscard() } }
		)) { file in
			GitDiscardConfirmationSheet(model: model, file: file)
		}
		.sheet(isPresented: $model.showGitRevertConfirmation) {
			GitRevertConfirmationSheet(model: model)
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
				ForEach(model.knownProjects) { project in
					Button {
						model.openKnownProject(project)
					} label: {
						HStack(spacing: 8) {
							Image(systemName: project.displayPath == model.projectPath ? "folder.fill" : "folder")
							VStack(alignment: .leading, spacing: 1) {
								Text(project.displayName).lineLimit(1)
								Text(project.displayPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
							}
							Spacer()
						}
					}
					.buttonStyle(.plain)
					.contextMenu {
						Button("Remove from Project Library", role: .destructive) {
							model.removeKnownProject(project)
						}
					}
				}
				Button("Add Project…") { model.openProject() }
			}
			Section("Threads") {
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
					VStack(alignment: .leading, spacing: 2) {
						Label(model.projectName, systemImage: "folder.fill")
						Text(model.projectRuntimeAuthorizationLabel)
							.font(.caption2)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
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
            VStack(alignment: .leading, spacing: 8) {
                if !model.promptImageAttachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(model.promptImageAttachments) { attachment in
                                PromptImageAttachmentChip(attachment: attachment) {
                                    model.removePromptImage(attachment)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 64)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    Button("Attach Images…") { model.choosePromptImages() }
                        .disabled(
                            model.selectedSession == nil
                                || model.selectedSession?.archived == true
                                || !model.canUseProjectRuntime
                                || model.isSending
                                || model.promptImageAttachments.count >= nativePromptAttachmentLimit
                        )
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
                            || (model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.promptImageAttachments.isEmpty)
							|| !model.canUseProjectRuntime
                            || model.isSending
                    )
                }
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
            if !message.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                            MessageImagePreview(image: image)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PromptImageAttachmentChip: View {
    let attachment: RuntimePromptImageAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(attachment.name)")
        }
        .font(.caption)
        .padding(6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct MessageImagePreview: View {
    let image: RuntimeMessageImage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let data = image.imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 220)
            } else {
                Label("This image format cannot be rendered by this macOS version.", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(image.mimeType)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
					Button("Save Checkpoint") { model.createGitCheckpoint() }
						.buttonStyle(.borderless)
						.disabled(model.isGitMutationInFlight || model.selectedSessionID == nil)
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
								if model.canDiscardGitFile(file) {
									Button("Discard…") { model.requestGitDiscard(file) }
										.foregroundStyle(.red)
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
				Button("Undo Latest Commit…") { model.requestGitRevert() }
					.disabled(model.isGitMutationInFlight)
				if let preview = model.gitPushPreview, preview.canPush {
					Button("Push \(preview.status.ahead ?? 0) Commit\(preview.status.ahead == 1 ? "" : "s")…") { model.requestGitPush() }
						.disabled(model.isGitMutationInFlight)
				} else if let reason = model.gitPushPreview?.reason {
					Text(reason)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				GitCheckpointsView(model: model)
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

struct GitCheckpointsView: View {
	@ObservedObject var model: AppModel

	var body: some View {
		DisclosureGroup("Thread checkpoints") {
			if model.isGitCheckpointLoading {
				ProgressView("Loading checkpoints…")
			} else if model.gitCheckpoints.isEmpty {
				Text("Save a checkpoint to keep this Thread's current Git status and bounded staged/unstaged diff for review. It does not create a Git ref or enable restore.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				ForEach(model.gitCheckpoints) { checkpoint in
					VStack(alignment: .leading, spacing: 4) {
						Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
							.font(.caption.weight(.semibold))
						Text("\(checkpoint.status.files.count) changed file\(checkpoint.status.files.count == 1 ? "" : "s") · \(checkpoint.status.branch ?? "Detached HEAD")")
							.font(.caption)
							.foregroundStyle(.secondary)
						CheckpointDiffView(label: "Staged", diff: checkpoint.staged)
						CheckpointDiffView(label: "Unstaged", diff: checkpoint.unstaged)
					}
					.padding(.vertical, 4)
				}
			}
		}
	}
}

struct CheckpointDiffView: View {
	let label: String
	let diff: RuntimeGitCheckpointDiff

	var body: some View {
		if !diff.diff.isEmpty {
			DisclosureGroup("\(label) diff\(diff.truncated ? " (bounded)" : "")") {
				ScrollView(.horizontal) {
					Text(diff.diff)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
				}
				.frame(maxHeight: 150)
			}
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

struct GitPushConfirmationSheet: View {
	@ObservedObject var model: AppModel

	var body: some View {
		let preview = model.gitPushPreview
		VStack(alignment: .leading, spacing: 16) {
			Text("Push Commits")
				.font(.title2.weight(.semibold))
			if let preview {
				Text("Push \(preview.status.ahead ?? 0) local commit\(preview.status.ahead == 1 ? "" : "s") from \(preview.status.branch ?? "the current branch") to \(preview.status.upstream ?? "its configured upstream").")
					.foregroundStyle(.secondary)
			}
			Text("Pi Agent will push only the current branch to its configured tracking upstream. It cannot force-push, set an upstream, choose another remote or branch, push tags, or alter your working tree.")
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button("Cancel") { model.cancelGitPush() }
				Button("Push") { model.pushGit() }
					.buttonStyle(.borderedProminent)
					.disabled(preview?.canPush != true || model.isGitMutationInFlight)
			}
		}
		.padding(24)
		.frame(width: 520)
	}
}

struct GitDiscardConfirmationSheet: View {
	@ObservedObject var model: AppModel
	let file: RuntimeGitFile

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Discard Unstaged Change")
				.font(.title2.weight(.semibold))
			Text("Discard the unstaged changes in \(file.path)? This restores that tracked file to the current HEAD and cannot be undone from Pi Agent.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Text("Untracked files, staged changes, renamed files, and submodule pointer changes are intentionally unavailable here. A tracked file inside a submodule can be restored in that submodule's own worktree.")
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button("Cancel") { model.cancelGitDiscard() }
				Button("Discard Changes") { model.discardGitPath(file) }
					.buttonStyle(.borderedProminent)
					.tint(.red)
					.disabled(model.isGitMutationInFlight)
			}
		}
		.padding(24)
		.frame(width: 520)
	}
}

struct GitRevertConfirmationSheet: View {
	@ObservedObject var model: AppModel

	var body: some View {
		let preview = model.gitRevertPreview
		VStack(alignment: .leading, spacing: 16) {
			Text("Undo Latest Commit")
				.font(.title2.weight(.semibold))
			if let commit = preview?.commit {
				Text("Create a new commit that reverses \(commit.hash.prefix(12)): \(commit.subject)")
					.foregroundStyle(.secondary)
			}
			Text("This preserves history. Pi Agent will not reset or amend commits, change branches, force-push, select another commit, or alter an upstream. The working tree and index must remain clean when you confirm.")
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button("Cancel") { model.cancelGitRevert() }
				Button("Create Revert Commit") { model.revertGitHead() }
					.buttonStyle(.borderedProminent)
					.disabled(preview?.canRevert != true || model.isGitMutationInFlight)
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
				Button("Export Redacted Support Report…") { model.exportSupportReport() }
					.disabled(model.isSupportReportExporting)
				if model.isSupportReportExporting {
					ProgressView("Collecting Runtime metadata…")
				} else if let message = model.supportReportMessage {
					Text(message)
						.font(.caption)
						.foregroundStyle(message.hasPrefix("Saved") ? Color.secondary : Color.red)
						.textSelection(.enabled)
				}
				Text("The JSON report is redacted: it excludes prompts, transcripts, workspace content, terminal output, credentials, and capability tokens.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
            }
            Section("Project") {
                LabeledContent("Current", value: model.projectPath)
				LabeledContent("Runtime access", value: model.projectRuntimeAuthorizationLabel)
                Button("Choose Project…") { model.openProject() }
            }
			Section("Installation and Data") {
				LabeledContent("Pi Agent data", value: model.nativeAppDataPath)
				Text("Uninstall moves only Pi Agent.app to the Trash. It keeps this App-owned state, saved project bookmarks, migration records, sessions, and Keychain credentials. Your project directories and legacy PI WEB data are never changed.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Button("Reveal Pi Agent Data") { model.revealNativeAppData() }
				Button("Uninstall Pi Agent, Keep Data…", role: .destructive) {
					model.requestUninstallKeepingData()
				}
				.disabled(model.isUninstallPreparing)
				Button("Erase All Native Pi Agent Data…", role: .destructive) {
					model.requestDataErase()
				}
				.disabled(model.isDataErasePreparing)
				if model.isUninstallPreparing {
					ProgressView("Checking active sessions before uninstall…")
				} else if let message = model.uninstallMessage {
					Text(message)
						.font(.caption)
						.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
				}
				if model.isDataErasePreparing {
					ProgressView("Checking active sessions before erasing data…")
				} else if let message = model.dataEraseMessage {
					Text(message)
						.font(.caption)
						.foregroundStyle(.red)
						.fixedSize(horizontal: false, vertical: true)
				}
				Text("Erase All moves Pi Agent Application Support data to the Trash and clears native project bookmarks, migration records, sessions, Runtime state, preferences, and Pi Agent Keychain credentials. It keeps Pi Agent.app, your project directories, and legacy PI WEB files. Keychain credentials cannot be recovered.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Section("Legacy PI WEB migration") {
				Text("This inventory is read-only. It distinguishes data Pi Agent can migrate now from legacy state that remains in place because the native product has no safe target for it yet.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				if model.isLegacyMigrationOverviewLoading {
					ProgressView("Inspecting legacy PI WEB state…")
				} else if let overview = model.legacyMigrationOverview {
					LabeledContent("Legacy data", value: overview.legacyDataDir)
					ForEach(overview.items) { item in
						VStack(alignment: .leading, spacing: 2) {
							LabeledContent(legacyMigrationItemLabel(item.id), value: legacyMigrationActionLabel(item.action))
							Text(item.source)
								.font(.caption)
								.foregroundStyle(.secondary)
							if let count = item.itemCount {
								Text("\(count) item\(count == 1 ? "" : "s") discovered")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							if let issue = item.issue {
								Text(issue)
									.font(.caption)
									.foregroundStyle(.orange)
							}
						}
					}
				}
				if let error = model.legacyMigrationOverviewError {
					Text("Could not inspect legacy PI WEB state: \(error)")
						.font(.caption)
						.foregroundStyle(.orange)
						.fixedSize(horizontal: false, vertical: true)
				}
				Button("Review Legacy Migration") { model.refreshLegacyMigrationOverview() }
					.disabled(model.isLegacyMigrationOverviewLoading)
			}
			Section("Legacy PI WEB projects") {
				Text("Each migration is read back into the native Project Library before Pi Agent records it. Rolling back removes only a bookmark created by that exact migration; it never changes the legacy projects.json, your directory, sessions, or manually added projects.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				if model.isLegacyProjectPreviewLoading {
					ProgressView("Inspecting legacy projects…")
				} else if let preview = model.legacyProjectPreview {
					if let issue = preview.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
					else if preview.candidates.isEmpty { Text(preview.sourceExists ? "No valid legacy projects found." : "No legacy projects.json found.").foregroundStyle(.secondary) }
					else {
						Text("Select each original directory again to create a new macOS bookmark. PI WEB paths alone do not grant Pi Agent access.").font(.caption).foregroundStyle(.secondary)
						ForEach(preview.candidates) { candidate in
							HStack { VStack(alignment: .leading) { Text(candidate.name); Text(candidate.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Button("Re-authorize…") { model.reauthorizeLegacyProject(candidate) } }
						}
					}
				}
				if model.isLegacyProjectMigrationInFlight {
					ProgressView("Updating native project migration…")
				} else if let migration = model.legacyProjectMigration {
					LabeledContent("Last migration", value: migration.state.rawValue)
					if migration.rollbackEligible {
						Button("Roll Back Last Project Migration…", role: .destructive) {
							model.requestLegacyProjectMigrationRollback()
						}
					}
				}
				Button("Review Legacy Projects") { model.refreshLegacyProjectPreview() }
					.disabled(model.isLegacyProjectPreviewLoading || model.isLegacyProjectMigrationInFlight)
			}
            if let taskNotifications = model.taskNotifications {
                NativeTaskNotificationsSection(coordinator: taskNotifications)
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
            Section("Legacy credentials") {
                Text("Pi Agent can copy compatible credentials from the existing auth.json into this Mac's Keychain. Values are never shown here, and the source file remains unchanged.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isLegacyAuthMigrationLoading {
                    ProgressView("Checking legacy credentials…")
                } else if let preview = model.legacyAuthMigrationPreview {
                    if preview.credentials.isEmpty {
                        Text(preview.issue ?? "No legacy credentials found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(preview.credentials) { credential in
                            LabeledContent(credential.providerId, value: credential.type == "oauth" ? "OAuth" : "API key")
                            if credential.status != "ready" {
                                Text("Already in Keychain — migration will not overwrite it.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let issue = preview.issue {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Button("Migrate to Keychain…") { model.requestLegacyAuthMigration() }
                        .disabled(!preview.eligible)
                } else {
                    Text("This Runtime has not reported a legacy credential migration capability.")
                        .foregroundStyle(.secondary)
                }
                if let migration = model.legacyAuthMigration {
                    LabeledContent("Last migration", value: migration.state)
                    if migration.rollbackEligible {
                        Button("Roll Back Last Migration", role: .destructive) { model.rollbackLegacyAuthMigration() }
                    }
                }
                Button("Review Legacy Credentials") { model.refreshLegacyAuthMigrationPreview() }
                    .disabled(model.isLegacyAuthMigrationLoading || !model.canUseProjectRuntime)
            }
        }
        .padding()
        .frame(width: 520)
        .confirmationDialog(
			"Uninstall Pi Agent and keep data?",
			isPresented: $model.showUninstallConfirmation,
			titleVisibility: .visible
		) {
			Button("Move Pi Agent.app to Trash", role: .destructive) { model.confirmUninstallKeepingData() }
			Button("Cancel", role: .cancel) { model.cancelUninstallKeepingData() }
		} message: {
			Text("Pi Agent verifies that no session is active, exits, then moves only its own bundle-ID-verified app to the Trash. It keeps Pi Agent data, project folders, legacy PI WEB state, and Keychain credentials.")
		}
		.sheet(isPresented: $model.showDataEraseConfirmation, onDismiss: model.cancelDataErase) {
			NativeDataEraseSheet(model: model)
		}
		.confirmationDialog(
			"Roll back the last project migration?",
			isPresented: $model.showLegacyProjectMigrationRollbackConfirmation,
			titleVisibility: .visible
		) {
			Button("Roll Back Native Bookmark", role: .destructive) { model.rollbackLegacyProjectMigration() }
			Button("Cancel", role: .cancel) { model.cancelLegacyProjectMigrationRollback() }
		} message: {
			Text("This removes only the native Project Library bookmark that this migration newly created. It does not alter the old PI WEB projects.json, the selected directory, sessions, credentials, or manually added projects.")
		}
		.confirmationDialog(
            "Migrate legacy credentials to Keychain?",
            isPresented: $model.showLegacyAuthMigrationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Migrate to Keychain") { model.migrateLegacyAuth() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the listed providers will be copied. Existing Keychain credentials will not be overwritten, and the old auth.json will remain unchanged.")
        }
    }
}

private func legacyMigrationItemLabel(_ id: String) -> String {
	switch id {
	case "projects": return "Projects"
	case "credentials": return "Provider credentials"
	case "archived-sessions": return "Archived sessions"
	case "machines": return "Remote machines"
	case "unread": return "Unread state"
	default: return id
	}
}

private func legacyMigrationActionLabel(_ action: String) -> String {
	switch action {
	case "reauthorize-projects": return "Re-authorize in Projects"
	case "migrate-to-keychain": return "Migrate to Keychain"
	case "copied-and-retained": return "Copied, source retained"
	case "retained": return "Retained; no native target"
	default: return action
	}
}

private struct NativeTaskNotificationsSection: View {
    @ObservedObject var coordinator: NativeTaskNotificationCoordinator

    var body: some View {
        Section("Notifications") {
            Toggle(
                "Notify when a task needs attention",
                isOn: Binding(
                    get: { coordinator.enabled },
                    set: { coordinator.setEnabled($0) }
                )
            )
            LabeledContent("macOS permission", value: coordinator.authorizationLabel)
            if coordinator.enabled {
                Text("Only explicit Pi task notifications from authorized projects can create alerts while Pi Agent is inactive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The Runtime keeps running, but Pi Agent will not create macOS alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
