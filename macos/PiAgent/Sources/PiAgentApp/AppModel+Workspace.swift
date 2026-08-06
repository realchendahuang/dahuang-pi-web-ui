import Foundation
import PiAgentCore

@MainActor
extension AppModel {
    func refreshSelectedSession() {
        loadSelectedSession()
    }

    func refreshWorkspace(path: String? = nil) {
        guard canUseProjectRuntime,
              let client = runtimeClient as? any RuntimeWorkspaceClient
        else { return }
        let cwd = projectPath
        let requestedPath = path ?? workspacePath
        workspaceRequestGeneration += 1
        let generation = workspaceRequestGeneration
        isWorkspaceLoading = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            do {
                let tree = try await client.workspaceTree(cwd: cwd, path: requestedPath)
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceTree = tree
                self.workspacePath = tree.path
                self.workspaceFile = nil
                self.workspaceImagePreview = nil
                self.workspaceImagePreviewError = nil
                self.workspaceEditorText = ""
                self.isWorkspaceLoading = false
            } catch {
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceLoading = false
            }
        }
    }

    func openWorkspaceEntry(_ entry: RuntimeWorkspaceEntry) {
        if entry.isDirectory {
            refreshWorkspace(path: entry.path)
        } else {
            loadWorkspaceFile(path: entry.path)
        }
    }

    func openWorkspaceParent() {
        let components = workspacePath.split(separator: "/")
        refreshWorkspace(path: components.dropLast().joined(separator: "/"))
    }

    private func loadWorkspaceFile(path: String) {
        guard canUseProjectRuntime,
              let client = runtimeClient as? any RuntimeWorkspaceClient
        else { return }
        let cwd = projectPath
        workspaceRequestGeneration += 1
        let generation = workspaceRequestGeneration
        isWorkspaceLoading = true
        workspaceErrorMessage = nil
        workspaceImagePreview = nil
        workspaceImagePreviewError = nil
        Task { [weak self] in
            do {
                let file = try await client.workspaceFile(cwd: cwd, path: path)
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceFile = file
                self.workspaceEditorText = file.content
                if file.mediaType == "image" {
                    do {
                        let preview = try await client.workspaceImagePreview(cwd: cwd, path: file.path)
                        guard self.isCurrentWorkspaceRequest(generation, cwd: cwd) else { return }
                        self.workspaceImagePreview = preview
                    } catch {
                        guard self.isCurrentWorkspaceRequest(generation, cwd: cwd) else { return }
                        self.workspaceImagePreviewError = error.localizedDescription
                    }
                }
                guard self.isCurrentWorkspaceRequest(generation, cwd: cwd) else { return }
                self.isWorkspaceLoading = false
            } catch {
                guard let self,
                      self.isCurrentWorkspaceRequest(generation, cwd: cwd)
                else { return }
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceLoading = false
            }
        }
    }

    func saveWorkspaceFile() {
        guard let file = workspaceFile,
              !file.binary,
              !file.truncated,
              let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        let content = workspaceEditorText
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.writeWorkspaceFile(
                        cwd: cwd,
                        path: file.path,
                        content: content,
                        overwrite: true,
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
                try self.requireCompletedReceipt(receipt, kind: "write-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.written == true else {
                    throw RuntimeClientError.serverError(500, "Runtime 文件写入回执不完整。")
                }
                self.isWorkspaceMutationInFlight = false
                self.loadWorkspaceFile(path: file.path)
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func requestWorkspaceFileDeletion() {
        guard workspaceFile != nil, !isWorkspaceMutationInFlight else { return }
        workspaceFilePendingDeletion = workspaceFile
    }

    func cancelWorkspaceFileDeletion() {
        workspaceFilePendingDeletion = nil
    }

    func requestWorkspaceFileMove() {
        guard let file = workspaceFile, !isWorkspaceMutationInFlight else { return }
        workspaceFilePendingMove = file
        workspaceMoveDestination = file.path
    }

    func cancelWorkspaceFileMove() {
        workspaceFilePendingMove = nil
        workspaceMoveDestination = ""
    }

    func confirmWorkspaceFileMove() {
        guard let file = workspaceFilePendingMove,
              let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let destination = workspaceMoveDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            workspaceErrorMessage = "请输入目标路径。"
            return
        }
        guard destination != file.path else {
            cancelWorkspaceFileMove()
            return
        }
        let cwd = projectPath
        let commandId = UUID().uuidString
        workspaceFilePendingMove = nil
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.moveWorkspaceFile(
                        cwd: cwd,
                        fromPath: file.path,
                        toPath: destination,
                        overwrite: false,
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
                try self.requireCompletedReceipt(receipt, kind: "move-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.moved == true else {
                    throw RuntimeClientError.serverError(500, "Runtime 文件移动回执不完整。")
                }
                self.workspaceFile = nil
                self.workspaceEditorText = ""
                self.workspaceMoveDestination = ""
                self.isWorkspaceMutationInFlight = false
                self.refreshWorkspace()
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func startWorkspaceFileCreation() {
        guard !isWorkspaceMutationInFlight else { return }
        workspaceNewFilePath = workspacePath.isEmpty ? "" : "\(workspacePath)/"
        showWorkspaceNewFileSheet = true
    }

    func cancelWorkspaceFileCreation() {
        showWorkspaceNewFileSheet = false
        workspaceNewFilePath = ""
    }

    func createWorkspaceFile() {
        guard let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let path = workspaceNewFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            workspaceErrorMessage = "请输入文件路径。"
            return
        }
        let cwd = projectPath
        let commandId = UUID().uuidString
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.writeWorkspaceFile(
                        cwd: cwd,
                        path: path,
                        content: "",
                        overwrite: false,
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
                try self.requireCompletedReceipt(receipt, kind: "write-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.written == true else {
                    throw RuntimeClientError.serverError(500, "Runtime 文件创建回执不完整。")
                }
                self.showWorkspaceNewFileSheet = false
                self.workspaceNewFilePath = ""
                self.isWorkspaceMutationInFlight = false
                self.refreshWorkspace()
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

    func confirmWorkspaceFileDeletion() {
        guard let file = workspaceFilePendingDeletion,
              let client = runtimeClient as? any RuntimeWorkspaceClient,
              let expectedRuntimeEpoch = runtimeEpoch,
              !isWorkspaceMutationInFlight
        else { return }
        let cwd = projectPath
        let commandId = UUID().uuidString
        workspaceFilePendingDeletion = nil
        isWorkspaceMutationInFlight = true
        workspaceErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt: RuntimeCommandReceipt
                do {
                    receipt = try await client.deleteWorkspaceFile(
                        cwd: cwd,
                        path: file.path,
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
                try self.requireCompletedReceipt(receipt, kind: "delete-workspace-file", expectedRuntimeEpoch: expectedRuntimeEpoch)
                guard receipt.result?.deletedFile == true else {
                    throw RuntimeClientError.serverError(500, "Runtime 文件删除回执不完整。")
                }
                self.workspaceFile = nil
                self.workspaceEditorText = ""
                self.isWorkspaceMutationInFlight = false
                self.refreshWorkspace()
            } catch {
                self.workspaceErrorMessage = error.localizedDescription
                self.isWorkspaceMutationInFlight = false
            }
        }
    }

}
