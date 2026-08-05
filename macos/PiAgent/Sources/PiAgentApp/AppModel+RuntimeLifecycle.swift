import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension AppModel {
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

    func scheduleOwnedRuntimeRecovery() {
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

    func isCurrentTerminalConnection(_ cwd: String) -> Bool {
        terminalCWD == cwd && cwd == projectPath
    }

    func isCurrentWorkspaceRequest(_ generation: Int, cwd: String) -> Bool {
        generation == workspaceRequestGeneration && cwd == projectPath
    }

    func isCurrentSessionStream(_ generation: Int, sessionID: String) -> Bool {
        generation == sessionStreamGeneration && selectedSessionID == sessionID
    }

}
