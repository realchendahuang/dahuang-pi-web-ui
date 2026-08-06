import Foundation
import PiAgentCore

extension UnixSocketRuntimeClient {
    public func gitStatus(cwd: String) async throws -> RuntimeGitStatus {
        try await request(method: "GET", path: "/git/status", query: [("cwd", cwd)])
    }

    public func gitDiff(cwd: String, path: String?, staged: Bool) async throws -> RuntimeGitDiff {
        var values = [("cwd", cwd), ("staged", staged ? "true" : "false")]
        if let path, !path.isEmpty { values.append(("path", path)) }
        return try await request(method: "GET", path: "/git/diff", query: values)
    }

    public func stageGitPaths(
        cwd: String,
        paths: [String],
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await gitPathsMutation(
            path: "/git/stage", cwd: cwd, paths: paths,
            commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch
        )
    }

    public func unstageGitPaths(
        cwd: String,
        paths: [String],
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await gitPathsMutation(
            path: "/git/unstage", cwd: cwd, paths: paths,
            commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch
        )
    }

    public func discardGitPaths(
        cwd: String,
        paths: [String],
        confirmed: Bool,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST", path: "/git/discard",
            body: GitDiscardPayload(
                cwd: cwd,
                paths: paths,
                confirmed: confirmed,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func commitGit(
        cwd: String,
        message: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST", path: "/git/commit",
            body: GitCommitPayload(cwd: cwd, message: message, commandId: commandId, runtimeEpoch: expectedRuntimeEpoch)
        )
    }

    public func gitPushPreview(cwd: String) async throws -> RuntimeGitPushPreview {
        try await request(method: "GET", path: "/git/push-preview", query: [("cwd", cwd)])
    }

    public func pushGit(
        cwd: String,
        confirmed: Bool,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST", path: "/git/push",
            body: GitPushPayload(
                cwd: cwd,
                confirmed: confirmed,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func gitRevertPreview(cwd: String) async throws -> RuntimeGitRevertPreview {
        try await request(method: "GET", path: "/git/revert-preview", query: [("cwd", cwd)])
    }

    public func revertGitHead(
        cwd: String,
        confirmed: Bool,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST", path: "/git/revert-head",
            body: GitRevertPayload(
                cwd: cwd,
                confirmed: confirmed,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func gitCheckpoints(cwd: String, sessionId: String) async throws -> [RuntimeGitCheckpoint] {
        try await request(
            method: "GET", path: "/git/checkpoints",
            query: [("cwd", cwd), ("sessionId", sessionId)]
        )
    }

    public func createGitCheckpoint(
        cwd: String,
        sessionId: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST", path: "/git/checkpoints",
            body: GitCheckpointPayload(
                cwd: cwd,
                sessionId: sessionId,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

}
