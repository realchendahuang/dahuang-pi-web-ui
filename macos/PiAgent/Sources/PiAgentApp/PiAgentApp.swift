import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// One App process must supervise at most one bundled Runtime. Each window
/// receives this immutable connection but owns its own project/thread/UI state.
@MainActor
private final class SharedRuntimeConnection: ObservableObject {
    let connection: AppModel.RuntimeConnection

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        connection = AppModel.makeRuntimeConnection(environment: environment)
    }
}

private struct PiAgentWindowRoot: View {
    @StateObject private var model: AppModel
    private let lifecycle: AppLifecycleDelegate

    init(connection: AppModel.RuntimeConnection, lifecycle: AppLifecycleDelegate) {
        let windowIdentifier = UUID().uuidString
        _model = StateObject(wrappedValue: AppModel(
            projectAuthorizationStore: ProjectAuthorizationStore(
                key: "com.realchendahuang.pi-agent.authorized-project.\(windowIdentifier)"
            ),
            connection: connection,
            taskNotifications: lifecycle.taskNotifications
        ))
        self.lifecycle = lifecycle
    }

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 980, minHeight: 680)
            .onAppear { lifecycle.register(model) }
            .onDisappear { lifecycle.unregister(model) }
            .alert(
                "仍有对话正在运行",
                isPresented: $model.showTerminationConfirmation
            ) {
                Button("保持运行并退出") { model.keepRuntimeRunningAndTerminate() }
                Button("停止 Runtime 并退出", role: .destructive) { model.stopOwnedRuntimeAndTerminate() }
                Button("取消", role: .cancel) { model.cancelTermination() }
            } message: {
                Text(model.terminationConfirmationMessage)
            }
            .alert(
                "永久删除已归档的对话？",
                isPresented: Binding(
                    get: { model.sessionPendingPermanentDeletion != nil },
                    set: { if !$0 { model.cancelPermanentDelete() } }
                )
            ) {
                Button("永久删除", role: .destructive) { model.confirmPermanentDelete() }
                Button("取消", role: .cancel) { model.cancelPermanentDelete() }
            } message: {
                Text("这会从 Pi Agent 存储中移除已归档的对话记录，且无法撤销。")
            }
            .alert(
                "删除工作区文件？",
                isPresented: Binding(
                    get: { model.workspaceFilePendingDeletion != nil },
                    set: { if !$0 { model.cancelWorkspaceFileDeletion() } }
                )
            ) {
                Button("删除文件", role: .destructive) { model.confirmWorkspaceFileDeletion() }
                Button("取消", role: .cancel) { model.cancelWorkspaceFileDeletion() }
            } message: {
                Text("这会从已授权的项目中永久移除所选文件。")
            }
    }
}

@main
struct PiAgentApp: App {
    @StateObject private var runtime = SharedRuntimeConnection()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Pi Agent", id: "pi-agent-main") {
            PiAgentWindowRoot(connection: runtime.connection, lifecycle: lifecycleDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新窗口") {
                    openWindow(id: "pi-agent-main")
                }
                .keyboardShortcut("n", modifiers: [.command])
                Divider()
                Button("新对话") {
                    lifecycleDelegate.activeModel?.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("打开项目") {
                    lifecycleDelegate.activeModel?.openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("重新连接 Runtime") {
                    lifecycleDelegate.activeModel?.refreshRuntime()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("下一个模型") {
                    lifecycleDelegate.activeModel?.cycleModel(direction: "forward")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(lifecycleDelegate.activeModel?.selectedSessionStatus?.model == nil)
                Button("下一个推理强度") {
                    lifecycleDelegate.activeModel?.cycleThinkingLevel()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(lifecycleDelegate.activeModel?.selectedSessionStatus?.thinkingLevel == nil)
            }
        }

        Settings {
            if let model = lifecycleDelegate.activeModel {
                SettingsView(model: model)
            } else {
                Text("打开 Pi Agent 窗口以配置项目和 Runtime。")
                    .padding()
            }
        }

        // A visible background affordance: closing all document windows never
        // implies stopping the Runtime, and this menu gives users a way back.
        MenuBarExtra("Pi Agent", systemImage: "sparkles") {
            Button("打开 Pi Agent") {
                openWindow(id: "pi-agent-main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("退出 Pi Agent") {
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let models = NSHashTable<AppModel>.weakObjects()
    weak var activeModel: AppModel?
    let taskNotifications = NativeTaskNotificationCoordinator()
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        taskNotifications.onOpenSession = { [weak self] sessionID, cwd in
            guard let self else { return }
            if let model = self.allModels.first(where: {
                $0.selectNotificationSession(sessionID: sessionID, cwd: cwd)
            }) {
                self.activeModel = model
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.allModels.forEach { $0.systemWillSleep() }
            }
        }
        didWakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.allModels.forEach { $0.systemDidWake() }
            }
        }
    }

    func register(_ model: AppModel) {
        models.add(model)
        activeModel = model
    }

    func unregister(_ model: AppModel) {
        models.remove(model)
        if activeModel === model {
            activeModel = allModels.last
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        activeModel?.requestApplicationTermination() ?? .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let willSleepObserver {
            notificationCenter.removeObserver(willSleepObserver)
        }
        if let didWakeObserver {
            notificationCenter.removeObserver(didWakeObserver)
        }
        willSleepObserver = nil
        didWakeObserver = nil
        taskNotifications.stop()
    }

    private var allModels: [AppModel] { models.allObjects }
}
