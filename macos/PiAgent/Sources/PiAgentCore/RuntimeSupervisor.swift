import Foundation

#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Owns only a Runtime process explicitly started by the native shell.
///
/// An already-running session daemon is never terminated by this type. That
/// distinction is what lets the App reconnect after a window or UI restart.
public final class RuntimeSupervisor: @unchecked Sendable {
    private let plan: RuntimeLaunchPlan
    private let launchSecrets: [RuntimeLaunchNonce]
    private let validateBeforeStart: @Sendable () throws -> Void
    private let lock = NSLock()
    private var process: Process?

    public init(
        plan: RuntimeLaunchPlan,
        launchSecrets: [RuntimeLaunchNonce] = [],
        validateBeforeStart: @escaping @Sendable () throws -> Void = {}
    ) {
        self.plan = plan
        self.launchSecrets = launchSecrets
        self.validateBeforeStart = validateBeforeStart
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func start() throws {
        try validateBeforeStart()
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning != true else { return }
        for secret in launchSecrets { try secret.rotate() }

        var environment = plan.environment
        if let projectCapabilityToken = launchSecrets.first(where: {
            $0.fileURL.lastPathComponent == RuntimeLaunchNonce.projectCapabilityTokenFileName
        }) {
            environment["PI_AGENT_RUNTIME_PROJECT_CAPABILITY_TOKEN"] = projectCapabilityToken.currentValue
        }

        let child = Process()
        child.executableURL = plan.executable
        child.arguments = plan.arguments
        child.environment = environment
        child.currentDirectoryURL = plan.workingDirectory
        try child.run()
        process = child
    }

    /// Reuses a healthy compatible Runtime at the plan's socket. Otherwise it
    /// validates and launches only the Runtime this supervisor owns, then waits
    /// for its product-level handshake instead of guessing from a PID.
    public func ensureRunning(
        using client: any RuntimeHelloClient,
        attempts: Int = 80,
        retryDelayNanoseconds: UInt64 = 125_000_000
    ) async throws -> RuntimeHealth {
        if let health = try? await compatibleHealth(using: client) {
            return health
        }

        // Do not block the App's main actor while another Pi Agent process is
        // starting the Runtime or while full manifest verification runs.
        return try await Task.detached(priority: .userInitiated) { [self] in
            let launchLock = try RuntimeLaunchLock.acquire(socketPath: plan.socketPath)
            defer { launchLock.release() }

            // The holder before us may have completed startup while we waited
            // for the lock. Rechecking is what prevents a second child from
            // being created for the same stable socket path.
            if let health = try? await compatibleHealth(using: client) {
                return health
            }
            try start()
            var lastError: Error?
            for _ in 0..<attempts {
                do {
                    return try await compatibleHealth(using: client)
                } catch {
                    lastError = error
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
            throw lastError ?? RuntimeClientError.connectionFailed("Runtime did not become healthy")
        }.value
    }

    public func stop() {
        lock.lock()
        let child = process
        process = nil
        lock.unlock()

        guard let child, child.isRunning else { return }
        child.terminate()
    }

    private func compatibleHealth(using client: any RuntimeHelloClient) async throws -> RuntimeHealth {
        async let health = client.health()
        let hello = try await client.hello()
        try hello.requireCompatibleProtocol(major: BundledRuntime.protocolMajor)
        return try await health
    }
}

/// Coordinates only bundled Runtime startup. The Unix socket remains the
/// product-level source of truth; this lock merely closes the narrow window
/// where two App processes both observe an absent socket and race to spawn.
private final class RuntimeLaunchLock: @unchecked Sendable {
    private let descriptor: Int32
    private var released = false
    private let stateLock = NSLock()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(socketPath: String) throws -> RuntimeLaunchLock {
        let socketURL = URL(fileURLWithPath: socketPath)
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = directory.appendingPathComponent(".sessiond-launch.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RuntimeClientError.connectionFailed(
                "Could not open Runtime launch lock: \(String(cString: strerror(errno)))"
            )
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let message = String(cString: strerror(errno))
            _ = close(descriptor)
            throw RuntimeClientError.connectionFailed("Could not acquire Runtime launch lock: \(message)")
        }
        return RuntimeLaunchLock(descriptor: descriptor)
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit {
        release()
    }
}
