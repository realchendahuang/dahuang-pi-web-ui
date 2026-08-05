import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// Filter text for the workspace tree, held as an ObservableObject because
/// the build toolchain cannot expand the macro-based `@State` wrapper.
final class WorkspaceFilesFilter: ObservableObject {
    @Published var text = ""
}

/// File panel: a filterable workspace tree, or the open file with a back
/// button. Tree/file state and all mutations stay in `AppModel`.
struct WorkspaceFilesView: View {
    @ObservedObject var model: AppModel
    @StateObject private var filter = WorkspaceFilesFilter()

    var body: some View {
        VStack(spacing: 0) {
            if let file = model.workspaceFile {
                fileContent(file)
            } else {
                treeContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if model.workspaceTree == nil { model.refreshWorkspace() }
        }
    }

    // MARK: - Tree

    private var treeContent: some View {
        VStack(spacing: 0) {
            treeHeader
            Divider()
            treeBody
        }
    }

    private var treeHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Label(
                    model.workspacePath.isEmpty ? "项目文件" : model.workspacePath,
                    systemImage: "folder"
                )
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer()
                if !model.workspacePath.isEmpty {
                    headerButton(systemImage: "arrow.up", help: "前往上级文件夹") {
                        model.openWorkspaceParent()
                    }
                }
                headerButton(systemImage: "arrow.clockwise", help: "刷新文件") {
                    model.refreshWorkspace()
                }
                headerButton(systemImage: "plus", help: "新建文件…") {
                    model.startWorkspaceFileCreation()
                }
                .disabled(model.isWorkspaceMutationInFlight || !model.canUseProjectRuntime)
            }

            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("筛选文件…", text: $filter.text)
                    .textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 4)
            .background(
                .quaternary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            )
        }
        .padding(Theme.Spacing.medium)
    }

    private func headerButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var filteredEntries: [RuntimeWorkspaceEntry] {
        guard let tree = model.workspaceTree else { return [] }
        let query = filter.text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tree.entries }
        return tree.entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var treeBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.isWorkspaceLoading {
                    ProgressView("正在加载文件…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.extraLarge)
                } else if model.workspaceTree != nil {
                    let entries = filteredEntries
                    if entries.isEmpty {
                        emptyState(
                            systemImage: "doc.questionmark",
                            message: filter.text.isEmpty ? "此文件夹为空" : "没有匹配“\(filter.text)”的文件"
                        )
                    } else {
                        ForEach(entries) { entry in
                            treeRow(entry)
                        }
                    }
                    if model.workspaceTree?.truncated == true {
                        Text("仅显示前 1,000 个条目。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.medium)
                            .padding(.top, Theme.Spacing.small)
                    }
                } else {
                    emptyState(
                        systemImage: "folder",
                        message: "Runtime 连接后将加载文件。"
                    )
                }

                if let error = model.workspaceErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(Theme.Spacing.medium)
                }
            }
        }
    }

    private func treeRow(_ entry: RuntimeWorkspaceEntry) -> some View {
        Button {
            model.openWorkspaceEntry(entry)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                let icon = iconDescriptor(for: entry)
                Image(systemName: icon.name)
                    .foregroundStyle(icon.tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(entry.path)
    }

    private func emptyState(systemImage: String, message: String) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.extraLarge)
    }

    // MARK: - Open file

    private func fileContent(_ file: RuntimeWorkspaceFile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    model.refreshWorkspace()
                } label: {
                    Label("文件", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help("返回文件目录树")
                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("移动/重命名…") { model.requestWorkspaceFileMove() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("删除…", role: .destructive) {
                    model.requestWorkspaceFileDeletion()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .disabled(model.isWorkspaceMutationInFlight)
            .padding(Theme.Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if let error = model.workspaceErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    fileBody(file)
                }
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func fileBody(_ file: RuntimeWorkspaceFile) -> some View {
        if file.mediaType == "image" {
            WorkspaceImagePreviewView(
                file: file,
                preview: model.workspaceImagePreview,
                errorMessage: model.workspaceImagePreviewError
            )
        } else if file.binary {
            Label("暂不支持二进制或图片预览。", systemImage: "doc.richtext")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if file.truncated {
            ScrollView([.horizontal, .vertical]) {
                Text(file.content)
                    .font(Theme.codeCaptionFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            Text("预览已在 512 KB 处截断。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            TextEditor(text: $model.workspaceEditorText)
                .font(Theme.codeCaptionFont)
                .frame(minHeight: 240, maxHeight: 360)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(.quaternary))
            HStack {
                Button("存储") { model.saveWorkspaceFile() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .disabled(model.isWorkspaceMutationInFlight)
        }
    }

    // MARK: - Icons

    private struct FileIcon {
        let name: String
        let tint: SwiftUI.Color
    }

    private func iconDescriptor(for entry: RuntimeWorkspaceEntry) -> FileIcon {
        if entry.isDirectory { return FileIcon(name: "folder", tint: .blue) }
        if entry.type == "symlink" { return FileIcon(name: "link", tint: .secondary) }
        let name = entry.name.lowercased()
        if name == ".gitignore" || name == ".gitattributes" || name == ".gitmodules" {
            return FileIcon(name: "arrow.triangle.branch", tint: .orange)
        }
        switch (name as NSString).pathExtension {
        case "swift":
            return FileIcon(name: "swift", tint: .orange)
        case "ts", "tsx", "js", "jsx", "mjs", "cjs":
            return FileIcon(name: "doc.text", tint: .blue)
        case "json":
            return FileIcon(name: "curlybraces.square", tint: .green)
        case "md", "markdown":
            return FileIcon(name: "doc.richtext", tint: .indigo)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic":
            return FileIcon(name: "photo", tint: .pink)
        case "sh", "zsh", "bash":
            return FileIcon(name: "terminal", tint: .green)
        case "toml", "yml", "yaml", "xml", "plist":
            return FileIcon(name: "doc.text", tint: .gray)
        default:
            return FileIcon(name: "doc", tint: .secondary)
        }
    }
}

private struct WorkspaceImagePreviewView: View {
    let file: RuntimeWorkspaceFile
    let preview: RuntimeWorkspaceImagePreview?
    let errorMessage: String?

    var body: some View {
        if let preview, preview.path == file.path,
           let data = preview.imageData,
           let image = NSImage(data: data)
        {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .accessibilityLabel("\(file.path) 的图片预览")
                Text("\(preview.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if preview != nil {
            Label("macOS 无法渲染此图片格式。", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ProgressView("正在加载图片预览…")
                .controlSize(.small)
        }
    }
}
