import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

struct NativeAuthFlowSheet: View {
    @ObservedObject var model: AppModel
    let flow: RuntimeAuthFlow
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接 \(flow.providerName)").font(.title2.weight(.semibold))
            if let auth = flow.auth {
                Button("在浏览器中打开授权") { openURL(URL(string: auth.url)!) }
                if let instructions = auth.instructions { Text(instructions).foregroundStyle(.secondary) }
                if let code = auth.deviceCode?.userCode { Text("设备代码：\(code)").textSelection(.enabled) }
            }
            ForEach(flow.progress, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if let prompt = flow.prompt {
                if prompt.promptType == "secret" { SecureField(prompt.message, text: $model.authInput).textFieldStyle(.roundedBorder) }
                else { TextField(prompt.message, text: $model.authInput).textFieldStyle(.roundedBorder) }
                Button("继续") { model.respondToAuthFlow() }.buttonStyle(.borderedProminent)
            }
            if let select = flow.select {
                Text(select.message)
                ForEach(select.options) { option in Button(option.label) { model.respondToAuthFlow(option.value) } }
            }
            if let error = flow.error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("刷新") { model.refreshAuthFlow() }; Button("取消") { model.cancelAuthFlow() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: flow.prompt?.requestId) { _, _ in model.authInput = "" }
    }
}
