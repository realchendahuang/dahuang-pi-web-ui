import Foundation

/// Owns only a Runtime process explicitly started by the native shell.
///
/// An already-running session daemon is never terminated by this type. That
/// distinction is what lets the App reconnect after a window or UI restart.
public final class RuntimeSupervisor: @unchecked Sendable {
    private let plan: RuntimeLaunchPlan
    private let lock = NSLock()
    private var process: Process?

    public init(plan: RuntimeLaunchPlan) {
        self.plan = plan
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning != true else { return }

        let child = Process()
        child.executableURL = plan.executable
        child.arguments = plan.arguments
        child.environment = plan.environment
        child.currentDirectoryURL = plan.workingDirectory
        try child.run()
        process = child
    }

    public func stop() {
        lock.lock()
        let child = process
        process = nil
        lock.unlock()

        guard let child, child.isRunning else { return }
        child.terminate()
    }
}
