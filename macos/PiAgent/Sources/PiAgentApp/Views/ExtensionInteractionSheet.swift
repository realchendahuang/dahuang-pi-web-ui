import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct ExtensionInteractionSheet: View {
    @ObservedObject var model: AppModel
    let interaction: RuntimeExtensionInteraction

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(interaction.title)
                .font(.title3.weight(.semibold))
            if let message = interaction.message, !message.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch interaction.kind {
            case "select":
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(interaction.options ?? [], id: \.self) { option in
                            Button(option) {
                                model.respondToExtensionInteraction(interaction, response: .selected(option))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 300)
            case "input":
                TextField(interaction.placeholder ?? "", text: $model.extensionInteractionText)
                    .textFieldStyle(.roundedBorder)
            case "editor":
                TextEditor(text: $model.extensionInteractionText)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("取消") {
                    model.respondToExtensionInteraction(interaction, response: .cancelled)
                }
                .keyboardShortcut(.cancelAction)
                if interaction.kind == "confirm" {
                    Button("确认") {
                        model.respondToExtensionInteraction(interaction, response: .confirmed(true))
                    }
                    .buttonStyle(.borderedProminent)
                } else if interaction.kind == "input" || interaction.kind == "editor" {
                    Button("提交") {
                        model.respondToExtensionInteraction(interaction, response: .text(model.extensionInteractionText))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 480, minHeight: 160)
        .disabled(model.isExtensionInteractionMutationInFlight)
    }
}
