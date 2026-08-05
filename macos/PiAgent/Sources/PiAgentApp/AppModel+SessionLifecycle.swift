import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension AppModel {
    func selectSession(_ sessionID: String?) {
        stopSessionEventStream()
        selectedSessionID = sessionID
        transcriptMessages = []
        extensionInteractions = []
        extensionInteractionText = ""
        streamingMessage = nil
        lastSessionSequence = 0
        errorMessage = nil
        availableModels = []
        availableThinkingLevels = []
        guard sessionID != nil else { return }
        loadSelectedSession()
        refreshModelOptions()
        refreshGitCheckpoints()
        if selectedSession?.archived != true {
            startSessionEventStream()
        }
    }

    /// A notification may select only an already-authorized project already
    /// represented by this window. Its userInfo never grants a new filesystem
    /// path or opens an arbitrary session.
    @discardableResult
    func selectNotificationSession(sessionID: String, cwd: String) -> Bool {
        guard cwd == projectPath,
              sessions.contains(where: { $0.id == sessionID && $0.cwd == cwd })
        else { return false }
        selectSession(sessionID)
        return true
    }

    func startNewSession() {
        let client = runtimeClient
        let cwd = projectPath
        guard canUseProjectRuntime else {
            errorMessage = "请先授权所选项目，再创建对话。"
            return
        }
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再创建对话。"
            return
        }
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.startSession(
                        cwd: cwd,
                        runtimeId: nil,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "start-session",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.created == true,
                      let createdSessionID = receipt.result?.sessionId
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 会话回执缺少新建会话结果。"
                    )
                }
                let createdCWD = receipt.result?.cwd ?? cwd
                let sessions = try await client.listSessions(cwd: createdCWD)
                guard let session = sessions.first(where: { $0.id == createdSessionID }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 已创建对话，但会话投影中未找到它。请重新连接以刷新。"
                    )
                }
                self.replaceSessions(sessions)
                self.isSending = false
                self.selectSession(session.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func sendPrompt() {
        guard let session = selectedSession else {
            errorMessage = "请先选择一个对话，再发送消息。"
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = promptImageAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isSending else { return }
        guard canUseProjectRuntime else {
            errorMessage = "请先授权所选项目，再发送消息。"
            return
        }
        guard session.archived != true else {
            errorMessage = "请先恢复此已归档对话，再发送消息。"
            return
        }

        let client = runtimeClient
        let cwd = projectPath
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再发送消息。"
            return
        }
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.prompt(
                        sessionId: session.id,
                        cwd: cwd,
                        runtimeId: session.runtimeId,
                        text: text,
                        attachments: attachments,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "prompt",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.accepted == true,
                      receipt.result?.sessionId == session.id
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 消息回执缺少已接受的会话结果。"
                    )
                }
                self.prompt = ""
                self.promptImageAttachments = []
                self.isSending = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func choosePromptImages() {
        guard !isSending else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = nativePromptImageContentTypes
        panel.prompt = "添加图片"
        panel.message = "Pi Agent 会将支持的图片内联发送到所选对话。每张图片不得超过 4.5 MB。"
        guard panel.runModal() == .OK else { return }

        var accepted: [RuntimePromptImageAttachment] = []
        var rejected: [String] = []
        for url in panel.urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count > 0 else { throw RuntimeClientError.serverError(400, "图片为空。") }
                guard data.count <= nativeInlineImageLimit else {
                    throw RuntimeClientError.serverError(400, "图片超过 Pi 的 4.5 MB 内联上限。")
                }
                guard let mimeType = nativeImageMimeType(for: url) else {
                    throw RuntimeClientError.serverError(400, "仅支持 PNG、JPEG、GIF 和 WebP 图片。")
                }
                accepted.append(RuntimePromptImageAttachment(
                    name: url.lastPathComponent,
                    mimeType: mimeType,
                    data: data.base64EncodedString(),
                    size: data.count
                ))
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        let capacity = max(0, nativePromptAttachmentLimit - promptImageAttachments.count)
        promptImageAttachments.append(contentsOf: accepted.prefix(capacity))
        if accepted.count > capacity { rejected.append("超过 \(nativePromptAttachmentLimit) 张图片") }
        if !rejected.isEmpty {
            errorMessage = "无法添加：\(rejected.joined(separator: "，"))。"
        }
    }

    func removePromptImage(_ attachment: RuntimePromptImageAttachment) {
        promptImageAttachments.removeAll { $0.id == attachment.id }
    }

    func archiveSession(_ session: RuntimeSession) {
        performSessionMutation(
            session,
            kind: "archive-session",
            accepted: { $0.archived == true },
            execute: { client, commandId, epoch in
                try await client.archiveSession(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
            }
        )
    }

    func restoreSession(_ session: RuntimeSession) {
        performSessionMutation(
            session,
            kind: "restore-session",
            accepted: { $0.restored == true },
            execute: { client, commandId, epoch in
                try await client.restoreSession(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
            }
        )
    }

    func requestPermanentDelete(_ session: RuntimeSession) {
        guard session.archived == true, !isSending else { return }
        sessionPendingPermanentDeletion = session
    }

    func cancelPermanentDelete() {
        sessionPendingPermanentDeletion = nil
    }

    func requestFork(_ session: RuntimeSession) {
        guard session.archived != true, !isSending else { return }
        guard runtimeEpoch != nil else {
            errorMessage = "请先重新连接 Runtime，再分叉对话。"
            return
        }
        let client = runtimeClient
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                // Candidate selection is read-only. The selected entry is
                // still revalidated by the Runtime when the receipt-safe fork
                // mutation runs, so a stale sheet cannot fork an arbitrary entry.
                let candidates = try await client.forkCandidates(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId
                )
                guard !candidates.isEmpty else {
                    throw RuntimeClientError.serverError(
                        400,
                        "此对话没有可用于分叉的用户消息。"
                    )
                }
                self.forkCandidates = candidates
                self.sessionPendingFork = session
                self.isSending = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func cancelFork() {
        sessionPendingFork = nil
        forkCandidates = []
    }

    func forkSession(_ session: RuntimeSession, from candidate: RuntimeForkCandidate) {
        guard !isSending else { return }
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再分叉对话。"
            return
        }
        let client = runtimeClient
        let commandId = UUID().uuidString
        sessionPendingFork = nil
        forkCandidates = []
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.forkSession(
                        sessionId: session.id,
                        cwd: session.cwd,
                        runtimeId: session.runtimeId,
                        entryId: candidate.entryId,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "fork-session",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.forked == true,
                      let forked = receipt.result?.session
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 分叉回执缺少分叉会话结果。"
                    )
                }
                let refreshed = try await client.listSessions(cwd: forked.cwd)
                guard refreshed.contains(where: { $0.id == forked.id }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 已分叉对话，但会话投影中未找到它。请重新连接以刷新。"
                    )
                }
                self.replaceSessions(refreshed)
                self.isSending = false
                self.selectSession(forked.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func importSessionFromFile() {
        guard let session = selectedSession else {
            errorMessage = "请先选择一个未归档的对话，再导入会话。"
            return
        }
        guard session.archived != true else {
            errorMessage = "请先恢复此已归档对话，再导入会话。"
            return
        }
        guard !isSending else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "导入对话"
        panel.message = "选择一个 Pi 会话 JSONL 文件。Pi Agent 会将其副本导入此项目的会话存储。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performSessionImport(session, inputPath: url.path)
    }

    private func performSessionImport(_ session: RuntimeSession, inputPath: String) {
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再导入会话。"
            return
        }
        let client = runtimeClient
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.importSession(
                        sessionId: session.id,
                        cwd: session.cwd,
                        runtimeId: session.runtimeId,
                        inputPath: inputPath,
                        commandId: commandId,
                        expectedRuntimeEpoch: expectedRuntimeEpoch
                    )
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: "import-session",
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.imported == true,
                      let imported = receipt.result?.session
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 导入回执缺少导入会话结果。"
                    )
                }
                let refreshed = try await client.listSessions(cwd: imported.cwd)
                guard refreshed.contains(where: { $0.id == imported.id }) else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 已导入对话，但会话投影中未找到它。请重新连接以刷新。"
                    )
                }
                self.replaceSessions(refreshed)
                self.isSending = false
                self.selectSession(imported.id)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func confirmPermanentDelete() {
        guard let session = sessionPendingPermanentDeletion else { return }
        sessionPendingPermanentDeletion = nil
        performSessionMutation(
            session,
            kind: "delete-archived-session",
            accepted: { $0.deleted == true },
            selectMutatedSession: false,
            execute: { client, commandId, epoch in
                try await client.deleteArchivedSession(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    commandId: commandId,
                    expectedRuntimeEpoch: epoch
                )
            }
        )
    }

    private func performSessionMutation(
        _ session: RuntimeSession,
        kind: String,
        accepted: @escaping @Sendable (RuntimeCommandReceipt.Result) -> Bool,
        selectMutatedSession: Bool = true,
        execute: @escaping @Sendable (any RuntimeClient, String, String) async throws -> RuntimeCommandReceipt
    ) {
        guard !isSending else { return }
        guard let expectedRuntimeEpoch = runtimeEpoch else {
            errorMessage = "请先重新连接 Runtime，再修改对话。"
            return
        }
        let client = runtimeClient
        let commandId = UUID().uuidString
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await execute(client, commandId, expectedRuntimeEpoch)
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(
                        client: client,
                        commandId: commandId,
                        originalError: error
                    )
                }
                try self.requireCompletedReceipt(
                    receipt,
                    kind: kind,
                    expectedRuntimeEpoch: expectedRuntimeEpoch
                )
                guard receipt.result?.sessionId == session.id,
                      let result = receipt.result,
                      accepted(result)
                else {
                    throw RuntimeClientError.serverError(
                        500,
                        "Runtime 对话变更回执缺少完成结果。"
                    )
                }
                let refreshed = try await client.listSessions(cwd: session.cwd)
                self.replaceSessions(refreshed)
                self.isSending = false
                if selectMutatedSession, self.sessions.contains(where: { $0.id == session.id }) {
                    self.selectSession(session.id)
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func currentRuntimeEpoch(using client: any RuntimeClient) async throws -> String {
        guard let helloClient = client as? any RuntimeHelloClient else {
            throw RuntimeClientError.incompatibleRuntime(
                "已连接的 Runtime 不提供原生身份握手。"
            )
        }
        let hello = try await helloClient.hello()
        try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
        runtimeEpoch = hello.runtimeEpoch
        return hello.runtimeEpoch
    }

    func commandReceiptAfterUnknownTransport(
        client: any RuntimeClient,
        commandId: String,
        originalError: Error
    ) async throws -> RuntimeCommandReceipt {
        guard isUnknownCommandTransportError(originalError) else { throw originalError }
        return try await client.commandReceipt(commandId: commandId)
    }

    private func isUnknownCommandTransportError(_ error: Error) -> Bool {
        switch error {
        case RuntimeClientError.connectionFailed, RuntimeClientError.invalidHTTPResponse:
            return true
        default:
            return false
        }
    }

    func requireCompletedReceipt(
        _ receipt: RuntimeCommandReceipt,
        kind: String,
        expectedRuntimeEpoch: String
    ) throws {
        guard receipt.kind == kind else {
            throw RuntimeClientError.serverError(500, "Runtime 返回了错误命令类型的回执。")
        }
        guard receipt.runtimeEpoch == expectedRuntimeEpoch || receipt.recoveredAfterRuntimeRestart == true else {
            throw RuntimeClientError.incompatibleRuntime(
                "命令执行期间 Runtime 已重启。请重新连接后重试。"
            )
        }
        guard receipt.status == "completed" else {
            throw RuntimeClientError.serverError(
                500,
                receipt.error ?? "Runtime 命令失败。"
            )
        }
    }

}
