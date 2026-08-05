import SwiftUI

/// Requires a deliberately specific phrase so a destructive maintenance
/// helper cannot be launched from a single accidental Settings click.
struct NativeDataEraseSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("抹掉所有原生 Pi Agent 数据？")
                .font(.title2.weight(.semibold))
            Text("Pi Agent 会先退出。其 Application Support 数据会被移入废纸篓，Keychain 凭据则被永久删除。Pi Agent.app、你的项目文件夹和旧版 PI WEB 数据不受影响。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("输入 \(AppModel.dataEraseConfirmationPhrase) 以继续。")
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
            TextField("确认短语", text: $model.dataEraseConfirmationText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { model.cancelDataErase() }
                    .keyboardShortcut(.cancelAction)
                Button("抹掉原生数据并退出", role: .destructive) {
                    model.confirmDataErase()
                }
                .disabled(!model.canConfirmDataErase || model.isDataErasePreparing)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(model.isDataErasePreparing)
    }
}
