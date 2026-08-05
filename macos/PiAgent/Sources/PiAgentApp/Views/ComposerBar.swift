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
                    if !NSEvent.modifierFlags.contains(.shift) { model.sendPrompt() }
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

                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
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
