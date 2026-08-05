import Foundation
import Testing
@testable import PiAgentCore

@Suite("ProjectAuthorizationStore")
struct ProjectAuthorizationStoreTests {
    private final class Harness {
        let defaults: UserDefaults
        let store: ProjectAuthorizationStore
        let directory: URL

        init() throws {
            let suite = "pi-agent-auth-tests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw ProjectAuthorizationError.notDirectory(suite)
            }
            self.defaults = defaults
            store = ProjectAuthorizationStore(
                defaults: defaults,
                key: "test.authorized-project"
            )
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pi-agent-auth-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            store.clear()
            defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness() throws -> Harness {
        try Harness()
    }

    @Test func authorizeRejectsFilePaths() throws {
        let harness = try makeHarness()
        let fileURL = harness.directory.appendingPathComponent("not-a-directory.txt")

        #expect(throws: ProjectAuthorizationError.self) {
            try harness.store.authorize(fileURL)
        }
    }

    @Test func authorizeThenRestoreRoundTripsPath() throws {
        let harness = try makeHarness()
        let access = try harness.store.authorize(harness.directory)

        #expect(access.url.path == harness.directory.standardizedFileURL.path)

        let restored = harness.store.restore()
        #expect(restored?.url.path == harness.directory.standardizedFileURL.path)
    }

    @Test func restoreReturnsNilForUnsetStore() throws {
        let harness = try makeHarness()
        #expect(harness.store.restore() == nil)
    }

    @Test func clearRemovesAuthorization() throws {
        let harness = try makeHarness()
        _ = try harness.store.authorize(harness.directory)
        #expect(harness.store.restore() != nil)

        harness.store.clear()

        #expect(harness.store.restore() == nil)
    }

    @Test func restoreDiscardsCorruptData() throws {
        let harness = try makeHarness()
        harness.defaults.set(Data("not a bookmark".utf8), forKey: "test.authorized-project")

        #expect(harness.store.restore() == nil)
        #expect(harness.defaults.data(forKey: "test.authorized-project") == nil)
    }
}
