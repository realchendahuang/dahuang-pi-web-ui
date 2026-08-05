import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
	enum ProjectRuntimeAuthorization: Equatable {
		case notRequired
		case authorizing
		case authorized(path: String)
		case failed(message: String)

		var label: String {
			switch self {
			case .notRequired: return "此 Runtime 无需授权"
			case .authorizing: return "正在授权…"
			case let .authorized(path): return "已授权：\(path)"
			case let .failed(message): return "授权失败：\(message)"
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
    /// Settings is an in-app page inside the main window, not a separate scene.
    @Published var showSettingsPage = false
    @Published var prompt = ""
    @Published var promptImageAttachments: [RuntimePromptImageAttachment] = []
    @Published var sessions: [RuntimeSession] = []
    @Published var transcriptMessages: [RuntimeMessage] = []
    @Published var statusBySession: [String: RuntimeSessionStatus] = [:]
    /// Model/thinking-level catalogs for the selected session, loaded on
    /// session selection. The current choice always comes from the status
    /// projection (`statusBySession`), not from these lists.
    @Published var availableModels: [RuntimeSessionModel] = []
    @Published var availableThinkingLevels: [String] = []
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
	@Published var projectRuntimeAuthorization: ProjectRuntimeAuthorization = .notRequired

    let runtimeClient: any RuntimeClient
    let terminalSurfaceController = TerminalSurfaceController()
    let runtimeSupervisor: RuntimeSupervisor?
    private let projectAuthorizationStore: ProjectAuthorizationStore
	private let projectCatalog: NativeProjectCatalog
	private let legacyProjectMigrationCoordinator: NativeLegacyProjectMigrationCoordinator
    let taskNotifications: NativeTaskNotificationCoordinator?
    private var projectAccess: ProjectAccess?

    var sessionStreamTask: Task<Void, Never>?
    var sessionEventSubscription: RuntimeEventSubscription?
    var sessionStreamGeneration = 0
    var lastSessionSequence = 0
    var streamingMessage: RuntimeMessage?
    var terminalTask: Task<Void, Never>?
    var terminalSubscription: RuntimeTerminalSubscription?
    var terminalCWD: String?
    var runtimeRefreshGeneration = RuntimeRefreshGeneration()
    var runtimeRecovery = RuntimeLifecycleRecovery()
    var runtimeRecoveryTask: Task<Void, Never>?
    var workspaceRequestGeneration = 0
    var terminationCheckInFlight = false
    var terminationActiveSessionCount: Int?
    var terminationAbortInFlight = false
    var terminationAbortError: String?
    var uninstallPlan: NativeAppUninstallPlan?
    var dataErasePlan: NativeAppDataErasePlan?
    var maintenanceHelperLaunched = false
    var runtimeEpoch: String?
    var authPollingTask: Task<Void, Never>?

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

    var selectedSessionStatus: RuntimeSessionStatus? {
        guard let selectedSessionID else { return nil }
        return statusBySession[selectedSessionID]
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
            return "Runtime 已断开连接"
        case .connecting:
            return "正在连接…"
        case let .connected(health):
            return health.version.label
        case let .failed(message):
            return "Runtime 不可用：\(message)"
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
			return "Runtime 未能停止所有活跃会话：\(terminationAbortError) 可以保持运行并退出、重试停止，或取消。"
		}
        if let terminationActiveSessionCount {
            return "\(terminationActiveSessionCount) 个活跃会话仍在运行。可以保持捆绑 Runtime 运行并退出、仅停止此 App 拥有的 Runtime，或取消退出。"
        }
        return "无法刷新 Runtime 状态。可以保持捆绑 Runtime 运行、仅停止此 App 拥有的 Runtime，或取消退出。"
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
    func openSettingsPage() {
        showSettingsPage = true
    }

    func closeSettingsPage() {
        showSettingsPage = false
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "使用项目"
        panel.message = "选择 Pi Agent 用于新建和继续对话的项目目录。"
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
			errorMessage = "重新授权 \(project.displayName) 以使用此项目：\(error.localizedDescription)"
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
		panel.prompt = "授权项目"
		panel.message = "选择 \(candidate.name) 的原始目录。只有路径完全一致时 Pi Agent 才会添加它。"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard url.standardizedFileURL.path == URL(fileURLWithPath: candidate.path).standardizedFileURL.path else {
			errorMessage = "请精确选择原遗留项目路径：\(candidate.path)"
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
					socketSecurity: .bundled,
					launchNonce: bundledRuntime.launchNonce,
					projectCapabilityTokenSecret: bundledRuntime.projectCapabilityToken
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
            let message = "Pi Agent.app 缺少其捆绑的 Runtime。请重新构建 App，而不是连接全局守护进程。"
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
    func listModels(sessionId _: String, cwd _: String, runtimeId _: String?) async throws -> [RuntimeSessionModel] { throw RuntimeClientError.connectionFailed(message) }
    func setModel(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        provider _: String,
        modelId _: String
    ) async throws -> RuntimeSessionStatus { throw RuntimeClientError.connectionFailed(message) }
    func listThinkingLevels(sessionId _: String, cwd _: String, runtimeId _: String?) async throws -> [String] { throw RuntimeClientError.connectionFailed(message) }
    func setThinkingLevel(
        sessionId _: String,
        cwd _: String,
        runtimeId _: String?,
        level _: String
    ) async throws -> RuntimeSessionStatus { throw RuntimeClientError.connectionFailed(message) }
    func abort(sessionId _: String, cwd _: String, runtimeId _: String?) async throws { throw RuntimeClientError.connectionFailed(message) }
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

extension AppModel {
    var runtimeClientSocketDescription: String {
        if let client = runtimeClient as? UnixSocketRuntimeClient { return client.socketPath }
        return "已配置的 Runtime 客户端"
    }
}
