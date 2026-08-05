import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class TerminalSurfaceController: ObservableObject {
    weak var view: TerminalView?
    private var pendingOutput: [String] = []

    func attach(_ view: TerminalView) {
        self.view = view
        flush()
    }

    func feed(_ output: String) {
        guard !output.isEmpty else { return }
        if view == nil {
            pendingOutput.append(output)
            if pendingOutput.count > 64 { pendingOutput.removeFirst(pendingOutput.count - 64) }
            return
        }
        view?.feed(byteArray: Array(output.utf8)[...])
    }

    private func flush() {
        guard view != nil else { return }
        let output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: false)
        for chunk in output { view?.feed(byteArray: Array(chunk.utf8)[...]) }
    }
}

struct TerminalSurfaceView: NSViewRepresentable {
    @ObservedObject var controller: TerminalSurfaceController
    let onInput: (String) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = context.coordinator
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.terminalDelegate = context.coordinator
        controller.attach(nsView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let onInput: (String) -> Void
        private let onResize: (Int, Int) -> Void

        init(onInput: @escaping (String) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(String(decoding: data, as: UTF8.self))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {}
    }
}
