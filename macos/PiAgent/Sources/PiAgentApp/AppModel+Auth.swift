import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension AppModel {
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

}
