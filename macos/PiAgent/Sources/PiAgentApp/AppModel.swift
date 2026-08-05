import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
	private enum ProjectRuntimeAuthorization: Equatable {
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
                        receipt.error ?? "Runtime 中止命令失败。"
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
                            "Runtime 未授权所选项目。"
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
			errorMessage = "请先授权所选项目，再创建对话。"
			return
		}
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再创建对话。"
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
                        "Runtime 会话回执缺少新建会话结果。"
                    )
                }
                let createdCWD = receipt.result?.cwd ?? cwd
                let sessions = try await client.listSessions(cwd: createdCWD)
                guard let session = sessions.first(where: { $0.id == createdSessionID }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 已创建对话，但会话投影中未找到它。请重新连接以刷新。"
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
            errorMessage = "请先选择一个对话，再发送消息。"
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = promptImageAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isSending else { return }
		guard canUseProjectRuntime else {
			errorMessage = "请先授权所选项目，再发送消息。"
			return
		}
		guard session.archived != true else {
			errorMessage = "请先恢复此已归档对话，再发送消息。"
			return
		}

        let client = runtimeClient
        let cwd = projectPath
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再发送消息。"
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
                        "Runtime 消息回执缺少已接受的会话结果。"
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
        panel.prompt = "添加图片"
        panel.message = "Pi Agent 会将支持的图片内联发送到所选对话。每张图片不得超过 4.5 MB。"
        guard panel.runModal() == .OK else { return }

        var accepted: [RuntimePromptImageAttachment] = []
        var rejected: [String] = []
        for url in panel.urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count > 0 else { throw RuntimeClientError.serverError(400, "图片为空。") }
                guard data.count <= nativeInlineImageLimit else {
                    throw RuntimeClientError.serverError(400, "图片超过 Pi 的 4.5 MB 内联上限。")
                }
                guard let mimeType = nativeImageMimeType(for: url) else {
                    throw RuntimeClientError.serverError(400, "仅支持 PNG、JPEG、GIF 和 WebP 图片。")
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
        if accepted.count > capacity { rejected.append("超过 \(nativePromptAttachmentLimit) 张图片") }
        if !rejected.isEmpty {
            errorMessage = "无法添加：\(rejected.joined(separator: "，"))。"
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
            errorMessage = "请先重新连接 Runtime，再分叉对话。"
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
                        "此对话没有可用于分叉的用户消息。"
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
            errorMessage = "请先重新连接 Runtime，再分叉对话。"
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
                        "Runtime 分叉回执缺少分叉会话结果。"
                    )
                }
                let refreshed = try await client.listSessions(cwd: forked.cwd)
                guard refreshed.contains(where: { $0.id == forked.id }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 已分叉对话，但会话投影中未找到它。请重新连接以刷新。"
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
            errorMessage = "请先选择一个未归档的对话，再导入会话。"
            return
        }
        guard session.archived != true else {
            errorMessage = "请先恢复此已归档对话，再导入会话。"
            return
        }
        guard !isSending else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "导入对话"
        panel.message = "选择一个 Pi 会话 JSONL 文件。Pi Agent 会将其副本导入此项目的会话存储。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performSessionImport(session, inputPath: url.path)
    }

    private func performSessionImport(_ session: RuntimeSession, inputPath: String) {
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再导入会话。"
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
                        "Runtime 导入回执缺少导入会话结果。"
                    )
                }
                let refreshed = try await client.listSessions(cwd: imported.cwd)
                guard refreshed.contains(where: { $0.id == imported.id }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 已导入对话，但会话投影中未找到它。请重新连接以刷新。"
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
            errorMessage = "请先重新连接 Runtime，再修改对话。"
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
                        "Runtime 对话变更回执缺少完成结果。"
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
                "已连接的 Runtime 不提供原生身份握手。"
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
            throw RuntimeClientError.serverError(500, "Runtime 返回了错误命令类型的回执。")
        }
        guard receipt.runtimeEpoch == expectedRuntimeEpoch || receipt.recoveredAfterRuntimeRestart == true else {
            throw RuntimeClientError.incompatibleRuntime(
                "命令执行期间 Runtime 已重启。请重新连接后重试。"
            )
        }
        guard receipt.status == "completed" else {
            throw RuntimeClientError.serverError(
                500,
                receipt.error ?? "Runtime 命令失败。"
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
		else { errorMessage = "请先选择对话并重新连接 Runtime，再创建检查点。"; return }
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
					throw RuntimeClientError.serverError(500, "Runtime 检查点回执缺少审查快照。")
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
		else { errorMessage = "请先重新连接 Runtime，再放弃 Git 更改。"; return }
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
					throw RuntimeClientError.serverError(500, "Runtime 放弃更改回执缺少 Git 状态投影。")
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
		else { errorMessage = "请先重新连接 Runtime，再推送更改。"; return }
		let cwd = projectPath
		Task { [weak self] in
			guard let self else { return }
			do {
				let preview = try await client.gitPushPreview(cwd: cwd)
				guard self.projectPath == cwd else { return }
				self.gitPushPreview = preview
				guard preview.canPush else {
					self.errorMessage = preview.reason ?? "当前分支无法推送。"
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
		else { errorMessage = "请先重新连接 Runtime，再撤销 Git 提交。"; return }
		let cwd = projectPath
		Task { [weak self] in
			guard let self else { return }
			do {
				let preview = try await client.gitRevertPreview(cwd: cwd)
				guard self.projectPath == cwd else { return }
				self.gitRevertPreview = preview
				guard preview.canRevert else {
					self.errorMessage = preview.reason ?? "最新提交无法撤销。"
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
		else { errorMessage = "请先刷新最新提交的撤销预览，再继续。"; return }
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
					throw RuntimeClientError.serverError(500, "Runtime 撤销回执缺少 Git 状态投影。")
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
		else { errorMessage = "请先重新连接 Runtime，再提交更改。"; return }
		let message = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !message.isEmpty else { errorMessage = "请输入提交信息。"; return }
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
					throw RuntimeClientError.serverError(500, "Runtime 提交回执缺少 Git 状态投影。")
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
		else { errorMessage = "请先刷新 Git 推送预览，再推送更改。"; return }
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
					throw RuntimeClientError.serverError(500, "Runtime 推送回执缺少 Git 状态投影。")
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
		else { errorMessage = "请先重新连接 Runtime，再更改 Git 状态。"; return }
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
					throw RuntimeClientError.serverError(500, "Runtime Git 回执缺少完成结果。")
				}
				guard let status = receipt.result?.status else {
					throw RuntimeClientError.serverError(500, "Runtime Git 回执缺少 Git 状态投影。")
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
		panel.message = "报告仅包含 App 与 Runtime 的版本和状态元数据，绝不包含提示词、对话记录、项目文件内容、凭据或能力令牌。"
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
				self.supportReportMessage = "已将脱敏报告保存到 \(url.path)"
			} catch {
				self.supportReportMessage = "无法保存支持报告：\(error.localizedDescription)"
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
			uninstallMessage = "仅当使用 Pi Agent.app 捆绑的 Runtime 时才能自动卸载。此连接为外部连接，Pi Agent 不会停止或移除它。"
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
					throw RuntimeClientError.serverError(409, "请先结束或停止 \(health.activeSessions) 个活跃会话，再卸载 Pi Agent。")
				}
				self.isUninstallPreparing = false
				self.showUninstallConfirmation = true
			} catch {
				self.isUninstallPreparing = false
				self.uninstallMessage = "Pi Agent 未能开始卸载：\(error.localizedDescription)"
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
					throw RuntimeClientError.serverError(409, "卸载前有会话开始运行。Pi Agent 未改动应用包。")
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
				self.uninstallMessage = "Pi Agent 未能开始卸载：\(error.localizedDescription)"
			}
		}
	}

	func requestDataErase() {
		guard !isDataErasePreparing, !maintenanceHelperLaunched else { return }
		guard runtimeSupervisor != nil else {
			dataEraseMessage = "仅当使用 Pi Agent.app 捆绑的 Runtime 时才能自动抹掉数据。此连接为外部连接，Pi Agent 不会移除任何数据。"
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
					throw RuntimeClientError.serverError(409, "有会话正在运行。Pi Agent 未改动任何数据。")
				}
				self.isDataErasePreparing = false
				self.dataEraseConfirmationText = ""
				self.showDataEraseConfirmation = true
			} catch {
				self.isDataErasePreparing = false
				self.dataEraseMessage = "Pi Agent 未能开始抹掉数据：\(error.localizedDescription)"
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
					throw RuntimeClientError.serverError(409, "抹掉数据前有会话开始运行。Pi Agent 未改动任何数据。")
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
				self.dataEraseMessage = "Pi Agent 未能开始抹掉数据：\(error.localizedDescription)"
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
                    throw RuntimeClientError.serverError(500, "Runtime 迁移回执缺少完成结果。")
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
                    throw RuntimeClientError.serverError(500, "Runtime 回滚回执缺少完成结果。")
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
                    throw RuntimeClientError.serverError(500, "Runtime 文件写入回执不完整。")
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
            workspaceErrorMessage = "请输入目标路径。"
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
                    throw RuntimeClientError.serverError(500, "Runtime 文件移动回执不完整。")
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
            workspaceErrorMessage = "请输入文件路径。"
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
                    throw RuntimeClientError.serverError(500, "Runtime 文件创建回执不完整。")
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
                    throw RuntimeClientError.serverError(500, "Runtime 文件删除回执不完整。")
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
            terminalErrorMessage = "此 Runtime 不提供终端界面。"
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
                            "请先重新连接 Runtime，再创建终端。"
                        )
                    }
                    let commandId = UUID().uuidString
                    let receipt: RuntimeCommandReceipt
                    do {
                        receipt = try await client.createTerminal(
                            cwd: cwd,
                            name: "Pi Agent 终端",
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
                            "Runtime 终端回执缺少新建终端结果。"
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
                                self.terminalErrorMessage = event.message ?? "终端流已失败。"
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
                        self.terminalErrorMessage = "终端正在重新连接：\(error.localizedDescription)"
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
                        "Runtime 终端回执缺少继续终端结果。"
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
                    self.errorMessage = "会话流正在重新连接：\(error.localizedDescription)"
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
            errorMessage = event.errorMessage ?? event.text ?? "会话报告了一个错误。"
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
				self.errorMessage = "无法刷新扩展对话框：\(error.localizedDescription)"
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
			errorMessage = "请先重新连接 Runtime，再回应扩展对话框。"
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
					throw RuntimeClientError.serverError(500, "Runtime 交互回执不完整。")
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
