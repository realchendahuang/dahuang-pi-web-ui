import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct WorkspaceMoveSheet: View {
    @ObservedObject var model: AppModel
    let file: RuntimeWorkspaceFile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移动或重命名文件")
                .font(.title2.weight(.semibold))
            Text("在已授权的项目内移动 \(file.path)。不会覆盖已有文件。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("目标相对路径", text: $model.workspaceMoveDestination)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { model.cancelWorkspaceFileMove() }
                    .keyboardShortcut(.cancelAction)
                Button("移动") { model.confirmWorkspaceFileMove() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.workspaceMoveDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(model.isWorkspaceMutationInFlight)
    }
}

struct WorkspaceNewFileSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建文件")
                .font(.title2.weight(.semibold))
            Text("在已授权的项目内创建一个空的 UTF-8 文本文件。不会覆盖已有文件。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("相对路径", text: $model.workspaceNewFilePath)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { model.cancelWorkspaceFileCreation() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { model.createWorkspaceFile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.workspaceNewFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(model.isWorkspaceMutationInFlight)
    }
}
