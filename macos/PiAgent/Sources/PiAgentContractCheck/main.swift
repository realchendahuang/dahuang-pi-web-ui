import Foundation
import PiAgentCore

@main
struct PiAgentContractCheck {
    static func main() async throws {
        try checkHealthDecoding()
        try checkRuntimeHelloDecoding()
        try checkRuntimeCommandReceiptDecoding()
		try checkGitContractDecoding()
		try checkExtensionInteractionContractDecoding()
        try checkProjectAuthorization()
        try checkSessionAndMessageDecoding()
        try checkStreamingAndTerminalDecoding()
        try await checkRuntimeSupervisorOwnership()
        checkImplicitLaunchIsDisabled()
        try checkExplicitLaunchPlan()
        if let socketPath = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_SOCKET"] {
            let client = UnixSocketRuntimeClient(socketPath: socketPath)
            let health = try await client.health()
            precondition(health.ok)
            let hello = try await client.hello()
            try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
            print("Connected to Runtime: \(health.version.label), active sessions: \(health.activeSessions)")
            let cwd = ProcessInfo.processInfo.environment["PI_AGENT_PROJECT_PATH"]
                ?? FileManager.default.currentDirectoryPath
            let sessions = try await client.listSessions(cwd: cwd)
            print("Loaded \(sessions.count) session projections for \(cwd)")
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

		let receiptData = Data(
			#"{"commandId":"git-1","kind":"commit-git","runtimeEpoch":"epoch-1","status":"completed","startedAt":"2026-08-04T00:00:00Z","completedAt":"2026-08-04T00:00:01Z","result":{"committed":true,"hash":"deadbeef","subject":"native Git","status":{"isGitRepo":true,"hash":"clean","files":[],"submodules":[]}}}"#.utf8
		)
		let receipt = try decoder.decode(RuntimeCommandReceipt.self, from: receiptData)
		precondition(receipt.result?.committed == true)
		precondition(receipt.result?.hash == "deadbeef")
		precondition(receipt.result?.status?.files.isEmpty == true)
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
            #"{"messages":[{"id":"m1","role":"user","content":"hello"},{"id":"m2","role":"assistant","content":[{"type":"thinking","thinking":"private chain"},{"type":"text","text":"world"}]}],"start":0,"total":2}"#.utf8
        )
        let page = try decoder.decode(RuntimeMessagePage.self, from: messageData)
        precondition(page.messages.count == 2)
        precondition(page.messages[0].text == "hello")
        precondition(page.messages[1].text == "world")
        precondition(page.total == 2)
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
