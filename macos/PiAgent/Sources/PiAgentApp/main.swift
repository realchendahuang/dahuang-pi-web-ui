import PiAgentCore
import SwiftUI

@main
struct PiAgentApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Pi Agent") {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    model.newThread()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Reconnect Runtime") {
                    model.refreshRuntime()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Thread: Identifiable, Hashable {
        let id: UUID
        let title: String
        let status: String
    }

    @Published var runtimeState: RuntimeConnectionState = .disconnected
    @Published var selectedThreadID: UUID?
    @Published var showInspector = true
    @Published var prompt = ""
    @Published var threads: [Thread] = [
        Thread(id: UUID(), title: "Native shell vertical slice", status: "Ready"),
    ]

    let runtimeClient: any RuntimeHealthClient

    init(runtimeClient: any RuntimeHealthClient = AppModel.makeRuntimeClient()) {
        self.runtimeClient = runtimeClient
        selectedThreadID = threads.first?.id
    }

    func refreshRuntime() {
        runtimeState = .connecting
        let client = runtimeClient
        Task { [weak self] in
            do {
                let health = try await client.health()
                self?.runtimeState = .connected(health)
            } catch {
                self?.runtimeState = .failed(error.localizedDescription)
            }
        }
    }

    func newThread() {
        let thread = Thread(id: UUID(), title: "New thread", status: "Draft")
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
    }

    var runtimeLabel: String {
        switch runtimeState {
        case .disconnected:
            return "Runtime disconnected"
        case .connecting:
            return "Connecting…"
        case let .connected(health):
            return health.version.label
        case let .failed(message):
            return "Runtime unavailable: \(message)"
        }
    }

    private static func makeRuntimeClient() -> any RuntimeHealthClient {
        let socket = ProcessInfo.processInfo.environment["PI_AGENT_RUNTIME_SOCKET"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi-web/sessiond.sock")
                .path
        return UnixSocketRuntimeClient(socketPath: socket)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedThreadID) {
                Section("Project") {
                    Label("Local checkout", systemImage: "folder")
                        .foregroundStyle(.secondary)
                }

                Section("Threads") {
                    ForEach(model.threads) { thread in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title)
                                Text(thread.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: thread.status == "Ready" ? "circle.fill" : "circle")
                                .foregroundStyle(thread.status == "Ready" ? .green : .secondary)
                        }
                        .tag(thread.id)
                    }
                }
            }
            .navigationTitle("Pi Agent")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.newThread) {
                        Label("New Thread", systemImage: "plus")
                    }
                }
            }
        } detail: {
            TranscriptView(model: model)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.runtimeLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshRuntime()
                } label: {
                    Label("Reconnect Runtime", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .task {
            model.refreshRuntime()
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Native Pi Agent")
                        .font(.largeTitle.weight(.semibold))
                    Text("This Phase 0 shell keeps Runtime ownership in the existing session daemon and makes the connection state visible.")
                        .foregroundStyle(.secondary)
                    Divider()
                    Label("Environment: Local checkout", systemImage: "desktopcomputer")
                    Label("Thread: \(model.threads.first(where: { $0.id == model.selectedThreadID })?.title ?? "None")", systemImage: "bubble.left.and.bubble.right")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(32)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask Pi Agent…", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button("Send") {
                    model.prompt = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Environment") {
                LabeledContent("Type", value: "Local checkout")
                LabeledContent("Runtime", value: model.runtimeLabel)
            }
            Section("Workspace") {
                Label("Changes", systemImage: "square.and.pencil")
                Label("Files", systemImage: "doc")
                Label("Terminal", systemImage: "terminal")
            }
            Section("Runtime health") {
                switch model.runtimeState {
                case let .connected(health):
                    LabeledContent("Active sessions", value: String(health.activeSessions))
                    LabeledContent("Protocol", value: health.version.component)
                default:
                    Text(model.runtimeLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Inspector")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Runtime") {
                Text("The native shell connects to the existing PI WEB session daemon through its user-owned Unix socket.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: model.runtimeLabel)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
