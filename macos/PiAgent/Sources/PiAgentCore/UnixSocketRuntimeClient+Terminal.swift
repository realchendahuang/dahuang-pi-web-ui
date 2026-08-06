import Foundation
import PiAgentCore

extension UnixSocketRuntimeClient {
    public func listTerminals(cwd: String) async throws -> [RuntimeTerminalInfo] {
        try await request(
            method: "GET",
            path: "/terminals",
            query: [("cwd", cwd)]
        )
    }

    public func createTerminal(
        cwd: String,
        name: String,
        cols: Int,
        rows: Int,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/terminals",
            body: TerminalCreatePayload(
                cwd: cwd,
                name: name,
                cols: cols,
                rows: rows,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func continueTerminal(
        id: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/terminals/\(Self.pathSegment(id))/continue",
            body: RuntimeCommandPayload(
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func subscribeTerminal(
        id: String,
        cols: Int,
        rows: Int
    ) -> RuntimeTerminalSubscription {
        let runner = UnixSocketStreamRunner<RuntimeTerminalEvent>(
            socketPath: socketPath,
            path: "/terminals/\(Self.pathSegment(id))/socket",
            query: [("cols", String(cols)), ("rows", String(rows))],
            capabilityToken: effectiveProjectCapabilityToken,
            socketSecurity: socketSecurity,
            decode: { data in
                try JSONDecoder().decode(RuntimeTerminalEvent.self, from: data)
            }
        )
        return runner.terminalSubscription()
    }

}
