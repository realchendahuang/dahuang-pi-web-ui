import Foundation
import PiAgentCore

@main
struct PiAgentContractCheck {
    static func main() async throws {
        try checkHealthDecoding()
        checkImplicitLaunchIsDisabled()
        try checkExplicitLaunchPlan()
        if let socketPath = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_SOCKET"] {
            let health = try await UnixSocketRuntimeClient(socketPath: socketPath).health()
            precondition(health.ok)
            print("Connected to Runtime: \(health.version.label), active sessions: \(health.activeSessions)")
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

    private static func checkImplicitLaunchIsDisabled() {
        let plan = RuntimeLaunchPlan.fromEnvironment(
            ["PATH": "/usr/bin"],
            defaultSocketPath: "/tmp/pi-agent.sock"
        )
        precondition(plan == nil)
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
}
