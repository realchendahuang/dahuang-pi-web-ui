import SwiftUI

/// Requires a deliberately specific phrase so a destructive maintenance
/// helper cannot be launched from a single accidental Settings click.
struct NativeDataEraseSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Erase all native Pi Agent data?")
                .font(.title2.weight(.semibold))
            Text("Pi Agent will exit first. Its Application Support data is moved to the Trash, but its Keychain credentials are permanently deleted. Pi Agent.app, your project folders, and legacy PI WEB data are not changed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Type \(AppModel.dataEraseConfirmationPhrase) to continue.")
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
            TextField("Confirmation phrase", text: $model.dataEraseConfirmationText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelDataErase() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase Native Data and Quit", role: .destructive) {
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
