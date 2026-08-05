import Foundation
import Testing
@testable import PiAgentCore

/// Exercises the migration journal lifecycle against an isolated UserDefaults
/// suite and a temporary project directory, without touching the real catalog.
@Suite("Native project migration journal")
struct NativeProjectMigrationJournalTests {
    private final class Harness {
        let defaults: UserDefaults
        let journal: NativeProjectMigrationJournal
        let directory: URL

        init() throws {
            let suite = "pi-agent-journal-tests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw NativeProjectMigrationError.journalReadbackMismatch(id: suite)
            }
            self.defaults = defaults
            journal = NativeProjectMigrationJournal(
                defaults: defaults,
                key: "test.migrations"
            )
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pi-agent-journal-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            if let name = defaults.volatileDomainNames.first {
                defaults.removeVolatileDomain(forName: name)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness() throws -> Harness {
        try Harness()
    }

    private func makeActivation(for harness: Harness, created: Bool = false) -> NativeProjectCatalogActivation {
        let bookmark = NativeProjectBookmark(
            id: UUID().uuidString,
            displayName: "Legacy",
            displayPath: harness.directory.path,
            bookmarkData: Data(),
            addedAt: Date(),
            lastOpenedAt: Date()
        )
        return NativeProjectCatalogActivation(
            record: bookmark,
            access: ProjectAccess(url: harness.directory),
            created: created
        )
    }

    private func appendVerified(_ harness: Harness) throws -> NativeProjectMigrationRecord {
        try harness.journal.appendVerified(
            legacyProjectID: "legacy-1",
            legacyPath: harness.directory.path,
            activation: makeActivation(for: harness),
            catalog: fakeCatalog(harness)
        )
    }

    /// A catalog fake that never creates records; the journal tests only
    /// exercise persistence, so identity comes from the activation record.
    private func fakeCatalog(_ harness: Harness) -> NativeProjectCatalog {
        NativeProjectCatalog(
            defaults: harness.defaults,
            key: "test.catalog"
        )
    }

    @Test func emptyJournalHasNoLatestMigration() throws {
        let harness = try makeHarness()
        #expect(try harness.journal.latest() == nil)
    }

    @Test func appendVerifiedRecordsMigration() throws {
        let harness = try makeHarness()
        let record = try appendVerified(harness)

        #expect(record.state == .verified)
        #expect(try harness.journal.latest()?.id == record.id)
    }

    @Test func beginRollbackMarksLatestVerifiedRecord() throws {
        let harness = try makeHarness()
        _ = try appendVerified(harness)

        let rollingBack = try harness.journal.beginRollbackLatest()

        #expect(rollingBack.state == .rollingBack)
        #expect(try harness.journal.latest()?.state == .rollingBack)
    }

    @Test func beginRollbackRejectsEmptyJournal() throws {
        let harness = try makeHarness()

        #expect(throws: NativeProjectMigrationError.self) {
            try harness.journal.beginRollbackLatest()
        }
    }

    @Test func completeRollbackRestoresVerifiedState() throws {
        let harness = try makeHarness()
        let record = try appendVerified(harness)
        _ = try harness.journal.beginRollbackLatest()

        let completed = try harness.journal.completeRollback(record)

        #expect(completed.state == .verified)
        #expect(try harness.journal.latest()?.state == .verified)
    }

    @Test func rollbackStateSurvivesReopen() throws {
        let harness = try makeHarness()
        _ = try appendVerified(harness)
        _ = try harness.journal.beginRollbackLatest()

        let reopened = NativeProjectMigrationJournal(
            defaults: harness.defaults,
            key: "test.migrations"
        )

        #expect(try reopened.latest()?.state == .rollingBack)
    }
}
