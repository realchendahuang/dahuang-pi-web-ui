import Foundation
import PiAgentCore

@main
struct PiAgentContractCheck {
    static func main() async throws {
        try checkHealthDecoding()
        try checkSessionAndMessageDecoding()
        try checkStreamingAndTerminalDecoding()
        checkImplicitLaunchIsDisabled()
        try checkExplicitLaunchPlan()
        if let socketPath = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_SOCKET"] {
            let client = UnixSocketRuntimeClient(socketPath: socketPath)
            let health = try await client.health()
            precondition(health.ok)
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
            #"{"messages":[{"id":"m1","role":"user","content":"hello"},{"id":"m2","role":"assistant","content":[{"type":"text","text":"world"}]}],"start":0,"total":2}"#.utf8
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
            from: Data(#"{"seq":42,"partial":{"role":"assistant","content":"partial answer"}}"#.utf8)
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
    case timeout
}
