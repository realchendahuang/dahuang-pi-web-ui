import AppKit
import PiAgentCore
import SwiftUI

/// Renders one transcript entry. The runtime projects four shapes into
/// `RuntimeMessage`: user turns, assistant turns, tool-call rows (role
/// "tool", text "name: summary" while running, replaced by output when done),
/// and shell output rows (role "shell").
struct MessageRow: View {
    let message: RuntimeMessage

    var body: some View {
        switch message.role {
        case "user":
            UserMessageRow(message: message)
        case "tool":
            ToolCallRow(message: message)
        case "shell":
            ShellOutputRow(message: message)
        default:
            AssistantMessageRow(message: message)
        }
    }
}

private struct UserMessageRow: View {
    let message: RuntimeMessage

    private var copyText: String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
                if !message.images.isEmpty {
                    MessageImages(images: message.images)
                }
                if !message.text.isEmpty {
                    MarkdownInlineText(text: message.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            .quaternary.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        )
                }
            }
            .frame(maxWidth: 560)
            .contextMenu {
                if let copyText {
                    Button("复制消息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("你")
    }
}

private struct AssistantMessageRow: View {
    let message: RuntimeMessage

    /// The live streaming message exists before its first delta arrives.
    private var isThinking: Bool {
        message.id == "streaming-assistant" && message.text.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label("Pi", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if isThinking {
                HStack(spacing: Theme.Spacing.small) {
                    TypingIndicator()
                    Text("思考中…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pi 正在思考")
            } else {
                if !message.text.isEmpty {
                    MarkdownText(text: message.text)
                }
                if !message.images.isEmpty {
                    MessageImages(images: message.images)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                Button("复制消息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}

/// Collapsible card for a tool call. Tool rows carry no structured name once
/// finished (the runtime replaces the "name: summary" text with raw output),
/// so the name is recovered from the "name: detail" prefix when it still
/// looks like one.
private struct ToolCallRow: View {
    let message: RuntimeMessage

    private var parsed: (name: String?, detail: String) {
        let text = message.text
        guard let separator = text.range(of: ": ") else { return (nil, text) }
        let head = text[text.startIndex..<separator.lowerBound]
        let looksLikeName = head.count <= 32
            && head.first?.isLetter == true
            && head.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        guard looksLikeName else { return (nil, text) }
        return (String(head), String(text[separator.upperBound...]))
    }

    private var iconName: String {
        guard let name = parsed.name?.lowercased() else { return "wrench.and.screwdriver" }
        if name.contains("bash") || name.contains("shell") || name.contains("terminal") || name.contains("command") {
            return "terminal"
        }
        if name.contains("edit") || name.contains("write") || name.contains("read") || name.contains("file") || name.contains("patch") {
            return "doc.text"
        }
        if name.contains("grep") || name.contains("glob") || name.contains("search") || name.contains("find") {
            return "magnifyingglass"
        }
        if name.contains("web") || name.contains("fetch") || name.contains("http") || name.contains("browse") {
            return "globe"
        }
        if name.contains("task") || name.contains("plan") || name.contains("todo") {
            return "checklist"
        }
        return "wrench.and.screwdriver"
    }

    var body: some View {
        // DisclosureGroup owns its expansion state; the build toolchain
        // cannot expand the macro-based @State wrapper for view-local state.
        DisclosureGroup {
            if !message.text.isEmpty {
                ScrollView {
                    Text(message.text)
                        .font(Theme.codeCaptionFont)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Spacing.small)
                }
                .frame(maxHeight: 220)
            }
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: iconName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(parsed.name ?? "工具")
                    .font(Theme.codeCaptionFont.weight(.semibold))
                    .foregroundStyle(.primary)
                if !parsed.detail.isEmpty {
                    Text(parsed.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .subtleCard(cornerRadius: Theme.Radius.small)
        .accessibilityLabel("工具调用：\(parsed.name ?? "工具")")
    }
}

private struct ShellOutputRow: View {
    let message: RuntimeMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(Theme.codeCaptionFont)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .subtleCard(cornerRadius: Theme.Radius.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("终端输出")
    }
}

/// Codex-style collapsed record of one stretch of agent work: a quiet
/// "Worked N steps" caption row ("Working…" while the group is still the
/// live one) that discloses the individual tool/shell rows on a subtle rail.
/// The message model has no turn timing, so the row shows a step count.
struct WorkedGroupRow: View {
    let messages: [RuntimeMessage]
    var isActive: Bool = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    MessageRow(message: message)
                }
            }
            .padding(.leading, 10)
            .padding(.top, Theme.Spacing.small)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1.5)
            }
        } label: {
            Text(isActive
                 ? "处理中 · \(messages.count) 步"
                 : "已处理 · \(messages.count) 步")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(messages.count) 个工作步骤")
        .accessibilityValue(isActive ? "进行中" : "已完成")
    }
}

struct MessageImages: View {
    let images: [RuntimeMessageImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    MessageImagePreview(image: image)
                }
            }
        }
        .frame(maxHeight: 260)
    }
}

struct MessageImagePreview: View {
    let image: RuntimeMessageImage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let data = image.imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                    }
            } else {
                Label("此 macOS 版本无法渲染该图片格式。", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(image.mimeType)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
