import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct GitChangesView: View {
	@ObservedObject var model: AppModel

	var body: some View {
		if model.isGitLoading {
			ProgressView("正在加载更改…")
		} else if let status = model.gitStatus, status.isGitRepo {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Label(status.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
						.font(.caption.weight(.semibold))
					Spacer()
					Button("刷新") { model.refreshGit() }
						.buttonStyle(.borderless)
					Button("保存检查点") { model.createGitCheckpoint() }
						.buttonStyle(.borderless)
						.disabled(model.isGitMutationInFlight || model.selectedSessionID == nil)
				}
				if status.files.isEmpty {
					Text("工作区干净")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else {
					ForEach(status.files) { file in
						VStack(alignment: .leading, spacing: 4) {
							HStack(spacing: 6) {
								Button {
									model.selectGitPath(file.path)
								} label: {
									Text(file.path)
										.lineLimit(1)
										.frame(maxWidth: .infinity, alignment: .leading)
								}
								.buttonStyle(.plain)
								Text(gitFileStateLabel(file))
									.font(.caption.monospaced())
									.foregroundStyle(.secondary)
							}
							HStack(spacing: 8) {
								if file.index == "unmodified" || file.index == "untracked" {
									Button("暂存") { model.stageGitPath(file.path) }
								} else {
									Button("取消暂存") { model.unstageGitPath(file.path) }
								}
								if model.canDiscardGitFile(file) {
									Button("放弃…") { model.requestGitDiscard(file) }
										.foregroundStyle(.red)
								}
								Spacer()
							}
							.buttonStyle(.borderless)
							.disabled(model.isGitMutationInFlight)
						}
					}
				}
				if let selectedPath = model.gitSelectedPath {
					GitDiffView(path: selectedPath, unstaged: model.gitUnstagedDiff, staged: model.gitStagedDiff)
				}
				Button("提交已暂存的更改…") { model.requestGitCommit() }
					.disabled(model.isGitMutationInFlight || !status.files.contains(where: { $0.index != "unmodified" && $0.index != "untracked" }))
				Button("撤销最近一次提交…") { model.requestGitRevert() }
					.disabled(model.isGitMutationInFlight)
				if let preview = model.gitPushPreview, preview.canPush {
					Button("推送 \(preview.status.ahead ?? 0) 个提交…") { model.requestGitPush() }
						.disabled(model.isGitMutationInFlight)
				} else if let reason = model.gitPushPreview?.reason {
					Text(reason)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				GitCheckpointsView(model: model)
			}
		} else if model.gitStatus?.isGitRepo == false {
			Label("此项目不是 Git 仓库", systemImage: "exclamationmark.triangle")
				.foregroundStyle(.secondary)
		} else {
			Label("Runtime 连接后将加载 Git 更改", systemImage: "arrow.triangle.branch")
				.foregroundStyle(.secondary)
		}
	}
}

struct GitCheckpointsView: View {
	@ObservedObject var model: AppModel

	var body: some View {
		DisclosureGroup("对话检查点") {
			if model.isGitCheckpointLoading {
				ProgressView("正在加载检查点…")
			} else if model.gitCheckpoints.isEmpty {
				Text("保存检查点可记录此对话当前的 Git 状态以及大小受限的暂存/未暂存差异，供稍后查看。它不会创建 Git 引用，也不支持恢复。")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				ForEach(model.gitCheckpoints) { checkpoint in
					VStack(alignment: .leading, spacing: 4) {
						Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
							.font(.caption.weight(.semibold))
						Text("\(checkpoint.status.files.count) 个更改的文件 · \(checkpoint.status.branch ?? "Detached HEAD")")
							.font(.caption)
							.foregroundStyle(.secondary)
						CheckpointDiffView(label: "已暂存", diff: checkpoint.staged)
						CheckpointDiffView(label: "未暂存", diff: checkpoint.unstaged)
					}
					.padding(.vertical, 4)
				}
			}
		}
	}
}

struct CheckpointDiffView: View {
	let label: String
	let diff: RuntimeGitCheckpointDiff

	var body: some View {
		if !diff.diff.isEmpty {
			DisclosureGroup("\(label)差异\(diff.truncated ? "（已截断）" : "")") {
				ScrollView(.horizontal) {
					Text(diff.diff)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
				}
				.frame(maxHeight: 150)
			}
		}
	}
}

private func gitFileStateLabel(_ file: RuntimeGitFile) -> String {
	let index = file.index == "unmodified" ? "" : "I:\(file.index)"
	let worktree = file.workingTree == "unmodified" ? "" : "W:\(file.workingTree)"
	return [index, worktree].filter { !$0.isEmpty }.joined(separator: " ")
}

struct GitDiffView: View {
	let path: String
	let unstaged: RuntimeGitDiff?
	let staged: RuntimeGitDiff?

	var body: some View {
		let diffs = [staged, unstaged].compactMap { $0 }.filter { !$0.diff.isEmpty }
		if diffs.isEmpty {
			Text("\(path) 没有可显示的文本差异。")
				.font(.caption)
				.foregroundStyle(.secondary)
		} else {
			ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
				VStack(alignment: .leading, spacing: 4) {
					Text(diff.staged ? "已暂存的差异" : "未暂存的差异")
						.font(.caption.weight(.semibold))
					ScrollView(.horizontal) {
						Text(diff.diff)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
					}
					.frame(maxHeight: 180)
				}
			}
		}
	}
}
