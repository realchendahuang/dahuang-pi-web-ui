import Foundation
import PiAgentCore

extension UnixSocketRuntimeClient {
    public func workspaceTree(cwd: String, path: String?) async throws -> RuntimeWorkspaceTree {
        var values = [("cwd", cwd)]
        if let path, !path.isEmpty { values.append(("path", path)) }
        return try await request(method: "GET", path: "/workspace/tree", query: values)
    }

    public func workspaceFile(cwd: String, path: String) async throws -> RuntimeWorkspaceFile {
        try await request(
            method: "GET",
            path: "/workspace/file",
            query: [("cwd", cwd), ("path", path)]
        )
    }

    public func workspaceImagePreview(cwd: String, path: String) async throws -> RuntimeWorkspaceImagePreview {
        try await request(
            method: "GET",
            path: "/workspace/file/preview",
            query: [("cwd", cwd), ("path", path)]
        )
    }

    public func writeWorkspaceFile(
        cwd: String,
        path: String,
        content: String,
        overwrite: Bool,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "PUT",
            path: "/workspace/file",
            body: WorkspaceWritePayload(
                cwd: cwd,
                path: path,
                content: content,
                overwrite: overwrite,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func deleteWorkspaceFile(
        cwd: String,
        path: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "DELETE",
            path: "/workspace/file",
            body: WorkspaceDeletePayload(
                cwd: cwd,
                path: path,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func moveWorkspaceFile(
        cwd: String,
        fromPath: String,
        toPath: String,
        overwrite: Bool,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/workspace/file/move",
            body: WorkspaceMovePayload(
                cwd: cwd,
                fromPath: fromPath,
                toPath: toPath,
                overwrite: overwrite,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

}
