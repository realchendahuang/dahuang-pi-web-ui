import Foundation

/// The App-owned, bookmark-backed project library. `displayPath` is never a
/// runtime capability: it is only a user-visible label for a stored bookmark.
public struct NativeProjectBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let displayPath: String
    public let bookmarkData: Data
    public let addedAt: Date
    public let lastOpenedAt: Date
}

/// Keeps the native project's own bookmark catalog separate from PI WEB's
/// historical `projects.json`. Runtime receives a path only after the user
/// activates a record and the App sends `authorize-project` over its contract.
public final class NativeProjectCatalog: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.realchendahuang.pi-agent.native-project-catalog",
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    public func list() -> [NativeProjectBookmark] {
        (try? read())?.sorted { $0.lastOpenedAt > $1.lastOpenedAt } ?? []
    }

    public func rememberAndAccess(_ url: URL) throws -> (record: NativeProjectBookmark, access: ProjectAccess) {
        let directory = url.standardizedFileURL
        guard directory.hasDirectoryPath else { throw ProjectAuthorizationError.notDirectory(directory.path) }
        let data = try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var records = try read()
        let current = now()
        let previous = records.first { $0.displayPath == directory.path }
        let record = NativeProjectBookmark(
            id: previous?.id ?? UUID().uuidString,
            displayName: directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent,
            displayPath: directory.path,
            bookmarkData: data,
            addedAt: previous?.addedAt ?? current,
            lastOpenedAt: current
        )
        records.removeAll { $0.id == record.id }
        records.append(record)
        try write(records)
        return (record, ProjectAccess(url: directory))
    }

    public func access(_ record: NativeProjectBookmark) throws -> ProjectAccess {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: record.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).standardizedFileURL
        guard url.hasDirectoryPath else { throw ProjectAuthorizationError.notDirectory(url.path) }
        if stale { _ = try rememberAndAccess(url) }
        return ProjectAccess(url: url)
    }

    public func remove(id: String) throws {
        var records = try read()
        records.removeAll { $0.id == id }
        try write(records)
    }

    private func read() throws -> [NativeProjectBookmark] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([NativeProjectBookmark].self, from: data)
    }

    private func write(_ records: [NativeProjectBookmark]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(records), forKey: key)
    }
}
