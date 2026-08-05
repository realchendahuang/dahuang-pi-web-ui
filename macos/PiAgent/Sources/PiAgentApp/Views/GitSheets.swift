import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct GitCommitSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("提交已暂存的更改")
                .font(.title2.weight(.semibold))
            Text("仅会提交 Runtime 已暂存的文件。Git 钩子保持启用。")
                .foregroundStyle(.secondary)
            TextEditor(text: $model.gitCommitMessage)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("取消") { model.cancelGitCommit() }
                Button("提交") { model.commitGit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct GitPushConfirmationSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let preview = model.gitPushPreview
        VStack(alignment: .leading, spacing: 16) {
            Text("推送提交")
                .font(.title2.weight(.semibold))
            if let preview {
                Text("将 \(preview.status.branch ?? "当前分支") 的 \(preview.status.ahead ?? 0) 个本地提交推送到 \(preview.status.upstream ?? "其配置的上游")。")
                    .foregroundStyle(.secondary)
            }
            Text("Pi Agent 只会将当前分支推送到其配置的跟踪上游。它不能强制推送、设置上游、选择其他远程或分支、推送标签，也不会改动你的工作区。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.cancelGitPush() }
                Button("推送") { model.pushGit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview?.canPush != true || model.isGitMutationInFlight)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct GitDiscardConfirmationSheet: View {
    @ObservedObject var model: AppModel
    let file: RuntimeGitFile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("放弃未暂存的更改")
                .font(.title2.weight(.semibold))
            Text("放弃 \(file.path) 中未暂存的更改？这会将该受跟踪文件恢复到当前 HEAD，且无法从 Pi Agent 撤销。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("未跟踪的文件、已暂存的更改、重命名的文件以及子模块指针更改在此不可用。子模块内的受跟踪文件可在该子模块自己的工作区中恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.cancelGitDiscard() }
                Button("放弃更改") { model.discardGitPath(file) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.isGitMutationInFlight)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct GitRevertConfirmationSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let preview = model.gitRevertPreview
        VStack(alignment: .leading, spacing: 16) {
            Text("撤销最近一次提交")
                .font(.title2.weight(.semibold))
            if let commit = preview?.commit {
                Text("创建一个新提交，用于还原 \(commit.hash.prefix(12))：\(commit.subject)")
                    .foregroundStyle(.secondary)
            }
            Text("此操作保留历史记录。Pi Agent 不会重置或修改提交、切换分支、强制推送、选择其他提交或更改上游。确认时工作区和暂存区必须保持干净。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.cancelGitRevert() }
                Button("创建还原提交") { model.revertGitHead() }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview?.canRevert != true || model.isGitMutationInFlight)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
