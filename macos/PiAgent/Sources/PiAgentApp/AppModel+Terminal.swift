import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension AppModel {
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

}
