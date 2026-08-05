import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct ForkThreadSheet: View {
    @ObservedObject var model: AppModel
    let session: RuntimeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("派生对话")
                .font(.title2.weight(.semibold))
            Text("从 \(session.displayTitle) 中的一条历史用户消息派生新的 Pi 对话。原对话保持不变。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(model.forkCandidates) { candidate in
                Button {
                    model.forkSession(session, from: candidate)
                } label: {
                    Text(candidate.label)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("取消") {
                    model.cancelFork()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }
}
