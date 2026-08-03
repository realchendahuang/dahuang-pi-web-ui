import AppKit
import PiAgentCore
import SwiftUI

@main
struct PiAgentApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Pi Agent") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    model.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Open Project") {
                    model.openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])
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
    @Published var runtimeState: RuntimeConnectionState = .disconnected
    @Published var projectPath: String
    @Published var selectedSessionID: String?
    @Published var showInspector = true
    @Published var prompt = ""
    @Published var sessions: [RuntimeSession] = []
    @Published var transcriptMessages: [RuntimeMessage] = []
    @Published var statusBySession: [String: RuntimeSessionStatus] = [:]
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?

    let runtimeClient: any RuntimeClient

    init(
        runtimeClient: any RuntimeClient = AppModel.makeRuntimeClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runtimeClient = runtimeClient
        let configuredPath = environment["PI_AGENT_PROJECT_PATH"]
            ?? environment["PWD"]
            ?? FileManager.default.currentDirectoryPath
        projectPath = URL(fileURLWithPath: configuredPath).standardizedFileURL.path
    }

    var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    var selectedSession: RuntimeSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
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

    func refreshRuntime() {
        let client = runtimeClient
        let cwd = projectPath
        isLoading = true
        errorMessage = nil
        runtimeState = .connecting
        Task { [weak self] in
            do {
                let health = try await client.health()
                let sessions = try await client.listSessions(cwd: cwd)
                guard let self else { return }
                self.runtimeState = .connected(health)
                self.replaceSessions(sessions)
                self.isLoading = false
            } catch {
                guard let self else { return }
                self.runtimeState = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project"
        panel.message = "Choose the checkout Pi Agent should use for new and existing sessions."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.standardizedFileURL.path
        selectedSessionID = nil
        transcriptMessages = []
        statusBySession = [:]
        refreshRuntime()
    }

    func selectSession(_ sessionID: String?) {
        selectedSessionID = sessionID
        transcriptMessages = []
        errorMessage = nil
        guard sessionID != nil else { return }
        loadSelectedSession()
    }

    func startNewSession() {
        let client = runtimeClient
        let cwd = projectPath
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            do {
                let session = try await client.startSession(cwd: cwd, runtimeId: nil)
                guard let self else { return }
                self.sessions.removeAll { $0.id == session.id }
                self.sessions.insert(session, at: 0)
                self.selectedSessionID = session.id
                self.transcriptMessages = []
                self.isSending = false
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func sendPrompt() {
        guard let session = selectedSession else {
            errorMessage = "Select a session before sending a prompt."
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        let client = runtimeClient
        let cwd = projectPath
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            do {
                try await client.prompt(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId,
                    text: text
                )
                guard let self else { return }
                self.prompt = ""
                try await self.refreshUntilSettled(
                    client: client,
                    session: session,
                    cwd: cwd
                )
                self.isSending = false
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func refreshSelectedSession() {
        loadSelectedSession()
    }

    private func loadSelectedSession() {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        let cwd = projectPath
        Task { [weak self] in
            do {
                let page = try await client.messages(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                let status = try? await client.status(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                guard let self else { return }
                self.transcriptMessages = page.messages
                if let status { self.statusBySession[session.id] = status }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshUntilSettled(
        client: any RuntimeClient,
        session: RuntimeSession,
        cwd: String
    ) async throws {
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 350_000_000)
            let page = try await client.messages(
                sessionId: session.id,
                cwd: cwd,
                runtimeId: session.runtimeId
            )
            let status = try await client.status(
                sessionId: session.id,
                cwd: cwd,
                runtimeId: session.runtimeId
            )
            transcriptMessages = page.messages
            statusBySession[session.id] = status
            if !status.isStreaming && !status.isCompacting && status.pendingMessageCount == 0 {
                return
            }
        }
    }

    private func replaceSessions(_ sessions: [RuntimeSession]) {
        let visible = sessions
            .filter { $0.archived != true }
            .sorted { $0.modified > $1.modified }
        self.sessions = visible
        if let selectedSessionID, visible.contains(where: { $0.id == selectedSessionID }) {
            loadSelectedSession()
        } else {
            self.selectedSessionID = visible.first?.id
            if self.selectedSessionID != nil { loadSelectedSession() }
        }
    }

    private static func makeRuntimeClient() -> any RuntimeClient {
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
            SidebarView(model: model)
        } detail: {
            TranscriptView(model: model)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(model.projectName)
                        .font(.subheadline.weight(.semibold))
                    Text(model.runtimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshRuntime()
                } label: {
                    Label("Reconnect Runtime", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
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

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedSessionID },
            set: { model.selectSession($0) }
        )) {
            Section("Project") {
                Button {
                    model.openProject()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.projectName)
                            Text(model.projectPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                .buttonStyle(.plain)
            }

            Section("Sessions") {
                if model.sessions.isEmpty {
                    Label(
                        model.isLoading ? "Loading sessions…" : "No sessions in this project",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session, status: model.statusBySession[session.id])
                            .tag(Optional(session.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Pi Agent")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.startNewSession) {
                    Label("New Thread", systemImage: "plus")
                }
                .disabled(model.isSending || model.projectPath.isEmpty)
            }
        }
    }
}

struct SessionRow: View {
    let session: RuntimeSession
    let status: RuntimeSessionStatus?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.runtimeId.uppercased())
                    Text("·")
                    Text(statusLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: status?.isStreaming == true ? "circle.dotted" : "circle")
                .foregroundStyle(status?.isStreaming == true ? .orange : .secondary)
        }
    }

    private var statusLabel: String {
        if status?.isStreaming == true { return "Running" }
        if status?.isCompacting == true { return "Compacting" }
        return "Ready"
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { model.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .padding(12)
                .background(.yellow.opacity(0.14))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let session = model.selectedSession {
                        Text(session.displayTitle)
                            .font(.title2.weight(.semibold))
                        Text("\(session.runtimeId.uppercased()) · \(session.messageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if model.transcriptMessages.isEmpty {
                            Text(session.firstMessage.isEmpty ? "No transcript messages yet." : session.firstMessage)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            ForEach(Array(model.transcriptMessages.enumerated()), id: \.offset) { _, message in
                                MessageRow(message: message)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Select a session",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Choose an existing session or create a new one for this project.")
                        )
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(32)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask Pi Agent…", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) { model.sendPrompt() }
                    }
                Button(model.isSending ? "Sending…" : "Send") {
                    model.sendPrompt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedSession == nil
                        || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSending
                )
            }
            .padding(16)
        }
    }
}

struct MessageRow: View {
    let message: RuntimeMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty ? "(non-text message)" : message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Environment") {
                LabeledContent("Project", value: model.projectName)
                LabeledContent("Path", value: model.projectPath)
                LabeledContent("Runtime", value: model.runtimeLabel)
            }
            Section("Session") {
                LabeledContent("Count", value: String(model.sessions.count))
                if let session = model.selectedSession {
                    LabeledContent("Runtime", value: session.runtimeId.uppercased())
                    LabeledContent("Messages", value: String(session.messageCount))
                    if let status = model.statusBySession[session.id] {
                        LabeledContent("State", value: status.isStreaming ? "Running" : "Ready")
                        LabeledContent("Queued", value: String(status.pendingMessageCount))
                    }
                } else {
                    Text("No session selected")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Workspace") {
                Label("Changes", systemImage: "square.and.pencil")
                Label("Files", systemImage: "doc")
                Label("Terminal", systemImage: "terminal")
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
                LabeledContent("Socket", value: model.runtimeClientSocketDescription)
            }
            Section("Project") {
                LabeledContent("Current", value: model.projectPath)
                Button("Choose Project…") { model.openProject() }
            }
        }
        .padding()
        .frame(width: 520)
    }
}

private extension AppModel {
    var runtimeClientSocketDescription: String {
        if let client = runtimeClient as? UnixSocketRuntimeClient { return client.socketPath }
        return "Configured Runtime client"
    }
}
