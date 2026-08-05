import Foundation
import Testing
@testable import PiAgentCore

@Suite("RuntimeLaunchNonce")
struct RuntimeLaunchNonceTests {
    /// Runs registered cleanup blocks on scope exit (Swift Testing on this
    /// toolchain has no teardown-block API, so a deinit registry stands in).
    private final class CleanupRegistry {
        private var blocks: [() -> Void] = []
        func add(_ block: @escaping () -> Void) { blocks.append(block) }
        deinit { for block in blocks.reversed() { block() } }
    }

    /// Creates an isolated 0700 scratch directory; removed on scope exit.
    private func makeScratchDirectory(_ cleanup: CleanupRegistry) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-agent-nonce-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        cleanup.add { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @Test func loadOrCreateWritesPrivilegedFile() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        let nonce = try RuntimeLaunchNonce.loadOrCreate(in: directory)

        #expect(!nonce.currentValue.isEmpty)
        #expect(nonce.fileURL.path == directory.appendingPathComponent(RuntimeLaunchNonce.fileName).path)
        #expect(FileManager.default.fileExists(atPath: nonce.fileURL.path))
    }

    @Test func loadOrCreateReusesExistingNonce() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        let first = try RuntimeLaunchNonce.loadOrCreate(in: directory)
        let second = try RuntimeLaunchNonce.loadOrCreate(in: directory)

        #expect(first.currentValue == second.currentValue)
    }

    @Test func newNonceMatchesBase64URLShape() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        let nonce = try RuntimeLaunchNonce.loadOrCreate(in: directory)

        // 32 random bytes, base64url-encoded without padding: exactly 43 chars.
        #expect(
            nonce.currentValue.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
            "unexpected nonce format: \(nonce.currentValue)"
        )
    }

    @Test func rotateChangesValueAndPersists() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        let nonce = try RuntimeLaunchNonce.loadOrCreate(in: directory)
        let original = nonce.currentValue

        try nonce.rotate()

        #expect(nonce.currentValue != original)
        let reloaded = try RuntimeLaunchNonce.loadOrCreate(in: directory)
        #expect(reloaded.currentValue == nonce.currentValue)
    }

    @Test func rejectsWorldReadableNonceFile() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        _ = try RuntimeLaunchNonce.loadOrCreate(in: directory)
        let fileURL = directory.appendingPathComponent(RuntimeLaunchNonce.fileName)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        #expect(throws: RuntimeClientError.self) {
            try RuntimeLaunchNonce.loadOrCreate(in: directory)
        }
    }

    @Test func prepareSecureDirectoryCreates0700() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        let fresh = directory.appendingPathComponent("nested/state", isDirectory: true)

        try RuntimeLaunchNonce.prepareSecureDirectory(fresh)

        let attributes = try FileManager.default.attributesOfItem(atPath: fresh.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }

    @Test func prepareSecureDirectoryRejectsSymlink() throws {
        let cleanup = CleanupRegistry()
        let directory = try makeScratchDirectory(cleanup)
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: RuntimeClientError.self) {
            try RuntimeLaunchNonce.prepareSecureDirectory(link)
        }
    }
}
