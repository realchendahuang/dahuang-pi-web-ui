import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// The left column of the main window, structured after the Codex desktop
/// sidebar: a header row on top, primary action rows, then the project
/// library where the selected project's threads nest directly underneath
/// its row. Custom row views replace `List(.sidebar)` so the surface stays
/// chrome-free: hover highlights and a rounded fill for the selection.
///
/// The data model only exposes sessions for the *selected* project, so
/// threads are nested under that project's row only; other projects stay
/// collapsed single rows, exactly like Codex.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SidebarActionRow(title: "新对话", systemImage: "square.and.pencil") {
                        model.startNewSession()
                    }
                    .help("新建对话 (⇧⌘N)")
                    .disabled(model.isSending || model.projectPath.isEmpty || !model.canUseProjectRuntime)
                    projectsSection
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            }
            SidebarFooter(model: model)
        }
        .navigationTitle("Pi Agent")
    }

    private var projectsSection: some View {
        Group {
            SidebarSectionHeader("项目")
                .padding(.top, Theme.Spacing.medium)
            ForEach(model.knownProjects) { project in
                let isActive = project.displayPath == model.projectPath
                SidebarProjectRow(project: project, isActive: isActive) {
                    model.openKnownProject(project)
                }
                .contextMenu {
                    Button("从项目库中移除", role: .destructive) {
                        model.removeKnownProject(project)
                    }
                }
                if isActive {
                    threadsUnderSelectedProject
                }
            }
            SidebarActionRow(title: "添加项目", systemImage: "plus") {
                model.openProject()
            }
        }
    }

    /// Active threads (plus the archived disclosure) of the currently
    /// selected project, indented so they read as nested under its row.
    private var threadsUnderSelectedProject: some View {
        Group {
            if model.isLoading && model.activeSessions.isEmpty {
                HStack(spacing: Theme.Spacing.small + 2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.small + 2)
                .padding(.vertical, Theme.Spacing.small)
            } else if model.activeSessions.isEmpty && model.archivedSessions.isEmpty {
                Text("暂无对话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.small + 2)
                    .padding(.vertical, Theme.Spacing.small - 2)
            } else {
                ForEach(model.activeSessions) { session in
                    SidebarThreadRow(
                        session: session,
                        status: model.statusBySession[session.id],
                        isSelected: model.selectedSessionID == session.id
                    ) {
                        model.selectSession(session.id)
                    }
                    .contextMenu {
                        Button("分叉对话…") {
                            model.requestFork(session)
                        }
                        .disabled(model.isSending)
                        Button("归档对话") {
                            model.archiveSession(session)
                        }
                        .disabled(model.isSending)
                        Divider()
                        Button("导入对话…") {
                            model.importSessionFromFile()
                        }
                        .disabled(model.isSending)
                    }
                }
                if !model.archivedSessions.isEmpty {
                    DisclosureGroup {
                        ForEach(model.archivedSessions) { session in
                            SidebarThreadRow(
                                session: session,
                                status: nil,
                                isSelected: model.selectedSessionID == session.id
                            ) {
                                model.selectSession(session.id)
                            }
                            .contextMenu {
                                Button("恢复对话") {
                                    model.restoreSession(session)
                                }
                                .disabled(model.isSending)
                                Divider()
                                Button("永久删除…", role: .destructive) {
                                    model.requestPermanentDelete(session)
                                }
                                .disabled(model.isSending)
                            }
                        }
                    } label: {
                        Text("已归档 (\(model.archivedSessions.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Theme.Spacing.small - 2)
                }
            }
        }
        .padding(.leading, Theme.Spacing.extraLarge)
    }
}

/// Top header: the workspace name with a chevron menu holding the two
/// window-level actions that exist in the real backend. No search/bell —
/// there is no backend for them, so they would be dead UI.
private struct SidebarHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Button("打开项目…") {
                model.openProject()
            }
            Divider()
            Button("重新连接 Runtime") {
                model.refreshRuntime()
            }
        } label: {
            HStack(spacing: 4) {
                Text("Pi Agent")
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.vertical, Theme.Spacing.small)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.small)
    }
}

/// Quiet section label above the project list, in the tone of macOS
/// sidebar group headers ("置顶"/"项目" in Codex).
private struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded row background shared by every sidebar row: invisible at rest,
/// a whisper of fill on hover, a slightly stronger fill when selected.
/// `Color.primary` keeps it semantic in light and dark mode.
private struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.08 : (isHovering ? 0.045 : 0)))
    }
}

/// One project in the library: folder icon plus name on a single line.
/// The selected project is marked only by the rounded highlight; its
/// threads render nested underneath (see `SidebarView`).
private struct SidebarProjectRow: View {
    let project: NativeProjectBookmark
    let isActive: Bool
    let open: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Spacing.small + 2) {
                Image(systemName: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(project.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.vertical, Theme.Spacing.small)
            .background {
                SidebarRowBackground(isSelected: isActive, isHovering: hover.isHovering)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .help(project.displayPath)
    }
}

/// Lightweight affordance row ("新对话", "添加项目") that reads as
/// part of the list rather than a heavy button.
private struct SidebarActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.small + 2) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.vertical, Theme.Spacing.small)
            .background {
                SidebarRowBackground(isSelected: false, isHovering: hover.isHovering)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
    }
}

/// One thread: a single line of title text and nothing else. The only
/// status affordance sits on the trailing edge — an accent dot while
/// streaming, a tiny spinner while compacting, an archivebox for archived
/// threads, and nothing at all when idle. The status word is still
/// exposed to VoiceOver (accessibilityValue) and the help tag, so state
/// never depends on sight or color alone.
private struct SidebarThreadRow: View {
    let session: RuntimeSession
    let status: RuntimeSessionStatus?
    let isSelected: Bool
    let select: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.small) {
                Text(session.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailingStatus
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.vertical, Theme.Spacing.small)
            .background {
                SidebarRowBackground(isSelected: isSelected, isHovering: hover.isHovering)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .help(statusText)
        .accessibilityLabel(session.displayTitle)
        .accessibilityValue(Text(statusText))
    }

    @ViewBuilder private var trailingStatus: some View {
        if session.archived == true {
            Image(systemName: "archivebox")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else if status?.isCompacting == true {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        } else if status?.isStreaming == true {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }

    private var statusText: String {
        if session.archived == true { return "已归档" }
        if status?.isStreaming == true { return "运行中" }
        if status?.isCompacting == true { return "压缩中" }
        return "就绪"
    }
}

/// Minimal bottom bar: a hairline, a quiet gear button opening the app's
/// Settings scene on the left (like Codex's bottom-left "⚙" row), and the
/// icon-only import button on the trailing edge.
private struct SidebarFooter: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @StateObject private var settingsHover = HoverState()
    @StateObject private var importHover = HoverState()

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gear")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background {
                            SidebarRowBackground(isSelected: false, isHovering: settingsHover.isHovering)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { settingsHover.isHovering = $0 }
                .help("设置 (⌘,)")
                .accessibilityLabel("设置")
                Spacer()
                Button {
                    model.importSessionFromFile()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.callout)
                        .frame(width: 26, height: 26)
                        .background {
                            SidebarRowBackground(isSelected: false, isHovering: importHover.isHovering)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { importHover.isHovering = $0 }
                .help("导入对话…")
                .disabled(model.isSending || !model.canUseProjectRuntime || model.selectedSession == nil || model.selectedSession?.archived == true)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
    }
}
