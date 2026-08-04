import Foundation

/// Tracks whether the native shell should reconcile an App-owned Runtime after
/// a transient transport failure. It deliberately owns no timer or process:
/// AppKit/SwiftUI provides those effects while this value keeps their policy
/// deterministic and testable.
public struct RuntimeLifecycleRecovery: Sendable {
    private(set) var isSleeping = false
    private(set) var recoveryPending = false

    public init() {}

    /// Returns true only for the first recoverable failure while the App is
    /// awake and connected to a Runtime it owns.
    public mutating func scheduleRecoveryIfNeeded(ownsRuntime: Bool) -> Bool {
        guard ownsRuntime, !isSleeping, !recoveryPending else { return false }
        recoveryPending = true
        return true
    }

    /// Consumes a delayed recovery immediately before the caller performs its
    /// authoritative Runtime reconciliation.
    public mutating func consumeScheduledRecovery() -> Bool {
        guard recoveryPending, !isSleeping else { return false }
        recoveryPending = false
        return true
    }

    /// Cancels a pending recovery when another explicit reconciliation takes
    /// precedence, without changing the sleep state.
    public mutating func cancelScheduledRecovery() {
        recoveryPending = false
    }

    /// Invalidates pending timers before macOS suspends the App. The Runtime
    /// and its Pi sessions remain running and retain their own state.
    @discardableResult
    public mutating func prepareForSleep() -> Bool {
        guard !isSleeping else { return false }
        isSleeping = true
        recoveryPending = false
        return true
    }

    /// Returns true exactly once for each preceding sleep transition so the
    /// native shell performs one authoritative reconciliation after wake.
    @discardableResult
    public mutating func recoverAfterWake() -> Bool {
        guard isSleeping else { return false }
        isSleeping = false
        recoveryPending = false
        return true
    }
}

/// A generation token prevents an older asynchronous refresh from committing
/// state after the user changes projects, the App sleeps, or a newer refresh
/// begins. The caller supplies the currently selected canonical project path.
public struct RuntimeRefreshGeneration: Sendable {
    private var value = 0

    public init() {}

    public mutating func begin(cwd: String) -> Token {
        value += 1
        return Token(value: value, cwd: cwd)
    }

    public mutating func invalidate() {
        value += 1
    }

    public func isCurrent(_ token: Token, cwd: String) -> Bool {
        token.value == value && token.cwd == cwd
    }

    public struct Token: Equatable, Sendable {
        fileprivate let value: Int
        public let cwd: String

        fileprivate init(value: Int, cwd: String) {
            self.value = value
            self.cwd = cwd
        }
    }
}
