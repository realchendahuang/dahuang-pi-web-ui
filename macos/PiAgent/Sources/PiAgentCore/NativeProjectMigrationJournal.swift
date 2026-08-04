import Foundation

/// Durable, App-owned evidence for an explicitly re-authorized legacy PI WEB
/// project. This is intentionally a bookmark-library journal, not a copy of
/// PI WEB's `projects.json`: source metadata never becomes filesystem access.
public struct NativeProjectMigrationRecord: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case verified
        case rollingBack
        case rolledBack
    }

    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// The legacy project ID is only an audit reference. It is never used
        /// as a Runtime capability or as a file path authority.
        public let legacyProjectID: String
        public let legacyPath: String
        public let nativeProjectID: String
        public let nativeProjectPath: String
        public let created: Bool

        public var id: String { legacyProjectID }

        public init(
            legacyProjectID: String,
            legacyPath: String,
            nativeProjectID: String,
            nativeProjectPath: String,
            created: Bool
        ) {
            self.legacyProjectID = legacyProjectID
            self.legacyPath = legacyPath
            self.nativeProjectID = nativeProjectID
            self.nativeProjectPath = nativeProjectPath
            self.created = created
        }
    }

    public let id: String
    public let createdAt: Date
    public var completedAt: Date?
    public var state: State
    public let entries: [Entry]

    public init(
        id: String,
        createdAt: Date,
        completedAt: Date? = nil,
        state: State,
        entries: [Entry]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.state = state
        self.entries = entries
    }

    public var rollbackEligible: Bool { state == .verified }
}

public enum NativeProjectMigrationError: LocalizedError, Equatable, Sendable {
    case selectedPathMismatch(expectedPath: String, actualPath: String)
    case catalogReadbackMissing(id: String)
    case catalogReadbackMismatch(id: String, expectedPath: String, actualPath: String)
    case noRollbackEligibleMigration
    case rollbackRecordMissing(id: String)
    case journalReadbackMismatch(id: String)
    case rollbackIncomplete(id: String)
    case journalWriteCompensationFailed(journalMessage: String, cleanupMessage: String)

    public var errorDescription: String? {
        switch self {
        case let .selectedPathMismatch(expectedPath, actualPath):
            return "Choose the original legacy project path exactly (expected \(expectedPath), found \(actualPath))."
        case let .catalogReadbackMissing(id):
            return "Pi Agent could not read back the newly authorized project record \(id)."
        case let .catalogReadbackMismatch(id, expectedPath, actualPath):
            return "Project record \(id) no longer matches the migration path (expected \(expectedPath), found \(actualPath))."
        case .noRollbackEligibleMigration:
            return "There is no verified project migration available to roll back."
        case let .rollbackRecordMissing(id):
            return "The project record \(id) is no longer present, so Pi Agent will not guess what to remove."
        case let .journalReadbackMismatch(id):
            return "Pi Agent could not read back project migration journal \(id)."
        case let .rollbackIncomplete(id):
            return "Project migration \(id) needs recovery before another rollback can start."
        case let .journalWriteCompensationFailed(journalMessage, cleanupMessage):
            return "Pi Agent could not record the project migration (\(journalMessage)) and could not remove its new native bookmark (\(cleanupMessage)). Reopen Settings before making any further migration changes."
        }
    }
}

/// The journal uses the same App-owned `UserDefaults` domain as the native
/// bookmark catalog. It contains only legacy and native identifiers, paths,
/// timestamps, ownership flags and state--never bookmark bytes, project files,
/// sessions, prompts, terminal output or credentials.
public final class NativeProjectMigrationJournal: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private let beforeWrite: () throws -> Void

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.realchendahuang.pi-agent.native-project-migrations",
        now: @escaping () -> Date = Date.init,
        beforeWrite: @escaping () throws -> Void = {}
    ) {
        self.defaults = defaults
        self.key = key
        self.now = now
        self.beforeWrite = beforeWrite
    }

    public func latest() throws -> NativeProjectMigrationRecord? {
        try read().last
    }

    /// Rewrites the journal entry state before destructive work begins. This
    /// makes an interrupted rollback explicit rather than silently retrying a
    /// deletion whose ownership cannot be proved.
    public func beginRollbackLatest() throws -> NativeProjectMigrationRecord {
        var records = try read()
        guard let index = records.indices.last else {
            throw NativeProjectMigrationError.noRollbackEligibleMigration
        }
        guard records[index].state == .verified else {
            if records[index].state == .rollingBack {
                throw NativeProjectMigrationError.rollbackIncomplete(id: records[index].id)
            }
            throw NativeProjectMigrationError.noRollbackEligibleMigration
        }
        records[index].state = .rollingBack
        try write(records)
        guard try read().last?.state == .rollingBack else {
            throw NativeProjectMigrationError.journalReadbackMismatch(id: records[index].id)
        }
        return records[index]
    }

    public func appendVerified(
        legacyProjectID: String,
        legacyPath: String,
        activation: NativeProjectCatalogActivation,
        catalog: NativeProjectCatalog
    ) throws -> NativeProjectMigrationRecord {
        let expectedPath = URL(fileURLWithPath: legacyPath).standardizedFileURL.path
        let actualPath = activation.record.displayPath
        guard expectedPath == actualPath else {
            throw NativeProjectMigrationError.selectedPathMismatch(expectedPath: expectedPath, actualPath: actualPath)
        }
        guard let readback = try catalog.record(id: activation.record.id) else {
            throw NativeProjectMigrationError.catalogReadbackMissing(id: activation.record.id)
        }
        guard readback.id == activation.record.id, readback.displayPath == actualPath else {
            throw NativeProjectMigrationError.catalogReadbackMismatch(
                id: activation.record.id,
                expectedPath: actualPath,
                actualPath: readback.displayPath
            )
        }

        let record = NativeProjectMigrationRecord(
            id: UUID().uuidString,
            createdAt: now(),
            state: .verified,
            entries: [
                .init(
                    legacyProjectID: legacyProjectID,
                    legacyPath: expectedPath,
                    nativeProjectID: activation.record.id,
                    nativeProjectPath: actualPath,
                    created: activation.created
                ),
            ]
        )
        var records = try read()
        records.append(record)
        try write(records)
        guard let readback = try read().last,
              readback.id == record.id,
              readback.state == .verified,
              readback.entries == record.entries
        else {
            throw NativeProjectMigrationError.journalReadbackMismatch(id: record.id)
        }
        return readback
    }

    public func completeRollback(_ record: NativeProjectMigrationRecord) throws -> NativeProjectMigrationRecord {
        var records = try read()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            throw NativeProjectMigrationError.journalReadbackMismatch(id: record.id)
        }
        guard records[index].state == .rollingBack else {
            throw NativeProjectMigrationError.rollbackIncomplete(id: record.id)
        }
        records[index].state = .rolledBack
        records[index].completedAt = now()
        try write(records)
        guard let readback = try read().first(where: { $0.id == record.id }),
              readback.state == .rolledBack,
              readback.completedAt != nil
        else {
            throw NativeProjectMigrationError.journalReadbackMismatch(id: record.id)
        }
        return readback
    }

    private func read() throws -> [NativeProjectMigrationRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([NativeProjectMigrationRecord].self, from: data)
    }

    private func write(_ records: [NativeProjectMigrationRecord]) throws {
        try beforeWrite()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(records), forKey: key)
    }
}

/// Coordinates an explicit Finder reauthorization with catalog readback and a
/// durable journal entry. The only compensation path removes the exact record
/// it just created; it never mutates legacy PI WEB state or preexisting/manual
/// native projects.
public final class NativeLegacyProjectMigrationCoordinator: @unchecked Sendable {
    private let catalog: NativeProjectCatalog
    private let journal: NativeProjectMigrationJournal

    public init(catalog: NativeProjectCatalog, journal: NativeProjectMigrationJournal) {
        self.catalog = catalog
        self.journal = journal
    }

    public func migrate(
        legacyProjectID: String,
        legacyPath: String,
        selectedURL: URL
    ) throws -> NativeProjectMigrationRecord {
        let expectedPath = URL(fileURLWithPath: legacyPath).standardizedFileURL.path
        let selectedPath = selectedURL.standardizedFileURL.path
        guard expectedPath == selectedPath else {
            throw NativeProjectMigrationError.selectedPathMismatch(expectedPath: expectedPath, actualPath: selectedPath)
        }
        let activation = try catalog.rememberAndAccess(selectedURL)
        do {
            return try journal.appendVerified(
                legacyProjectID: legacyProjectID,
                legacyPath: expectedPath,
                activation: activation,
                catalog: catalog
            )
        } catch {
            let journalError = error
            guard activation.created else { throw journalError }
            do {
                guard try catalog.remove(id: activation.record.id, matchingDisplayPath: activation.record.displayPath) else {
                    throw NativeProjectMigrationError.catalogReadbackMissing(id: activation.record.id)
                }
                guard try catalog.record(id: activation.record.id) == nil else {
                    throw NativeProjectMigrationError.catalogReadbackMissing(id: activation.record.id)
                }
            } catch {
                throw NativeProjectMigrationError.journalWriteCompensationFailed(
                    journalMessage: journalError.localizedDescription,
                    cleanupMessage: error.localizedDescription
                )
            }
            throw journalError
        }
    }

    public func rollbackLatest() throws -> NativeProjectMigrationRecord {
        let record = try journal.beginRollbackLatest()
        for entry in record.entries where entry.created {
            guard let current = try catalog.record(id: entry.nativeProjectID) else {
                throw NativeProjectMigrationError.rollbackRecordMissing(id: entry.nativeProjectID)
            }
            guard current.displayPath == entry.nativeProjectPath else {
                throw NativeProjectMigrationError.catalogReadbackMismatch(
                    id: entry.nativeProjectID,
                    expectedPath: entry.nativeProjectPath,
                    actualPath: current.displayPath
                )
            }
            guard try catalog.remove(id: entry.nativeProjectID, matchingDisplayPath: entry.nativeProjectPath) else {
                throw NativeProjectMigrationError.rollbackRecordMissing(id: entry.nativeProjectID)
            }
            guard try catalog.record(id: entry.nativeProjectID) == nil else {
                throw NativeProjectMigrationError.catalogReadbackMismatch(
                    id: entry.nativeProjectID,
                    expectedPath: "removed record",
                    actualPath: current.displayPath
                )
            }
        }
        return try journal.completeRollback(record)
    }

    public func latestMigration() throws -> NativeProjectMigrationRecord? {
        try journal.latest()
    }
}
