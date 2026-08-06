import Foundation
import PiAgentCore

extension UnixSocketRuntimeClient {
    public func health() async throws -> RuntimeHealth {
        try await request(method: "GET", path: "/health")
    }

    public func hello() async throws -> RuntimeHello {
        let hello: RuntimeHello = try await request(method: "GET", path: "/runtime/hello")
        if let launchNonce { try hello.requireMatchingLaunchNonce(launchNonce.currentValue) }
        return hello
    }

    public func legacyProjectMigrationPreview() async throws -> RuntimeLegacyProjectPreview {
        try await request(method: "GET", path: "/projects/legacy-migration/preview")
    }

    public func legacyMigrationOverview() async throws -> RuntimeLegacyMigrationOverview {
        try await request(method: "GET", path: "/migration/legacy/overview")
    }

    public func listSessions(cwd: String) async throws -> [RuntimeSession] {
        try await request(
            method: "GET",
            path: "/sessions",
            query: query(cwd: cwd, runtimeId: nil)
        )
    }

    public func startSession(
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/sessions",
            body: StartSessionPayload(
                cwd: cwd,
                runtimeId: runtimeId,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func messages(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeMessagePage {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/messages",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func status(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeSessionStatus {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/status",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func listModels(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> [RuntimeSessionModel] {
        let envelope: SessionModelsEnvelope = try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/models",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
        return envelope.models
    }

    public func setModel(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        provider: String,
        modelId: String
    ) async throws -> RuntimeSessionStatus {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/model",
            body: SetModelPayload(cwd: cwd, provider: provider, modelId: modelId)
        )
    }

    public func listThinkingLevels(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> [String] {
        let envelope: ThinkingLevelsEnvelope = try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/thinking-levels",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
        return envelope.levels
    }

    public func setThinkingLevel(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        level: String
    ) async throws -> RuntimeSessionStatus {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/thinking-level",
            body: SetThinkingLevelPayload(cwd: cwd, level: level)
        )
    }

    public func cycleModel(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        direction: String
    ) async throws -> RuntimeSessionStatus {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/model/cycle",
            body: CycleModelPayload(cwd: cwd, direction: direction)
        )
    }

    public func cycleThinkingLevel(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeSessionStatus {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/thinking-level/cycle",
            body: CycleThinkingLevelPayload(cwd: cwd)
        )
    }

    public func abort(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws {
        let _: AbortEnvelope = try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/abort",
            body: AbortPayload(cwd: cwd)
        )
    }

    public func unreadCatalog(cwd: String) async throws -> RuntimeUnreadCatalog {
        try await request(
            method: "GET",
            path: "/sessions/unread",
            query: [(cwd, cwd)]
        )
    }

    public func acknowledgeUnread(
        sessionId: String,
        cwd: String,
        catalogId: String,
        throughCompletionOrder: Int
    ) async throws -> RuntimeUnreadCatalog {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/unread/acknowledge",
            body: UnreadAcknowledgePayload(
                cwd: cwd,
                catalogId: catalogId,
                throughCompletionOrder: throughCompletionOrder
            )
        )
    }

    public func prompt(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        text: String,
        attachments: [RuntimePromptImageAttachment],
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/prompt",
            query: nil,
            body: PromptPayload(
                cwd: cwd,
                text: text,
                runtimeId: runtimeId,
                attachments: attachments,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func abortActiveWork(
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/runtime/commands/abort-active-work",
            body: RuntimeCommandPayload(
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func authorizeProject(path: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt {
        try await request(method: "POST", path: "/runtime/projects/authorize", body: AuthorizeProjectPayload(path: path, commandId: commandId, runtimeEpoch: expectedRuntimeEpoch))
    }

    public func archiveSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await sessionMutation(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/archive",
            cwd: cwd,
            runtimeId: runtimeId,
            commandId: commandId,
            expectedRuntimeEpoch: expectedRuntimeEpoch
        )
    }

    public func restoreSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await sessionMutation(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/restore",
            cwd: cwd,
            runtimeId: runtimeId,
            commandId: commandId,
            expectedRuntimeEpoch: expectedRuntimeEpoch
        )
    }

    public func deleteArchivedSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "DELETE",
            path: "/sessions/\(Self.pathSegment(sessionId))",
            query: query(cwd: cwd, runtimeId: runtimeId),
            body: RuntimeCommandPayload(
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func forkCandidates(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> [RuntimeForkCandidate] {
        let response: ForkCandidatesResponse = try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/fork-candidates",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
        return response.candidates
    }

    public func forkSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        entryId: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/fork",
            body: ForkSessionPayload(
                cwd: cwd,
                runtimeId: runtimeId,
                entryId: entryId,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func importSession(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        inputPath: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/import",
            body: ImportSessionPayload(
                cwd: cwd,
                runtimeId: runtimeId,
                inputPath: inputPath,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func commandReceipt(commandId: String) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "GET",
            path: "/runtime/commands/\(Self.pathSegment(commandId))"
        )
    }

    public func listExtensionInteractions(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> [RuntimeExtensionInteraction] {
        let response: ExtensionInteractionsResponse = try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/interactions",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
        return response.interactions
    }

    public func respondToExtensionInteraction(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        interactionId: String,
        response: RuntimeExtensionInteractionResponse,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/interactions/\(Self.pathSegment(interactionId))/respond",
            body: ExtensionInteractionResponsePayload(
                cwd: cwd,
                runtimeId: runtimeId,
                response: response,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func streamSnapshot(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeStreamSnapshot {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/stream-snapshot",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func subscribe(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) -> RuntimeEventSubscription {
        let runner = UnixSocketStreamRunner<RuntimeSessionEvent>(
            socketPath: socketPath,
            path: "/sessions/\(Self.pathSegment(sessionId))/events",
            query: query(cwd: cwd, runtimeId: runtimeId),
            capabilityToken: effectiveProjectCapabilityToken,
            socketSecurity: socketSecurity,
            decode: { data in
                try JSONDecoder().decode(RuntimeSessionEvent.self, from: data)
            }
        )
        return runner.eventSubscription()
    }

    public func notificationInbox(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeSessionNotificationInbox {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/notifications",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func subscribeNotificationSummaries(cwd: String) -> RuntimeNotificationSubscription {
        let runner = UnixSocketStreamRunner<RuntimeNotificationSummaryEvent>(
            socketPath: socketPath,
            path: "/sessions/notifications/events",
            query: [("cwd", cwd)],
            capabilityToken: effectiveProjectCapabilityToken,
            socketSecurity: socketSecurity,
            decode: { data in
                try JSONDecoder().decode(RuntimeNotificationSummaryEvent.self, from: data)
            }
        )
        return runner.notificationSubscription()
    }

}
