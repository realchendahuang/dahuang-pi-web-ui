import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct ComposerBar: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var focused: Bool

    private var isReadOnly: Bool {
        model.selectedSession == nil
            || model.selectedSession?.archived == true
            || !model.canUseProjectRuntime
    }

    private var canSend: Bool {
        !isReadOnly
            && !model.isSending
            && (!model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.promptImageAttachments.isEmpty)
    }

    private var gitBranch: String? {
        guard model.gitStatus?.isGitRepo == true,
              let branch = model.gitStatus?.branch,
              !branch.isEmpty
        else { return nil }
        return branch
    }

    private var isGoalPrompt: Bool {
        model.prompt.hasPrefix("/goal")
    }

    /// The agent is either mid-send or actively working; both states offer
    /// the stop button instead of the send button.
    private var isWorking: Bool {
        model.isSending || model.selectedSessionStatus?.isStreaming == true
    }

    // MARK: - Model / thinking-level capsule

    private var sessionStatus: RuntimeSessionStatus? {
        model.selectedSessionStatus
    }

    private var currentModelName: String? {
        sessionStatus?.model?.name ?? sessionStatus?.model?.id
    }

    private var currentLevelLabel: String? {
        sessionStatus?.thinkingLevel.map(Self.localizedThinkingLevel)
    }

    /// Hidden with no session, on archived threads, and when neither the
    /// status projection nor the catalog has anything to show.
    private var showsModelCapsule: Bool {
        guard let session = model.selectedSession, session.archived != true else { return false }
        return currentModelName != nil
            || sessionStatus?.thinkingLevel != nil
            || !model.availableModels.isEmpty
    }

    private var capsuleTitle: String {
        let parts = [currentModelName, currentLevelLabel].compactMap { $0 }
        return parts.isEmpty ? "模型" : parts.joined(separator: " ")
    }

    private func isCurrentModel(_ option: RuntimeSessionModel) -> Bool {
        guard let current = sessionStatus?.model else { return false }
        return option.provider == current.provider && option.id == current.id
    }

    static func localizedThinkingLevel(_ level: String) -> String {
        switch level.lowercased() {
        case "minimal": return "极低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "max", "maximum", "highest", "ultra": return "最高"
        default: return level
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            contextRow

            Divider()

            if !model.promptImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(model.promptImageAttachments) { attachment in
                            PromptImageAttachmentChip(attachment: attachment) {
                                model.removePromptImage(attachment)
                            }
                        }
                    }
                }
            }

            TextField(placeholder, text: $model.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($focused)
                .disabled(isReadOnly || model.isSending)
                .onSubmit {
                    // Shift+Return / Option+Return insert a newline; plain
                    // Return sends (macOS text-field convention).
                    let modifiers = NSEvent.modifierFlags
                    if !modifiers.contains(.shift), !modifiers.contains(.option) {
                        model.sendPrompt()
                    }
                }

            HStack(spacing: Theme.Spacing.medium) {
                Button {
                    model.choosePromptImages()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isReadOnly ? Color.secondary : Color.accentColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("附加图片…")
                .accessibilityLabel("附加图片")
                .disabled(
                    isReadOnly
                        || model.isSending
                        || model.promptImageAttachments.count >= nativePromptAttachmentLimit
                )

                // The pi-goal extension registers a real /goal session
                // command; this toggles the composer text in and out of it.
                Button {
                    if isGoalPrompt {
                        var remainder = String(model.prompt.dropFirst("/goal".count))
                        if remainder.hasPrefix(" ") { remainder.removeFirst() }
                        model.prompt = remainder
                    } else {
                        model.prompt = "/goal " + model.prompt
                    }
                    focused = true
                } label: {
                    Image(systemName: "target")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isGoalPrompt ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("目标模式（/goal）")
                .accessibilityLabel("目标模式")
                .accessibilityValue(isGoalPrompt ? "开" : "关")
                .disabled(isReadOnly || model.isSending)

                Spacer()

                if showsModelCapsule {
                    modelCapsule
                }

                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                } else if isWorking {
                    Button {
                        model.abortPrompt()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.red.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("停止当前任务")
                    .accessibilityLabel("停止当前任务")
                } else {
                    Button {
                        model.sendPrompt()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("发送（Return）")
                    .accessibilityLabel("发送消息")
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Codex-style context strip. Only chips backed by real state are shown:
    /// the project always exists, the runtime is always local, and the git
    /// branch appears only when the status projection knows one.
    private var contextRow: some View {
        HStack(spacing: Theme.Spacing.large) {
            Label(model.projectName, systemImage: "folder")
                .lineLimit(1)
            Label("本地", systemImage: "display")
            if let gitBranch {
                Label(gitBranch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Codex-style capsule: current model + thinking level, opening a menu
    /// with a model submenu and a thinking-level submenu. There is no
    /// reset-to-defaults endpoint on the socket, so no reset row is offered.
    private var modelCapsule: some View {
        Menu {
            if !model.availableModels.isEmpty {
                Menu("模型 \(currentModelName ?? "")") {
                    ForEach(Array(model.availableModels.enumerated()), id: \.offset) { _, option in
                        Button {
                            guard let provider = option.provider, let modelId = option.id else { return }
                            model.selectModel(provider: provider, modelId: modelId)
                        } label: {
                            HStack {
                                Text(option.name ?? option.id ?? "未知模型")
                                if isCurrentModel(option) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(option.provider == nil || option.id == nil)
                    }
                }
            }
            if !model.availableThinkingLevels.isEmpty {
                Menu("推理强度 \(currentLevelLabel ?? "")") {
                    ForEach(model.availableThinkingLevels, id: \.self) { level in
                        Button {
                            model.selectThinkingLevel(level)
                        } label: {
                            HStack {
                                Text(Self.localizedThinkingLevel(level))
                                if level == sessionStatus?.thinkingLevel {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(capsuleTitle)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("模型与推理强度")
        .accessibilityLabel("模型与推理强度")
        .accessibilityValue(capsuleTitle)
        // Model/thinking changes take effect on the next prompt, so the
        // capsule stays interactive while the agent is working.
        .disabled(isReadOnly)
    }

    private var placeholder: String {
        if model.selectedSession == nil { return "选择一个对话以继续" }
        if model.selectedSession?.archived == true { return "已归档的对话为只读" }
        return "发消息给 Pi…"
    }
}

struct PromptImageAttachmentChip: View {
    let attachment: RuntimePromptImageAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除 \(attachment.name)")
        }
        .font(.caption)
        .padding(6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}
