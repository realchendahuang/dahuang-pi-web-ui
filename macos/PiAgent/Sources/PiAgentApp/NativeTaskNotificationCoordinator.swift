import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// App-lifetime bridge from Runtime-owned explicit notifications to macOS.
/// It deliberately owns one project subscription per authorized project, not
/// one per window, so reconnecting or opening another window cannot duplicate
/// alerts. Notification text comes only from the bounded Runtime inbox.
@MainActor
final class NativeTaskNotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private static let enabledDefaultsKey = "com.realchendahuang.pi-agent.task-notifications.enabled"
    private static let maximumSeenNotificationIDs = 2_048

    @Published private(set) var enabled: Bool
    @Published private(set) var authorizationLabel = "Not requested"

    var onOpenSession: ((String, String) -> Void)?

    private let notificationCenter: UNUserNotificationCenter
    private var projects: [String: ProjectState] = [:]
    private var seenNotificationIDs = Set<String>()
    private var seenNotificationOrder: [String] = []

    override init() {
        notificationCenter = UNUserNotificationCenter.current()
        enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        super.init()
        notificationCenter.delegate = self
        refreshAuthorizationStatus()
    }

    func setEnabled(_ requested: Bool) {
        guard requested else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            pauseStreams()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                let settings = await notificationCenter.notificationSettings()
                authorizationLabel = Self.authorizationLabel(for: settings.authorizationStatus)
                enabled = granted && Self.permitsDelivery(settings.authorizationStatus)
                UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
                if enabled {
                    projects.values.forEach { startStreamIfNeeded(for: $0) }
                }
            } catch {
                enabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                authorizationLabel = "Unavailable"
            }
        }
    }

    func reconcile(
        client: any RuntimeNotificationClient,
        cwd: String,
        sessions: [RuntimeSession]
    ) {
        let state: ProjectState
        if let existing = projects[cwd] {
            state = existing
            state.client = client
            state.sessions = sessions
        } else {
            state = ProjectState(client: client, cwd: cwd, sessions: sessions)
            projects[cwd] = state
        }
        if enabled { startStreamIfNeeded(for: state) }
    }

    func pauseStreams() {
        for state in projects.values {
            state.generation += 1
            state.task?.cancel()
            state.subscription?.cancel()
            state.task = nil
            state.subscription = nil
        }
    }

    func stop() {
        pauseStreams()
        projects.removeAll()
    }

    private func refreshAuthorizationStatus() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await notificationCenter.notificationSettings()
            authorizationLabel = Self.authorizationLabel(for: settings.authorizationStatus)
            if enabled, !Self.permitsDelivery(settings.authorizationStatus) {
                enabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                pauseStreams()
            }
        }
    }

    private func startStreamIfNeeded(for state: ProjectState) {
        guard enabled, state.task == nil else { return }
        state.generation += 1
        let generation = state.generation
        state.task = Task { [weak self, weak state] in
            guard let self, let state else { return }
            var reconnectDelay: UInt64 = 250_000_000
            while !Task.isCancelled, isCurrent(state, generation: generation) {
                let subscription = state.client.subscribeNotificationSummaries(cwd: state.cwd)
                state.subscription = subscription
                do {
                    var connected = false
                    for try await _ in subscription.ready {
                        connected = true
                        break
                    }
                    guard connected else {
                        throw RuntimeClientError.connectionFailed("notification socket closed before handshake")
                    }
                    try await seedExistingNotifications(for: state)
                    reconnectDelay = 250_000_000
                    for try await event in subscription.events {
                        guard isCurrent(state, generation: generation) else {
                            subscription.cancel()
                            return
                        }
                        try await consume(event, from: state)
                    }
                    throw RuntimeClientError.connectionFailed("notification socket closed")
                } catch is CancellationError {
                    subscription.cancel()
                    return
                } catch {
                    subscription.cancel()
                    state.subscription = nil
                    guard isCurrent(state, generation: generation) else { return }
                    do {
                        try await Task.sleep(nanoseconds: reconnectDelay)
                    } catch {
                        return
                    }
                    reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
                }
            }
            if state.generation == generation {
                state.task = nil
                state.subscription = nil
            }
        }
    }

    private func isCurrent(_ state: ProjectState, generation: Int) -> Bool {
        enabled && state.generation == generation && projects[state.cwd] === state
    }

    private func seedExistingNotifications(for state: ProjectState) async throws {
        for session in state.sessions where session.cwd == state.cwd {
            let inbox = try await state.client.notificationInbox(
                sessionId: session.id,
                cwd: state.cwd,
                runtimeId: session.runtimeId
            )
            guard inbox.summary.cwd == state.cwd, inbox.summary.sessionId == session.id else { continue }
            for notification in inbox.notifications {
                _ = remember(notificationID(inbox: inbox, notification: notification))
            }
        }
    }

    private func consume(
        _ event: RuntimeNotificationSummaryEvent,
        from state: ProjectState
    ) async throws {
        guard event.type == "notifications.summary",
              event.summary.cwd == state.cwd,
              let session = state.sessions.first(where: {
                  $0.id == event.summary.sessionId && $0.cwd == state.cwd
              })
        else { return }
        let inbox = try await state.client.notificationInbox(
            sessionId: session.id,
            cwd: state.cwd,
            runtimeId: session.runtimeId
        )
        guard inbox.summary.cwd == state.cwd, inbox.summary.sessionId == session.id else { return }
        for notification in inbox.notifications {
            let identifier = notificationID(inbox: inbox, notification: notification)
            guard remember(identifier) else { continue }
            guard !NSApp.isActive else { continue }
            deliver(notification, sessionID: session.id, cwd: state.cwd, identifier: identifier)
        }
    }

    /// Returns false for an already-seen Runtime item. The bounded cache makes
    /// reconnects idempotent without retaining a transcript or notification body.
    private func remember(_ identifier: String) -> Bool {
        guard seenNotificationIDs.insert(identifier).inserted else { return false }
        seenNotificationOrder.append(identifier)
        if seenNotificationOrder.count > Self.maximumSeenNotificationIDs {
            let removed = seenNotificationOrder.removeFirst()
            seenNotificationIDs.remove(removed)
        }
        return true
    }

    private func notificationID(
        inbox: RuntimeSessionNotificationInbox,
        notification: RuntimeSessionNotification
    ) -> String {
        "\(inbox.daemonInstanceId):\(inbox.summary.cwd):\(inbox.summary.sessionId):\(notification.id)"
    }

    private func deliver(
        _ notification: RuntimeSessionNotification,
        sessionID: String,
        cwd: String,
        identifier: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Pi Agent task needs attention"
        content.body = notification.message
        content.sound = .default
        // Keep userInfo capability-free. The callback may only select an
        // already-open model for this exact project/session pair.
        content.userInfo = ["version": 1, "sessionId": sessionID, "cwd": cwd]
        notificationCenter.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionID = userInfo["sessionId"] as? String,
              let cwd = userInfo["cwd"] as? String
        else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            self?.onOpenSession?(sessionID, cwd)
        }
        completionHandler()
    }

    private static func permitsDelivery(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    private static func authorizationLabel(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied in System Settings"
        case .authorized: return "Allowed"
        case .provisional: return "Provisional"
        @unknown default: return "Unknown"
        }
    }

    private final class ProjectState {
        var client: any RuntimeNotificationClient
        let cwd: String
        var sessions: [RuntimeSession]
        var subscription: RuntimeNotificationSubscription?
        var task: Task<Void, Never>?
        var generation = 0

        init(client: any RuntimeNotificationClient, cwd: String, sessions: [RuntimeSession]) {
            self.client = client
            self.cwd = cwd
            self.sessions = sessions
        }
    }
}
