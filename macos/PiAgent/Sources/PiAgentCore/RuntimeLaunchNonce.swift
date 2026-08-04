import Foundation
import Security

#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// A per-Runtime launch secret shared only through a current-user `0600` file.
///
/// The nonce is not request authentication: the private Unix socket and peer
/// checks provide that boundary. It makes the first hello prove that the
/// Runtime at that socket was launched from this App-managed Runtime directory,
/// rather than merely being a same-user process that claimed the socket path.
public final class RuntimeLaunchNonce: @unchecked Sendable {
    public static let fileName = "runtime-hello-nonce"
    public static let projectCapabilityTokenFileName = "runtime-project-capability-token"

    public let fileURL: URL
    private let lock = NSLock()
    private var nonce: String

    private init(fileURL: URL, nonce: String) {
        self.fileURL = fileURL
        self.nonce = nonce
    }

    public var currentValue: String {
        lock.lock()
        defer { lock.unlock() }
        return nonce
    }

    public static func loadOrCreate(
        in directory: URL,
        fileName: String = fileName
    ) throws -> RuntimeLaunchNonce {
        try validateDirectory(directory)
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return RuntimeLaunchNonce(fileURL: fileURL, nonce: try read(fileURL))
        }
        let nonce = try newValue()
        try write(nonce, to: fileURL, in: directory)
        return RuntimeLaunchNonce(fileURL: fileURL, nonce: nonce)
    }

    /// Rotates immediately before the supervisor launches a new child. A
    /// healthy Runtime is checked first, so reopening the App can still prove
    /// and reuse the existing Runtime without changing its nonce.
    public func rotate() throws {
        let value = try Self.newValue()
        try Self.write(value, to: fileURL, in: fileURL.deletingLastPathComponent())
        lock.lock()
        nonce = value
        lock.unlock()
    }

    private static func newValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RuntimeClientError.connectionFailed("Could not create bundled Runtime hello nonce")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func write(_ value: String, to fileURL: URL, in directory: URL) throws {
        try validateDirectory(directory)
        let temporaryURL = directory.appendingPathComponent(".runtime-launch-secret-\(UUID().uuidString)")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RuntimeClientError.connectionFailed("Could not create bundled Runtime launch secret file: \(String(cString: strerror(errno)))")
        }
        do {
            try writeAll(Data(value.utf8), descriptor: descriptor)
            guard fsync(descriptor) == 0 else {
                throw RuntimeClientError.connectionFailed("Could not persist bundled Runtime launch secret")
            }
            guard close(descriptor) == 0 else {
                throw RuntimeClientError.connectionFailed("Could not close bundled Runtime launch secret file")
            }
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw RuntimeClientError.connectionFailed("Could not install bundled Runtime launch secret file: \(String(cString: strerror(errno)))")
            }
            _ = try read(fileURL)
        } catch {
            _ = close(descriptor)
            _ = unlink(temporaryURL.path)
            throw error
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard written > 0 else {
                    throw RuntimeClientError.connectionFailed("Could not write bundled Runtime launch secret file: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    private static func read(_ fileURL: URL) throws -> String {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else {
            throw RuntimeClientError.connectionFailed("Could not inspect bundled Runtime launch secret file: \(String(cString: strerror(errno)))")
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o600
        else {
            throw RuntimeClientError.connectionFailed("Bundled Runtime launch secret file is not a current-user 0600 regular file")
        }
        let value = try String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw RuntimeClientError.connectionFailed("Bundled Runtime launch secret file is invalid")
        }
        return value
    }

    private static func validateDirectory(_ directory: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else {
            throw RuntimeClientError.connectionFailed("Could not inspect bundled Runtime directory: \(String(cString: strerror(errno)))")
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o700
        else {
            throw RuntimeClientError.connectionFailed("Bundled Runtime directory is not a current-user 0700 directory")
        }
    }
}
