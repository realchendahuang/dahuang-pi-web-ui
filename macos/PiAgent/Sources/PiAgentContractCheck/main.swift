import Foundation
import PiAgentCore

@main
struct PiAgentContractCheck {
    static func main() async throws {
        try checkHealthDecoding()
        try checkRuntimeHelloDecoding()
        try checkRuntimeCommandReceiptDecoding()
        try checkProjectCapabilityReceiptDecoding()
        try checkGitContractDecoding()
		try checkSupportReportEncoding()
        try checkWorkspaceContractDecoding()
        try checkExtensionInteractionContractDecoding()
        try checkProjectAuthorization()
        try checkNativeProjectMigrationJournal()
        try checkNativeAppUninstallPlan()
        try checkSessionAndMessageDecoding()
        try checkTaskNotificationDecoding()
        try checkStreamingAndTerminalDecoding()
        checkRuntimeLifecycleRecovery()
        try await checkRuntimeSupervisorOwnership()
        checkImplicitLaunchIsDisabled()
        try checkExplicitLaunchPlan()
        if let socketPath = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_SOCKET"] {
			let client = UnixSocketRuntimeClient(
				socketPath: socketPath,
				projectCapabilityToken: ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_PROJECT_CAPABILITY_TOKEN"]
			)
            let health = try await client.health()
            precondition(health.ok)
            let hello = try await client.hello()
            try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
            print("Connected to Runtime: \(health.version.label), active sessions: \(health.activeSessions)")
            let cwd = ProcessInfo.processInfo.environment["PI_AGENT_PROJECT_PATH"]
                ?? FileManager.default.currentDirectoryPath
            let sessions = try await client.listSessions(cwd: cwd)
            print("Loaded \(sessions.count) session projections for \(cwd)")
            let workspace = try await client.workspaceTree(cwd: cwd, path: nil)
            precondition(!workspace.entries.contains(where: { $0.path.hasPrefix("/") }))
            let packageManifest = try await client.workspaceFile(cwd: cwd, path: "package.json")
            precondition(packageManifest.path == "package.json")
            precondition(!packageManifest.binary)
            print("Loaded \(workspace.entries.count) workspace entries and package.json through the Native Contract")
            let providers = try await client.authProviders()
            precondition(!providers.providers.isEmpty)
            precondition(providers.providers.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
            print("Loaded \(providers.providers.count) provider credential projections through the Native Contract")
            if let sessionID = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_SESSION_ID"],
               let session = sessions.first(where: { $0.id == sessionID })
            {
                let page = try await client.messages(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                let status = try await client.status(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                print("Read session \(session.id): \(page.messages.count) messages, streaming=\(status.isStreaming)")
            }
            if ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_WS_SMOKE"] == "1",
               let session = sessions.first(where: { $0.runtimeId == "pi" }) ?? sessions.first
            {
                let snapshot = try await client.streamSnapshot(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                let subscription = client.subscribe(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                var connected = false
                for try await _ in subscription.ready {
                    connected = true
                    break
                }
                precondition(connected)
                subscription.cancel()
                print("Session stream snapshot seq=\(snapshot.seq), WebSocket handshake passed for \(session.id)")
            }
            if let terminalID = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_TERMINAL_ID"] {
                let subscription = client.subscribeTerminal(id: terminalID, cols: 120, rows: 32)
                var connected = false
                for try await _ in subscription.ready {
                    connected = true
                    break
                }
                precondition(connected)
                subscription.resize(cols: 80, rows: 24)
                subscription.sendInput("printf 'pi-agent-native-terminal-smoke\\n'\r")
                try await waitForTerminalOutput(subscription.events, containing: "pi-agent-native-terminal-smoke")
                subscription.cancel()
                print("Terminal WebSocket handshake passed for \(terminalID)")
            }
        }
        print("PiAgentCore contract checks passed")
    }

    private static func checkHealthDecoding() throws {
        let data = Data(
            #"{"ok":true,"activeSessions":2,"checkedAt":"2026-08-03T00:00:00Z","version":{"component":"sessiond","label":"PI WEB Session Daemon","stale":false,"available":true}}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let health = try decoder.decode(RuntimeHealth.self, from: data)
        precondition(health.ok)
        precondition(health.activeSessions == 2)
        precondition(health.version.component == "sessiond")
        precondition(health.version.label == "PI WEB Session Daemon")
    }

    private static func checkRuntimeHelloDecoding() throws {
        let data = Data(
            #"{"kind":"pi-agent-runtime","protocol":{"major":1,"minor":0},"runtimeEpoch":"epoch-1","nodeVersion":"v24.18.0","architecture":"arm64","manifest":{"schemaVersion":1,"appVersion":"0.1.0","runtimeVersion":"0.1.0","piSdkVersion":"0.81.1"}}"#.utf8
        )
        let hello = try JSONDecoder().decode(RuntimeHello.self, from: data)
        try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
        precondition(hello.runtimeEpoch == "epoch-1")
        precondition(hello.manifest?.piSdkVersion == "0.81.1")
    }

	private static func checkRuntimeCommandReceiptDecoding() throws {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let data = Data(
			#"{"commandId":"command-1","kind":"abort-active-work","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"requested":1,"aborted":[{"sessionId":"s1","runtimeId":"pi"}],"failures":[]}}"#.utf8
		)
		let receipt = try decoder.decode(RuntimeCommandReceipt.self, from: data)
		precondition(receipt.commandId == "command-1")
		precondition(receipt.runtimeEpoch == "epoch-1")
		precondition(receipt.status == "completed")
		precondition(receipt.result?.requested == 1)
		precondition(receipt.result?.failures?.isEmpty == true)

		let promptData = Data(
			#"{"commandId":"command-2","kind":"prompt","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"accepted":true,"sessionId":"s1","runtimeId":"pi"}}"#.utf8
		)
		let promptReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: promptData)
		precondition(promptReceipt.result?.accepted == true)
		precondition(promptReceipt.result?.sessionId == "s1")
		precondition(promptReceipt.recoveredAfterRuntimeRestart == nil)

		let recoveredReceipt = try decoder.decode(
			RuntimeCommandReceipt.self,
			from: Data(#"{"commandId":"command-recovered","kind":"prompt","runtimeEpoch":"epoch-before-restart","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","recoveredAfterRuntimeRestart":true,"result":{"accepted":true,"sessionId":"s1"}}"#.utf8)
		)
		precondition(recoveredReceipt.recoveredAfterRuntimeRestart == true)

		let startData = Data(
			#"{"commandId":"command-3","kind":"start-session","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"created":true,"sessionId":"s2","cwd":"/repo","runtimeId":"pi"}}"#.utf8
		)
		let startReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: startData)
		precondition(startReceipt.result?.created == true)
		precondition(startReceipt.result?.cwd == "/repo")

		let archiveData = Data(
			#"{"commandId":"command-4","kind":"archive-session","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"archived":true,"sessionId":"s2","cwd":"/repo","runtimeId":"pi"}}"#.utf8
		)
		let archiveReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: archiveData)
		precondition(archiveReceipt.result?.archived == true)
		precondition(archiveReceipt.result?.sessionId == "s2")

		let restoreData = Data(
			#"{"commandId":"command-5","kind":"restore-session","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"restored":true,"sessionId":"s2"}}"#.utf8
		)
		let restoreReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: restoreData)
		precondition(restoreReceipt.result?.restored == true)

		let deleteData = Data(
			#"{"commandId":"command-6","kind":"delete-archived-session","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"deleted":true,"sessionId":"s2"}}"#.utf8
		)
		let deleteReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: deleteData)
		precondition(deleteReceipt.result?.deleted == true)

		let forkData = Data(
			#"{"commandId":"command-fork","kind":"fork-session","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"forked":true,"session":{"id":"forked","cwd":"/repo","runtimeId":"pi","path":"/sessions/forked.jsonl","created":"2026-08-04T00:00:00Z","modified":"2026-08-04T00:00:00Z","messageCount":1,"firstMessage":"fork point"},"promptDraft":"fork point"}}"#.utf8
		)
		let forkReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: forkData)
		precondition(forkReceipt.result?.forked == true)
		precondition(forkReceipt.result?.session?.id == "forked")
		precondition(forkReceipt.result?.promptDraft == "fork point")

		let importData = Data(
			#"{"commandId":"command-import","kind":"import-session","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"imported":true,"session":{"id":"imported","cwd":"/repo","runtimeId":"pi","path":"/sessions/imported.jsonl","created":"2026-08-04T00:00:00Z","modified":"2026-08-04T00:00:00Z","messageCount":2,"firstMessage":"imported message"}}}"#.utf8
		)
		let importReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: importData)
		precondition(importReceipt.result?.imported == true)
		precondition(importReceipt.result?.session?.id == "imported")

		let terminalData = Data(
			#"{"commandId":"command-7","kind":"create-terminal","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"created":true,"terminal":{"id":"t1","cwd":"/repo","name":"Pi Agent Terminal","createdAt":"2026-08-04T00:00:00Z","exited":false}}}"#.utf8
		)
		let terminalReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: terminalData)
		precondition(terminalReceipt.result?.created == true)
		precondition(terminalReceipt.result?.terminal?.id == "t1")

		let continuedTerminalData = Data(
			#"{"commandId":"command-8","kind":"continue-terminal","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"continued":true,"terminal":{"id":"t1","cwd":"/repo","name":"Pi Agent Terminal","createdAt":"2026-08-04T00:00:00Z","exited":false}}}"#.utf8
		)
		let continuedTerminalReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: continuedTerminalData)
		precondition(continuedTerminalReceipt.result?.continued == true)
	}

    private static func checkGitContractDecoding() throws {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let statusData = Data(
			#"{"isGitRepo":true,"hash":"status-hash","branch":"main","upstream":"origin/main","ahead":1,"behind":0,"files":[{"path":"Sources/App.swift","index":"modified","workingTree":"unmodified"}],"submodules":[]}"#.utf8
		)
		let status = try decoder.decode(RuntimeGitStatus.self, from: statusData)
		precondition(status.isGitRepo)
		precondition(status.branch == "main")
		precondition(status.files.first?.path == "Sources/App.swift")

		let pushPreviewData = Data(
			#"{"status":{"isGitRepo":true,"hash":"push-status","branch":"main","upstream":"origin/main","ahead":2,"behind":0,"files":[],"submodules":[]},"canPush":true}"#.utf8
		)
		let pushPreview = try decoder.decode(RuntimeGitPushPreview.self, from: pushPreviewData)
		precondition(pushPreview.canPush)
		precondition(pushPreview.status.upstream == "origin/main")

		let revertPreviewData = Data(
			#"{"status":{"isGitRepo":true,"hash":"clean","branch":"main","files":[],"submodules":[]},"canRevert":true,"commit":{"hash":"deadbeef","subject":"latest change"}}"#.utf8
		)
		let revertPreview = try decoder.decode(RuntimeGitRevertPreview.self, from: revertPreviewData)
		precondition(revertPreview.canRevert)
		precondition(revertPreview.commit?.hash == "deadbeef")

		let receiptData = Data(
			#"{"commandId":"git-1","kind":"commit-git","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"committed":true,"hash":"deadbeef","subject":"native Git","status":{"isGitRepo":true,"hash":"clean","files":[],"submodules":[]}}}"#.utf8
		)
		let receipt = try decoder.decode(RuntimeCommandReceipt.self, from: receiptData)
		precondition(receipt.result?.committed == true)
		precondition(receipt.result?.hash == "deadbeef")
        precondition(receipt.result?.status?.files.isEmpty == true)

		let pushReceiptData = Data(
			#"{"commandId":"push-1","kind":"push-git","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-05T00:00:00Z","completedAt":"2026-08-05T00:00:01Z","result":{"pushed":true,"status":{"isGitRepo":true,"hash":"clean","branch":"main","upstream":"origin/main","ahead":0,"behind":0,"files":[],"submodules":[]}}}"#.utf8
		)
		let pushReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: pushReceiptData)
		precondition(pushReceipt.result?.pushed == true)
		precondition(pushReceipt.result?.status?.ahead == 0)

		let discardReceiptData = Data(
			#"{"commandId":"discard-1","kind":"discard-git-paths","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-05T00:00:00Z","completedAt":"2026-08-05T00:00:01Z","result":{"discarded":true,"paths":["Sources/App.swift"],"status":{"isGitRepo":true,"hash":"clean","files":[],"submodules":[]}}}"#.utf8
		)
		let discardReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: discardReceiptData)
		precondition(discardReceipt.result?.discarded == true)
		precondition(discardReceipt.result?.paths == ["Sources/App.swift"])

		let revertReceiptData = Data(
			#"{"commandId":"revert-1","kind":"revert-git-head","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-05T00:00:00Z","completedAt":"2026-08-05T00:00:01Z","result":{"reverted":true,"hash":"reverted","subject":"Revert latest","status":{"isGitRepo":true,"hash":"clean","files":[],"submodules":[]}}}"#.utf8
		)
		let revertReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: revertReceiptData)
		precondition(revertReceipt.result?.reverted == true)
		precondition(revertReceipt.result?.hash == "reverted")

		let checkpointData = Data(
			#"{"commandId":"checkpoint-1","kind":"create-git-checkpoint","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"checkpointed":true,"checkpoint":{"id":"cp-1","sessionId":"thread-1","cwd":"/repo","createdAt":"2026-08-04T00:00:00Z","status":{"isGitRepo":true,"hash":"clean","files":[],"submodules":[]},"unstaged":{"hash":"u","diff":"diff --git","truncated":false},"staged":{"hash":"s","diff":"","truncated":false}}}}"#.utf8
		)
		let checkpointReceipt = try decoder.decode(RuntimeCommandReceipt.self, from: checkpointData)
		precondition(checkpointReceipt.result?.checkpointed == true)
		precondition(checkpointReceipt.result?.checkpoint?.sessionId == "thread-1")
		precondition(checkpointReceipt.result?.checkpoint?.unstaged.diff == "diff --git")
    }

	private static func checkSupportReportEncoding() throws {
		let report = NativeSupportReport(
			generatedAt: Date(timeIntervalSince1970: 1_722_844_800),
			application: .init(
				bundleIdentifier: "com.example.PiAgent",
				version: "0.202608.0",
				build: "42",
				bundlePath: "/Applications/Pi Agent.app"
			),
			runtime: .init(
				socket: "/tmp/pi-agent.sock",
				connectionState: "Connected",
				health: nil,
				hello: nil,
				diagnosticError: nil
			),
			project: .init(path: "/repo", authorization: "Authorized"),
			providers: [
				.init(id: "openai", authType: "oauth", configured: true, source: "keychain"),
				.init(id: "anthropic", authType: "api_key", configured: false, source: nil),
			]
		)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let decoded = try decoder.decode(NativeSupportReport.self, from: report.encodedJSON())
		precondition(decoded.schemaVersion == NativeSupportReport.schemaVersion)
		precondition(decoded.redacted)
		precondition(decoded.providers.map(\.id) == ["anthropic", "openai"])
		precondition(decoded.application.bundlePath == "/Applications/Pi Agent.app")
	}

    private static func checkWorkspaceContractDecoding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tree = try decoder.decode(
            RuntimeWorkspaceTree.self,
            from: Data(#"{"path":"Sources","entries":[{"name":"PiAgent.swift","path":"Sources/PiAgent.swift","type":"file","size":128,"modifiedAt":"2026-08-04T00:00:00Z"}],"scannedAt":"2026-08-04T00:00:00Z","truncated":false}"#.utf8)
        )
        precondition(tree.path == "Sources")
        precondition(tree.entries.first?.id == "Sources/PiAgent.swift")
        precondition(tree.entries.first?.isDirectory == false)

        let file = try decoder.decode(
            RuntimeWorkspaceFile.self,
            from: Data(#"{"path":"Sources/PiAgent.swift","language":"swift","encoding":"utf8","size":128,"modifiedAt":"2026-08-04T00:00:00Z","content":"import SwiftUI","truncated":false,"binary":false}"#.utf8)
        )
        precondition(file.language == "swift")
        precondition(file.content == "import SwiftUI")
        precondition(!file.binary)

        let image = try decoder.decode(
            RuntimeWorkspaceImagePreview.self,
            from: Data(#"{"path":"Assets/agent.png","mimeType":"image/png","size":3,"modifiedAt":"2026-08-04T00:00:00Z","data":"iVBORw=="}"#.utf8)
        )
        precondition(image.path == "Assets/agent.png")
        precondition(image.imageData == Data([0x89, 0x50, 0x4e, 0x47]))

        let writeReceipt = try decoder.decode(
            RuntimeCommandReceipt.self,
            from: Data(#"{"commandId":"workspace-write","kind":"write-workspace-file","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"written":true,"path":"Sources/PiAgent.swift","size":42,"modifiedAt":"2026-08-04T00:00:01Z","created":false}}"#.utf8)
        )
        precondition(writeReceipt.result?.written == true)
        precondition(writeReceipt.result?.path == "Sources/PiAgent.swift")
        precondition(writeReceipt.result?.created == false)

        let deleteReceipt = try decoder.decode(
            RuntimeCommandReceipt.self,
            from: Data(#"{"commandId":"workspace-delete","kind":"delete-workspace-file","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"deletedFile":true,"path":"Sources/PiAgent.swift","existed":true}}"#.utf8)
        )
        precondition(deleteReceipt.result?.deletedFile == true)
        precondition(deleteReceipt.result?.existed == true)

        let providers = try decoder.decode(
            RuntimeAuthProviders.self,
            from: Data(#"{"providers":[{"id":"openai","name":"OpenAI","authType":"api_key","status":{"configured":true,"source":"stored"},"loginFlow":"interactive"}]}"#.utf8)
        )
        precondition(providers.providers.count == 1)
        precondition(providers.providers[0].status.configured)
        precondition(providers.providers[0].status.source == "stored")
    }

    private static func checkExtensionInteractionContractDecoding() throws {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let projection = try decoder.decode(
			RuntimeExtensionInteraction.self,
			from: Data(#"{"id":"interaction-1","sessionId":"s1","cwd":"/repo","kind":"select","title":"Choose","options":["one","two"],"createdAt":"2026-08-04T00:00:00Z","timeoutAt":"2026-08-04T00:01:00Z"}"#.utf8)
		)
		precondition(projection.kind == "select")
		precondition(projection.options == ["one", "two"])

		let receipt = try decoder.decode(
			RuntimeCommandReceipt.self,
			from: Data(#"{"commandId":"interaction-command","kind":"respond-extension-interaction","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"responded":true,"interaction":{"id":"interaction-1","sessionId":"s1","cwd":"/repo","kind":"confirm","title":"Proceed","message":"Continue?","createdAt":"2026-08-04T00:00:00Z"}}}"#.utf8)
		)
		precondition(receipt.result?.responded == true)
		precondition(receipt.result?.interaction?.id == "interaction-1")
	}

	private static func checkProjectCapabilityReceiptDecoding() throws {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let receipt = try decoder.decode(
			RuntimeCommandReceipt.self,
			from: Data(#"{"commandId":"project-capability","kind":"authorize-project","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"authorized":true,"path":"/private/tmp/project"}}"#.utf8)
		)
		precondition(receipt.result?.authorized == true)
		precondition(receipt.result?.path == "/private/tmp/project")
	}

    private static func checkProjectAuthorization() throws {
        let suite = "PiAgentContractCheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ContractCheckError.projectAuthorizationStoreUnavailable
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectAuthorizationStore(defaults: defaults, key: "project")
        let access = try store.authorize(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        precondition(access.url.path == FileManager.default.currentDirectoryPath)
        let restored = store.restore()
        precondition(restored?.url.path == access.url.path)
    }

    private static func checkNativeProjectMigrationJournal() throws {
        let suite = "PiAgentContractCheck.ProjectMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ContractCheckError.projectAuthorizationStoreUnavailable
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let projectPath = projectURL.standardizedFileURL.path

        let catalog = NativeProjectCatalog(defaults: defaults, key: "catalog")
        let journal = NativeProjectMigrationJournal(defaults: defaults, key: "journal")
        let coordinator = NativeLegacyProjectMigrationCoordinator(catalog: catalog, journal: journal)
        let migration = try coordinator.migrate(
            legacyProjectID: "legacy-created",
            legacyPath: projectPath,
            selectedURL: projectURL
        )
        precondition(migration.state == .verified)
        precondition(migration.entries.count == 1)
        precondition(migration.entries[0].created)
        let createdRecord = try catalog.record(id: migration.entries[0].nativeProjectID)
        precondition(createdRecord?.displayPath == projectPath)
        let latestMigration = try coordinator.latestMigration()
        precondition(latestMigration?.id == migration.id)
        precondition(latestMigration?.entries == migration.entries)

        let rolledBack = try coordinator.rollbackLatest()
        precondition(rolledBack.state == .rolledBack)
        precondition(rolledBack.completedAt != nil)
        let removedRecord = try catalog.record(id: migration.entries[0].nativeProjectID)
        precondition(removedRecord == nil)

        let manualCatalog = NativeProjectCatalog(defaults: defaults, key: "manual-catalog")
        let manualActivation = try manualCatalog.rememberAndAccess(projectURL)
        precondition(manualActivation.created)
        let manualJournal = NativeProjectMigrationJournal(defaults: defaults, key: "manual-journal")
        let manualCoordinator = NativeLegacyProjectMigrationCoordinator(catalog: manualCatalog, journal: manualJournal)
        let existingMigration = try manualCoordinator.migrate(
            legacyProjectID: "legacy-preexisting",
            legacyPath: projectPath,
            selectedURL: projectURL
        )
        precondition(!existingMigration.entries[0].created)
        _ = try manualCoordinator.rollbackLatest()
        let manualRecord = try manualCatalog.record(id: manualActivation.record.id)
        precondition(manualRecord?.displayPath == projectPath)

        let failedCatalog = NativeProjectCatalog(defaults: defaults, key: "failed-catalog")
        let failedJournal = NativeProjectMigrationJournal(
            defaults: defaults,
            key: "failed-journal",
            beforeWrite: { throw ContractCheckError.projectMigrationJournalWriteFailure }
        )
        let failedCoordinator = NativeLegacyProjectMigrationCoordinator(catalog: failedCatalog, journal: failedJournal)
        do {
            _ = try failedCoordinator.migrate(
                legacyProjectID: "legacy-journal-failure",
                legacyPath: projectPath,
                selectedURL: projectURL
            )
            preconditionFailure("A migration journal write failure must be reported")
        } catch ContractCheckError.projectMigrationJournalWriteFailure {
            // The coordinator compensates only for the exact new bookmark.
        }
        precondition(failedCatalog.list().isEmpty)

        let mismatchCatalogKey = "mismatch-catalog"
        let mismatchJournalKey = "mismatch-journal"
        let mismatchRecord = NativeProjectBookmark(
            id: "mismatch-native-project",
            displayName: "Other",
            displayPath: "/private/tmp/not-the-legacy-project",
            bookmarkData: Data(),
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 0)
        )
        let mismatchMigration = NativeProjectMigrationRecord(
            id: "mismatch-migration",
            createdAt: Date(timeIntervalSince1970: 0),
            state: .verified,
            entries: [
                .init(
                    legacyProjectID: "legacy-mismatch",
                    legacyPath: projectPath,
                    nativeProjectID: mismatchRecord.id,
                    nativeProjectPath: projectPath,
                    created: true
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode([mismatchRecord]), forKey: mismatchCatalogKey)
        defaults.set(try encoder.encode([mismatchMigration]), forKey: mismatchJournalKey)
        let mismatchCatalog = NativeProjectCatalog(defaults: defaults, key: mismatchCatalogKey)
        let mismatchJournal = NativeProjectMigrationJournal(defaults: defaults, key: mismatchJournalKey)
        let mismatchCoordinator = NativeLegacyProjectMigrationCoordinator(catalog: mismatchCatalog, journal: mismatchJournal)
        do {
            _ = try mismatchCoordinator.rollbackLatest()
            preconditionFailure("A path mismatch must reject rollback")
        } catch NativeProjectMigrationError.catalogReadbackMismatch {
            // The unrelated record must remain untouched.
        }
        let mismatchCatalogRecord = try mismatchCatalog.record(id: mismatchRecord.id)
        precondition(mismatchCatalogRecord == mismatchRecord)
    }

    private static func checkNativeAppUninstallPlan() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-agent-uninstall-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Pi Agent.app", isDirectory: true)
        let helperURL = appURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(NativeAppUninstallPlan.helperName)
        try fileManager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": NativeAppUninstallPlan.expectedBundleIdentifier] as NSDictionary
        try info.write(to: appURL.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let plan = try NativeAppUninstallPlan.prepare(
            appBundleURL: appURL,
            helperURL: helperURL,
            waitForProcessID: 42,
            fileManager: fileManager
        )
        precondition(plan.appBundleURL == appURL.standardizedFileURL.resolvingSymlinksInPath())
        precondition(plan.helperURL == helperURL.standardizedFileURL.resolvingSymlinksInPath())
        precondition(plan.helperArguments == [
            "--uninstall-when-parent-exits",
            "--wait-for-pid", "42",
            "--app-path", plan.appBundleURL.path,
        ])
        do {
            _ = try NativeAppUninstallPlan.prepare(
                appBundleURL: appURL,
                helperURL: helperURL,
                waitForProcessID: 0,
                fileManager: fileManager
            )
            preconditionFailure("The uninstaller must reject an invalid parent process")
        } catch NativeAppMaintenanceError.invalidParentProcess {
            // A stale or missing parent must leave the app bundle untouched.
        }
        do {
            _ = try NativeAppUninstallPlan.prepare(
                appBundleURL: root,
                helperURL: helperURL,
                waitForProcessID: 42,
                fileManager: fileManager
            )
            preconditionFailure("The uninstaller must reject a non-Pi-Agent bundle")
        } catch NativeAppMaintenanceError.invalidAppBundle {
            // The helper never accepts a broad directory as its target.
        }
    }

    private static func checkSessionAndMessageDecoding() throws {
        let sessionData = Data(
            #"{"id":"s1","cwd":"/tmp/project","runtimeId":"pi","path":"/tmp/session.jsonl","persisted":true,"name":"Native smoke test","created":"2026-08-03T00:00:00Z","modified":"2026-08-03T00:01:00Z","messageCount":2,"firstMessage":"hello"}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(RuntimeSession.self, from: sessionData)
        precondition(session.displayTitle == "Native smoke test")
        precondition(session.runtimeId == "pi")
        precondition(session.messageCount == 2)

		let messageData = Data(
			#"{"messages":[{"id":"m1","role":"user","content":"hello"},{"id":"m2","role":"assistant","content":[{"type":"thinking","thinking":"private chain"},{"type":"text","text":"world"},{"type":"image","mimeType":"image/png","data":"QUJD"}]}],"start":0,"total":2}"#.utf8
        )
        let page = try decoder.decode(RuntimeMessagePage.self, from: messageData)
        precondition(page.messages.count == 2)
		precondition(page.messages[0].text == "hello")
		precondition(page.messages[1].text == "world")
		precondition(page.messages[1].images.count == 1)
		precondition(page.messages[1].images[0].imageData == Data([0x41, 0x42, 0x43]))

		let promptAttachment = RuntimePromptImageAttachment(
			name: "shot.png", mimeType: "image/png", data: "QUJD", size: 3
		)
		let encodedAttachment = try JSONSerialization.jsonObject(
			with: JSONEncoder().encode(promptAttachment)
		) as? [String: Any]
		precondition(encodedAttachment?["kind"] as? String == "image")
		precondition(encodedAttachment?["id"] == nil)
        precondition(page.total == 2)
    }

    private static func checkTaskNotificationDecoding() throws {
        let decoder = JSONDecoder()
        let inbox = try decoder.decode(
            RuntimeSessionNotificationInbox.self,
            from: Data(#"{"daemonInstanceId":"daemon-1","catalogRevision":7,"summary":{"sessionId":"s1","cwd":"/repo","inboxRevision":3,"retainedCount":1,"discardedCount":0,"highestSeverity":"warning"},"notifications":[{"id":"notice-1","message":"Task needs attention","truncated":false,"severity":"warning","receivedAt":"2026-08-05T00:00:00.000Z","order":4}]}"#.utf8)
        )
        precondition(inbox.daemonInstanceId == "daemon-1")
        precondition(inbox.summary.sessionId == "s1")
        precondition(inbox.summary.cwd == "/repo")
        precondition(inbox.notifications.first?.message == "Task needs attention")
        precondition(inbox.notifications.first?.order == 4)

        let event = try decoder.decode(
            RuntimeNotificationSummaryEvent.self,
            from: Data(#"{"type":"notifications.summary","daemonInstanceId":"daemon-1","catalogRevision":7,"summary":{"sessionId":"s1","cwd":"/repo","inboxRevision":3,"retainedCount":1,"discardedCount":0,"highestSeverity":"warning"}}"#.utf8)
        )
        precondition(event.type == "notifications.summary")
        precondition(event.daemonInstanceId == "daemon-1")
        precondition(event.summary.sessionId == "s1")
        precondition(event.summary.cwd == "/repo")
    }

    private static func checkStreamingAndTerminalDecoding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            RuntimeStreamSnapshot.self,
            from: Data(#"{"seq":42,"partial":{"role":"assistant","content":[{"type":"thinking","thinking":"private chain"},{"type":"text","text":"partial answer"}]}}"#.utf8)
        )
        precondition(snapshot.seq == 42)
        precondition(snapshot.partial?.role == "assistant")
        precondition(snapshot.partial?.text == "partial answer")

        let event = try decoder.decode(
            RuntimeSessionEvent.self,
            from: Data(#"{"type":"assistant.delta","text":"hello","seq":43}"#.utf8)
        )
        precondition(event.type == "assistant.delta")
        precondition(event.seq == 43)
        precondition(event.text == "hello")

        let terminal = try decoder.decode(
            RuntimeTerminalEvent.self,
            from: Data(#"{"type":"output","data":"$ ","replay":true}"#.utf8)
        )
        precondition(terminal.type == "output")
        precondition(terminal.data == "$ ")
        precondition(terminal.replay == true)
    }

    private static func checkRuntimeLifecycleRecovery() {
        var recovery = RuntimeLifecycleRecovery()
        precondition(!recovery.scheduleRecoveryIfNeeded(ownsRuntime: false))
        precondition(recovery.scheduleRecoveryIfNeeded(ownsRuntime: true))
        precondition(!recovery.scheduleRecoveryIfNeeded(ownsRuntime: true))
        precondition(recovery.prepareForSleep())
        precondition(!recovery.consumeScheduledRecovery())
        precondition(!recovery.scheduleRecoveryIfNeeded(ownsRuntime: true))
        precondition(recovery.recoverAfterWake())
        precondition(!recovery.recoverAfterWake())
        precondition(recovery.scheduleRecoveryIfNeeded(ownsRuntime: true))
        recovery.cancelScheduledRecovery()
        precondition(!recovery.consumeScheduledRecovery())

        var refreshGeneration = RuntimeRefreshGeneration()
        let first = refreshGeneration.begin(cwd: "/projects/first")
        precondition(refreshGeneration.isCurrent(first, cwd: "/projects/first"))
        let second = refreshGeneration.begin(cwd: "/projects/second")
        precondition(!refreshGeneration.isCurrent(first, cwd: "/projects/first"))
        precondition(refreshGeneration.isCurrent(second, cwd: "/projects/second"))
        refreshGeneration.invalidate()
        precondition(!refreshGeneration.isCurrent(second, cwd: "/projects/second"))
    }

    /// This executable doubles as the portable native smoke harness because
    /// the current Command Line Tools installation cannot load XCTest or the
    /// Swift Testing macro plugin. These checks exercise the same public
    /// boundary that the packaged app uses without starting a Pi provider.
    private static func checkRuntimeSupervisorOwnership() async throws {
        let compatibleClient = ContractRuntimeClient(
            hello: compatibleRuntimeHello(),
            health: healthyRuntime()
        )
        let reuseValidation = ValidationCounter()
        let reuseSupervisor = RuntimeSupervisor(
            plan: contractShellPlan("exit 97"),
            validateBeforeStart: { reuseValidation.increment() }
        )
        let reusedHealth = try await reuseSupervisor.ensureRunning(
            using: compatibleClient,
            attempts: 1,
            retryDelayNanoseconds: 0
        )
        precondition(reusedHealth == healthyRuntime())
        precondition(reuseValidation.count == 0)
        precondition(!reuseSupervisor.isRunning)

        let launchGate = RuntimeReadinessGate()
        let unavailableClient = ContractRuntimeClient(
            hello: compatibleRuntimeHello(),
            health: healthyRuntime(),
            readinessGate: launchGate
        )
        let ownedValidation = ValidationCounter()
        let ownedSupervisor = RuntimeSupervisor(
            plan: contractShellPlan("sleep 20"),
            validateBeforeStart: {
                ownedValidation.increment()
                launchGate.open()
            }
        )
        defer { ownedSupervisor.stop() }
        let startedHealth = try await ownedSupervisor.ensureRunning(
            using: unavailableClient,
            attempts: 2,
            retryDelayNanoseconds: 0
        )
        precondition(startedHealth == healthyRuntime())
        precondition(ownedValidation.count == 1)
        precondition(ownedSupervisor.isRunning)

        let lockDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-agent-contract-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let contentionGate = RuntimeReadinessGate()
        let contentionStarts = ValidationCounter()
        let contentionPlan = contractShellPlan(
            "sleep 20",
            socketPath: lockDirectory.appendingPathComponent("sessiond.sock").path
        )
        let firstSupervisor = RuntimeSupervisor(
            plan: contentionPlan,
            validateBeforeStart: {
                contentionStarts.increment()
                contentionGate.open()
            }
        )
        let secondSupervisor = RuntimeSupervisor(
            plan: contentionPlan,
            validateBeforeStart: {
                contentionStarts.increment()
                contentionGate.open()
            }
        )
        defer {
            firstSupervisor.stop()
            secondSupervisor.stop()
        }
        let contentionClient = ContractRuntimeClient(
            hello: compatibleRuntimeHello(),
            health: healthyRuntime(),
            readinessGate: contentionGate
        )
        async let firstHealth = firstSupervisor.ensureRunning(
            using: contentionClient,
            attempts: 2,
            retryDelayNanoseconds: 0
        )
        async let secondHealth = secondSupervisor.ensureRunning(
            using: contentionClient,
            attempts: 2,
            retryDelayNanoseconds: 0
        )
        let firstResult = try await firstHealth
        let secondResult = try await secondHealth
        precondition(firstResult == healthyRuntime())
        precondition(secondResult == healthyRuntime())
        precondition(contentionStarts.count == 1)
        precondition(firstSupervisor.isRunning != secondSupervisor.isRunning)

        let incompatibleClient = ContractRuntimeClient(
            hello: RuntimeHello(
                kind: "pi-agent-runtime",
                protocolVersion: RuntimeProtocolVersion(major: 2, minor: 0),
                runtimeEpoch: "old-runtime",
                nodeVersion: "v26.5.0",
                architecture: "arm64",
                manifest: nil
            ),
            health: healthyRuntime()
        )
        let incompatibleSupervisor = RuntimeSupervisor(plan: contractShellPlan("sleep 20"))
        defer { incompatibleSupervisor.stop() }
        do {
            _ = try await incompatibleSupervisor.ensureRunning(
                using: incompatibleClient,
                attempts: 1,
                retryDelayNanoseconds: 0
            )
            preconditionFailure("Incompatible Runtime must not be reused")
        } catch let error as RuntimeClientError {
            guard case .incompatibleRuntime = error else { throw error }
        }
        precondition(incompatibleSupervisor.isRunning)
    }

    private static func contractShellPlan(
        _ command: String,
        socketPath: String = "/tmp/pi-agent-contract-check.sock"
    ) -> RuntimeLaunchPlan {
        RuntimeLaunchPlan(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            socketPath: socketPath
        )
    }

    private static func healthyRuntime() -> RuntimeHealth {
        RuntimeHealth(
            ok: true,
            activeSessions: 2,
            checkedAt: Date(timeIntervalSince1970: 1_722_643_200),
            version: .init(component: "sessiond", label: "Session daemon", stale: false, available: true)
        )
    }

    private static func compatibleRuntimeHello() -> RuntimeHello {
        RuntimeHello(
            kind: "pi-agent-runtime",
            protocolVersion: RuntimeProtocolVersion(major: BundledRuntime.protocolMajor, minor: 0),
            runtimeEpoch: "current-runtime",
            nodeVersion: "v26.5.0",
            architecture: "arm64",
            manifest: nil
        )
    }

    private static func checkImplicitLaunchIsDisabled() {
        let plan = RuntimeLaunchPlan.fromEnvironment(
            ["PATH": "/usr/bin"],
            defaultSocketPath: "/tmp/pi-agent.sock"
        )
        precondition(plan == nil)
    }

    private static func waitForTerminalOutput(
        _ events: AsyncThrowingStream<RuntimeTerminalEvent, Error>,
        containing marker: String
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await event in events {
                    if event.type == "output", event.data?.contains(marker) == true { return true }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw ContractCheckError.timeout
            }
            guard try await group.next() == true else { throw ContractCheckError.timeout }
            group.cancelAll()
        }
    }

    private static func checkExplicitLaunchPlan() throws {
        guard let plan = RuntimeLaunchPlan.fromEnvironment(
            [
                "PI_AGENT_RUNTIME_EXECUTABLE": "/usr/local/bin/node",
                "PI_AGENT_RUNTIME_SCRIPT": "/app/runtime.js",
                "PI_AGENT_RUNTIME_SOCKET": "/tmp/pi-agent.sock",
                "PI_AGENT_RUNTIME_WORKING_DIRECTORY": "/app",
            ],
            defaultSocketPath: "/tmp/default.sock"
        ) else {
            throw ContractCheckError.missingExplicitPlan
        }

        precondition(plan.executable.path == "/usr/local/bin/node")
        precondition(plan.arguments == ["/app/runtime.js"])
        precondition(plan.socketPath == "/tmp/pi-agent.sock")
        precondition(plan.workingDirectory?.path == "/app")
    }
}

private enum ContractCheckError: Error {
    case missingExplicitPlan
    case projectAuthorizationStoreUnavailable
    case projectMigrationJournalWriteFailure
    case timeout
}

private actor ContractRuntimeClient: RuntimeHelloClient {
    private let helloResponse: RuntimeHello
    private let healthResponse: RuntimeHealth
    private var remainingFailures: Int
    private let readinessGate: RuntimeReadinessGate?

    init(
        hello: RuntimeHello,
        health: RuntimeHealth,
        failuresBeforeSuccess: Int = 0,
        readinessGate: RuntimeReadinessGate? = nil
    ) {
        helloResponse = hello
        healthResponse = health
        remainingFailures = failuresBeforeSuccess
        self.readinessGate = readinessGate
    }

    func health() async throws -> RuntimeHealth {
        if readinessGate?.isOpen == false {
            throw RuntimeClientError.connectionFailed("Runtime socket is not ready")
        }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw RuntimeClientError.connectionFailed("Runtime socket is not ready")
        }
        return healthResponse
    }

    func hello() async throws -> RuntimeHello {
        if readinessGate?.isOpen == false {
            throw RuntimeClientError.connectionFailed("Runtime socket is not ready")
        }
        if remainingFailures > 0 {
            throw RuntimeClientError.connectionFailed("Runtime socket is not ready")
        }
        return helloResponse
    }
}

private final class RuntimeReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func open() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
