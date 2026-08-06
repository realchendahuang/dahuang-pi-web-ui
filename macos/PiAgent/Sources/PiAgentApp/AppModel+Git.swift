import Foundation
import PiAgentCore

@MainActor
extension AppModel {
    func refreshGit() {
        guard let client = runtimeClient as? any RuntimeGitClient else {
            gitStatus = nil
            gitPushPreview = nil
            return
        }
        let cwd = projectPath
        isGitLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await client.gitStatus(cwd: cwd)
                guard self.projectPath == cwd else { return }
                self.gitStatus = status
                self.refreshGitPushPreview()
                self.isGitLoading = false
                if let selected = self.gitSelectedPath,
                   !status.files.contains(where: { $0.path == selected }) {
                    self.gitSelectedPath = nil
                    self.gitUnstagedDiff = nil
                    self.gitStagedDiff = nil
                }
            } catch {
                guard self.projectPath == cwd else { return }
                self.isGitLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func refreshGitPushPreview() {
        guard let client = runtimeClient as? any RuntimeGitClient else {
            gitPushPreview = nil
            return
        }
        let cwd = projectPath
        Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await client.gitPushPreview(cwd: cwd)
                guard self.projectPath == cwd else { return }
                self.gitPushPreview = preview
            } catch {
                guard self.projectPath == cwd else { return }
                self.gitPushPreview = nil
            }
        }
    }

    func refreshGitCheckpoints() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let session = selectedSession
        else { gitCheckpoints = []; return }
        let cwd = session.cwd
        let sessionId = session.id
        isGitCheckpointLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let checkpoints = try await client.gitCheckpoints(cwd: cwd, sessionId: sessionId)
                guard self.selectedSessionID == sessionId, self.projectPath == cwd else { return }
                self.gitCheckpoints = checkpoints
                self.isGitCheckpointLoading = false
            } catch {
                guard self.selectedSessionID == sessionId, self.projectPath == cwd else { return }
                self.isGitCheckpointLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func createGitCheckpoint() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let session = selectedSession,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isGitMutationInFlight
        else { errorMessage = "请先选择对话并重新连接 Runtime，再创建检查点。"; return }
        let commandId = UUID().uuidString
        let cwd = session.cwd
        let sessionId = session.id
        isGitMutationInFlight = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.createGitCheckpoint(cwd: cwd, sessionId: sessionId, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
                }
                try self.requireCompletedReceipt(receipt, kind: "create-git-checkpoint", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.checkpointed == true, let checkpoint = receipt.result?.checkpoint else {
                    throw RuntimeClientError.serverError(500, "Runtime 检查点回执缺少审查快照。")
                }
                guard self.selectedSessionID == sessionId, self.projectPath == cwd else { return }
                self.gitCheckpoints = [checkpoint] + self.gitCheckpoints.filter { $0.id != checkpoint.id }
                self.isGitMutationInFlight = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGitMutationInFlight = false
            }
        }
    }

    func selectGitPath(_ path: String) {
        guard let client = runtimeClient as? any RuntimeGitClient else { return }
        gitSelectedPath = path
        gitUnstagedDiff = nil
        gitStagedDiff = nil
        let cwd = projectPath
        Task { [weak self] in
            guard let self else { return }
            do {
                async let unstaged = client.gitDiff(cwd: cwd, path: path, staged: false)
                async let staged = client.gitDiff(cwd: cwd, path: path, staged: true)
                let (unstagedResult, stagedResult) = try await (unstaged, staged)
                guard self.projectPath == cwd, self.gitSelectedPath == path else { return }
                self.gitUnstagedDiff = unstagedResult
                self.gitStagedDiff = stagedResult
            } catch {
                guard self.projectPath == cwd, self.gitSelectedPath == path else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stageGitPath(_ path: String) { performGitPathMutation(path, kind: "stage-git-paths", accepted: { $0.staged == true }) { client, cwd, paths, commandId, epoch in
        try await client.stageGitPaths(cwd: cwd, paths: paths, commandId: commandId, expectedRuntimeEpoch: epoch)
    } }

    func unstageGitPath(_ path: String) { performGitPathMutation(path, kind: "unstage-git-paths", accepted: { $0.unstaged == true }) { client, cwd, paths, commandId, epoch in
        try await client.unstageGitPaths(cwd: cwd, paths: paths, commandId: commandId, expectedRuntimeEpoch: epoch)
    } }

    func canDiscardGitFile(_ file: RuntimeGitFile) -> Bool {
        guard let status = gitStatus else { return false }
        // A direct submodule pointer has recovery semantics different from a
        // contained file. The Runtime may safely restore the latter in its own
        // worktree, but never changes a submodule HEAD through this action.
        return file.index == "unmodified" &&
            file.workingTree != "unmodified" &&
            file.workingTree != "untracked" &&
            file.oldPath == nil &&
            !status.submodules.contains(file.path)
    }

    func requestGitDiscard(_ file: RuntimeGitFile) {
        guard canDiscardGitFile(file), !isGitMutationInFlight else { return }
        gitPathPendingDiscard = file
    }

    func cancelGitDiscard() { gitPathPendingDiscard = nil }

    func discardGitPath(_ file: RuntimeGitFile) {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              canDiscardGitFile(file),
              !isGitMutationInFlight
        else { errorMessage = "请先重新连接 Runtime，再放弃 Git 更改。"; return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isGitMutationInFlight = true
        gitPathPendingDiscard = nil
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.discardGitPaths(cwd: cwd, paths: [file.path], confirmed: true, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
                }
                try self.requireCompletedReceipt(receipt, kind: "discard-git-paths", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.discarded == true, let status = receipt.result?.status else {
                    throw RuntimeClientError.serverError(500, "Runtime 放弃更改回执缺少 Git 状态投影。")
                }
                guard self.projectPath == cwd else { return }
                self.gitStatus = status
                self.gitSelectedPath = nil
                self.gitUnstagedDiff = nil
                self.gitStagedDiff = nil
                self.isGitMutationInFlight = false
                self.refreshGitPushPreview()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGitMutationInFlight = false
            }
        }
    }

    func requestGitCommit() {
        guard gitStatus?.isGitRepo == true, !isGitMutationInFlight else { return }
        showGitCommitSheet = true
    }

    func requestGitPush() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              !isGitMutationInFlight
        else { errorMessage = "请先重新连接 Runtime，再推送更改。"; return }
        let cwd = projectPath
        Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await client.gitPushPreview(cwd: cwd)
                guard self.projectPath == cwd else { return }
                self.gitPushPreview = preview
                guard preview.canPush else {
                    self.errorMessage = preview.reason ?? "当前分支无法推送。"
                    return
                }
                self.showGitPushConfirmation = true
            } catch {
                guard self.projectPath == cwd else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelGitPush() {
        showGitPushConfirmation = false
    }

    func requestGitRevert() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              !isGitMutationInFlight
        else { errorMessage = "请先重新连接 Runtime，再撤销 Git 提交。"; return }
        let cwd = projectPath
        Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await client.gitRevertPreview(cwd: cwd)
                guard self.projectPath == cwd else { return }
                self.gitRevertPreview = preview
                guard preview.canRevert else {
                    self.errorMessage = preview.reason ?? "最新提交无法撤销。"
                    return
                }
                self.showGitRevertConfirmation = true
            } catch {
                guard self.projectPath == cwd else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelGitRevert() { showGitRevertConfirmation = false }

    func revertGitHead() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              gitRevertPreview?.canRevert == true,
              !isGitMutationInFlight
        else { errorMessage = "请先刷新最新提交的撤销预览，再继续。"; return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isGitMutationInFlight = true
        showGitRevertConfirmation = false
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.revertGitHead(cwd: cwd, confirmed: true, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch)
                } catch {
                    receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error)
                }
                try self.requireCompletedReceipt(receipt, kind: "revert-git-head", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.reverted == true, let status = receipt.result?.status else {
                    throw RuntimeClientError.serverError(500, "Runtime 撤销回执缺少 Git 状态投影。")
                }
                guard self.projectPath == cwd else { return }
                self.gitStatus = status
                self.gitSelectedPath = nil
                self.gitUnstagedDiff = nil
                self.gitStagedDiff = nil
                self.isGitMutationInFlight = false
                self.refreshGitPushPreview()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGitMutationInFlight = false
            }
        }
    }

    func cancelGitCommit() {
        showGitCommitSheet = false
        gitCommitMessage = ""
    }

    func commitGit() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let expectedRuntimeEpoch = runtimeEpoch
        else { errorMessage = "请先重新连接 Runtime，再提交更改。"; return }
        let message = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { errorMessage = "请输入提交信息。"; return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isGitMutationInFlight = true
        showGitCommitSheet = false
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do { receipt = try await client.commitGit(cwd: cwd, message: message, commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch) }
                catch { receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error) }
                try self.requireCompletedReceipt(receipt, kind: "commit-git", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.committed == true, let status = receipt.result?.status else {
                    throw RuntimeClientError.serverError(500, "Runtime 提交回执缺少 Git 状态投影。")
                }
                self.gitStatus = status
                self.gitCommitMessage = ""
                self.isGitMutationInFlight = false
                self.selectGitPath(self.gitSelectedPath ?? "")
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGitMutationInFlight = false
            }
        }
    }

    func pushGit() {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              let preview = gitPushPreview,
              preview.canPush,
              !isGitMutationInFlight
        else { errorMessage = "请先刷新 Git 推送预览，再推送更改。"; return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isGitMutationInFlight = true
        showGitPushConfirmation = false
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.pushGit(
                        cwd: cwd,
                        confirmed: true,
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
                try self.requireCompletedReceipt(receipt, kind: "push-git", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.pushed == true, let status = receipt.result?.status else {
                    throw RuntimeClientError.serverError(500, "Runtime 推送回执缺少 Git 状态投影。")
                }
                guard self.projectPath == cwd else { return }
                self.gitStatus = status
                self.isGitMutationInFlight = false
                self.refreshGitPushPreview()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGitMutationInFlight = false
                self.refreshGitPushPreview()
            }
        }
    }

    private func performGitPathMutation(
        _ path: String,
        kind: String,
        accepted: @escaping @Sendable (RuntimeCommandReceipt.Result) -> Bool,
        execute: @escaping @Sendable (any RuntimeGitClient, String, [String], String, String) async throws -> RuntimeCommandReceipt
    ) {
        guard let client = runtimeClient as? any RuntimeGitClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isGitMutationInFlight
        else { errorMessage = "请先重新连接 Runtime，再更改 Git 状态。"; return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isGitMutationInFlight = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do { receipt = try await execute(client, cwd, [path], commandId, expectedRuntimeEpoch) }
                catch { receipt = try await self.commandReceiptAfterUnknownTransport(client: self.runtimeClient, commandId: commandId, originalError: error) }
                try self.requireCompletedReceipt(receipt, kind: kind, expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard let result = receipt.result, accepted(result) else {
                    throw RuntimeClientError.serverError(500, "Runtime Git 回执缺少完成结果。")
                }
                guard let status = receipt.result?.status else {
                    throw RuntimeClientError.serverError(500, "Runtime Git 回执缺少 Git 状态投影。")
                }
                self.gitStatus = status
                self.isGitMutationInFlight = false
                self.selectGitPath(path)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGitMutationInFlight = false
            }
        }
    }

}
