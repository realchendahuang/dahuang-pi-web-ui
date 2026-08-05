import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.showSettingsPage {
                // Settings replaces the entire split view, Codex-style: the
                // page carries its own nav column and a Back row.
                SettingsView(model: model)
            } else {
                NavigationSplitView {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
                } detail: {
                    TranscriptView(model: model)
                        .navigationTitle(model.selectedSession?.displayTitle ?? "Pi Agent")
                }
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showInspector.toggle()
                        } label: {
                            Image(systemName: "sidebar.trailing")
                        }
                        .help("切换检查器")
                    }
                }
            }
        }
        .sheet(item: $model.sessionPendingFork, onDismiss: model.cancelFork) { session in
            ForkThreadSheet(model: model, session: session)
        }
        .sheet(isPresented: $model.showGitCommitSheet) {
            GitCommitSheet(model: model)
        }
        .sheet(isPresented: $model.showGitPushConfirmation) {
            GitPushConfirmationSheet(model: model)
        }
        .sheet(item: Binding(
            get: { model.gitPathPendingDiscard },
            set: { if $0 == nil { model.cancelGitDiscard() } }
        )) { file in
            GitDiscardConfirmationSheet(model: model, file: file)
        }
        .sheet(isPresented: $model.showGitRevertConfirmation) {
            GitRevertConfirmationSheet(model: model)
        }
        .sheet(item: Binding(
            get: { model.workspaceFilePendingMove },
            set: { if $0 == nil { model.cancelWorkspaceFileMove() } }
        )) { file in
            WorkspaceMoveSheet(model: model, file: file)
        }
        .sheet(isPresented: $model.showWorkspaceNewFileSheet, onDismiss: model.cancelWorkspaceFileCreation) {
            WorkspaceNewFileSheet(model: model)
        }
        .sheet(item: $model.activeAuthFlow) { flow in
            NativeAuthFlowSheet(model: model, flow: flow)
        }
        .sheet(item: Binding(
            get: { model.activeExtensionInteraction },
            set: { _ in }
        )) { interaction in
            ExtensionInteractionSheet(model: model, interaction: interaction)
        }
        .task {
            model.refreshRuntime()
        }
    }
}
