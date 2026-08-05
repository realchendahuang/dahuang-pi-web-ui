import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// Scroll-follow state held as an ObservableObject because the build
/// toolchain cannot expand the macro-based `@State` property wrapper.
private final class ScrollFollowState: ObservableObject {
    @Published var isNearBottom = true
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var follow = ScrollFollowState()

    private let bottomAnchorID = "transcript-bottom"

    /// Whether the selected thread is actively producing output right now.
    private var isStreaming: Bool {
        guard let session = model.selectedSession else { return false }
        return model.statusBySession[session.id]?.isStreaming == true
    }

    /// Shown only while the agent has started but produced nothing yet: the
    /// streaming assistant row carries its own "thinking" indicator and an
    /// active work group labels itself, so the standalone row covers the gap
    /// right after sending, when the user message is still the latest entry.
    private var showsWorkingRow: Bool {
        isStreaming && model.transcriptMessages.last?.role == "user"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }

            if model.selectedSession == nil {
                WelcomeView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Spacing.extraLarge) {
                            transcriptContent
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .onAppear { follow.isNearBottom = true }
                                .onDisappear { follow.isNearBottom = false }
                        }
                        .frame(maxWidth: 780, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.transcriptMessages.count) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: model.transcriptMessages.last?.text) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: model.selectedSessionID) {
                        follow.isNearBottom = true
                        scrollToBottom(proxy, animated: false)
                    }
                }
            }

            ComposerBar(model: model, focused: $composerFocused)
        }
        // Auto-dismiss transient errors after a grace period; manual close
        // still works. A new error restarts the countdown.
        .task(id: model.errorMessage) {
            guard model.errorMessage != nil else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            model.errorMessage = nil
        }
        .onChange(of: model.selectedSessionID) {
            composerFocused = true
        }
        .task {
            composerFocused = true
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if let session = model.selectedSession {
            if session.archived == true {
                Label("已归档 — 只读", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.transcriptMessages.isEmpty {
                ContentUnavailableView(
                    "新对话",
                    systemImage: "sparkles",
                    description: Text(session.firstMessage.isEmpty ? "发送一条消息开始。" : session.firstMessage)
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(groupedTranscript.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case let .message(message):
                        MessageRow(message: message)
                    case let .workGroup(messages):
                        WorkedGroupRow(
                            messages: messages,
                            isActive: isStreaming && messages.last?.id == model.transcriptMessages.last?.id
                        )
                    }
                }
                if showsWorkingRow {
                    HStack(spacing: Theme.Spacing.small) {
                        TypingIndicator()
                        Text("处理中…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Pi 正在处理")
                }
            }
        }
    }

    /// Consecutive tool/shell rows belonging to one stretch of agent work are
    /// collapsed into a single Codex-style "Worked N steps" disclosure row.
    /// The message model carries no turn or timing metadata, so grouping is
    /// purely by adjacency and rows show a step count rather than a duration.
    private enum TranscriptItem {
        case message(RuntimeMessage)
        case workGroup([RuntimeMessage])
    }

    private var groupedTranscript: [TranscriptItem] {
        var items: [TranscriptItem] = []
        var pendingWork: [RuntimeMessage] = []

        func flushWork() {
            if !pendingWork.isEmpty {
                items.append(.workGroup(pendingWork))
                pendingWork = []
            }
        }

        for message in model.transcriptMessages {
            if message.role == "tool" || message.role == "shell" {
                pendingWork.append(message)
            } else {
                flushWork()
                items.append(.message(message))
            }
        }
        flushWork()
        return items
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    /// Follows new content only while the user is already near the bottom;
    /// scrolling up to read history is never yanked back.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard follow.isNearBottom else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

/// Codex-style welcome shown when no thread is active: a quiet app glyph, an
/// emphasized project prompt, and suggestion cards that seed the composer and
/// start a new thread (the seeded text sends with the next Return).
private struct WelcomeView: View {
    @ObservedObject var model: AppModel

    struct Suggestion {
        let icon: String
        let color: SwiftUI.Color
        let title: String
        let prompt: String
    }

    private let suggestions: [Suggestion] = [
        Suggestion(
            icon: "magnifyingglass",
            color: .blue,
            title: "探索并理解代码",
            prompt: "探索这个代码库并解释它的工作原理。"
        ),
        Suggestion(
            icon: "hammer",
            color: .purple,
            title: "构建新功能或工具",
            prompt: "帮我构建一个新功能："
        ),
        Suggestion(
            icon: "arrow.triangle.2.circlepath",
            color: .green,
            title: "审查代码并提出修改建议",
            prompt: "审查当前的改动并提出改进建议。"
        ),
        Suggestion(
            icon: "ladybug",
            color: .orange,
            title: "修复问题和失败",
            prompt: "帮我查找并修复一个问题："
        ),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.extraLarge) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .subtleCard(cornerRadius: 14)
                .accessibilityHidden(true)

            (Text("要在 ") + Text(model.projectName).fontWeight(.bold) + Text(" 内开发什么？"))
                .font(.title)
                .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                    SuggestionCard(suggestion: suggestion) {
                        model.prompt = suggestion.prompt
                        model.startNewSession()
                    }
                    .disabled(model.isSending)
                }
            }
            .frame(maxWidth: 720)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

private struct SuggestionCard: View {
    let suggestion: WelcomeView.Suggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Image(systemName: suggestion.icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(suggestion.color)
                Text(suggestion.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 72, alignment: .top)
            .padding(Theme.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .subtleCard(cornerRadius: Theme.Radius.medium)
        .accessibilityLabel(suggestion.title)
        .accessibilityHint("以此提示词新建对话，并填入输入框")
    }
}
