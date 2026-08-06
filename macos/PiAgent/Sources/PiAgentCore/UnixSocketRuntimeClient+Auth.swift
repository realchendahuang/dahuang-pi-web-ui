import Foundation
import PiAgentCore

extension UnixSocketRuntimeClient {
    public func authProviders() async throws -> RuntimeAuthProviders {
        try await request(method: "GET", path: "/auth/providers", query: [("mode", "login")])
    }

    public func startOAuthLogin(providerId: String) async throws -> RuntimeAuthFlow {
        try await request(method: "POST", path: "/auth/oauth", body: AuthProviderPayload(providerId: providerId))
    }

    public func startInteractiveApiKeyLogin(providerId: String) async throws -> RuntimeAuthFlow {
        try await request(method: "POST", path: "/auth/api-key/interactive", body: AuthProviderPayload(providerId: providerId))
    }

    public func authFlow(id: String) async throws -> RuntimeAuthFlow {
        try await request(method: "GET", path: "/auth/oauth/\(Self.pathSegment(id))")
    }

    public func respondAuthFlow(id: String, requestId: String, value: String) async throws -> RuntimeAuthFlow {
        try await request(method: "POST", path: "/auth/oauth/\(Self.pathSegment(id))/respond", body: AuthResponsePayload(requestId: requestId, value: value))
    }

    public func cancelAuthFlow(id: String) async throws -> RuntimeAuthFlow {
        try await request(method: "POST", path: "/auth/oauth/\(Self.pathSegment(id))/cancel", body: EmptyAuthPayload())
    }

    public func legacyAuthMigrationPreview() async throws -> RuntimeLegacyAuthMigrationPreview {
        try await request(method: "GET", path: "/auth/legacy-migration/preview")
    }

    public func migrateLegacyAuth(providerIds: [String], commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/auth/legacy-migration",
            body: LegacyAuthMigrationPayload(providerIds: providerIds, commandId: commandId, runtimeEpoch: expectedRuntimeEpoch)
        )
    }

    public func rollbackLegacyAuthMigration(id: String, commandId: String, expectedRuntimeEpoch: String) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/auth/legacy-migration/\(Self.pathSegment(id))/rollback",
            body: RuntimeCommandPayload(commandId: commandId, runtimeEpoch: expectedRuntimeEpoch)
        )
    }

}
