import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// Domains shown in the right-hand inspector. The selection is view state
/// only and intentionally not persisted.
enum InspectorTab: String, CaseIterable, Identifiable {
    case files, git, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "文件"
        case .git: return "Git"
        case .terminal: return "终端"
        }
    }

    var systemImage: String {
        switch self {
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        case .terminal: return "terminal"
        }
    }
}

/// Held as an ObservableObject because the build toolchain cannot expand the
/// macro-based `@State` property wrapper.
final class InspectorTabSelection: ObservableObject {
    @Published var tab: InspectorTab = .files
}

/// Slim panel chrome: a segmented control on top, the selected domain below.
struct InspectorView: View {
    @ObservedObject var model: AppModel
    @StateObject private var selection = InspectorTabSelection()

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $selection.tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .accessibilityLabel("检查器分区")

            Divider()

            Group {
                switch selection.tab {
                case .files:
                    WorkspaceFilesView(model: model)
                case .git:
                    ScrollView {
                        GitChangesView(model: model)
                            .padding(Theme.Spacing.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .terminal:
                    terminalContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("检查器")
        .task { model.ensureTerminalConnection() }
    }

    private var terminalContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let terminal = model.terminalInfo {
                HStack {
                    Label(terminal.name, systemImage: "terminal")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if terminal.exited {
                        Button("继续") { model.continueTerminal() }
                            .buttonStyle(.borderless)
                            .disabled(model.isTerminalMutationInFlight)
                    }
                }
                TerminalSurfaceView(
                    controller: model.terminalSurfaceController,
                    onInput: model.sendTerminalInput,
                    onResize: model.resizeTerminal(cols:rows:)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
            } else {
                VStack(spacing: Theme.Spacing.small) {
                    Label(
                        model.terminalErrorMessage ?? "连接中…",
                        systemImage: "terminal"
                    )
                    .foregroundStyle(.secondary)
                    if model.terminalErrorMessage != nil {
                        Button("重新连接") { model.reconnectTerminal() }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let terminalErrorMessage = model.terminalErrorMessage,
               model.terminalInfo != nil
            {
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    Text(terminalErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重新连接") { model.reconnectTerminal() }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(Theme.Spacing.medium)
    }
}
