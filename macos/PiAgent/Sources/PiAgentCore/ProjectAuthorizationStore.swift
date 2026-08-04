import Foundation

/// App-owned persistence for the project directory chosen in the native UI.
///
/// The Runtime receives only the resolved project path through its existing
/// command contract. This store never writes PI WEB's project/session state and
/// is deliberately small enough to migrate to a stricter sandboxed helper.
public final class ProjectAuthorizationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.realchendahuang.pi-agent.authorized-project"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func restore() -> ProjectAccess? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ).standardizedFileURL
            guard url.hasDirectoryPath else {
                defaults.removeObject(forKey: key)
                return nil
            }
            let access = ProjectAccess(url: url)
            if stale { try persist(url) }
            return access
        } catch {
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    public func authorize(_ url: URL) throws -> ProjectAccess {
        let directory = url.standardizedFileURL
        guard directory.hasDirectoryPath else {
            throw ProjectAuthorizationError.notDirectory(directory.path)
        }
        try persist(directory)
        return ProjectAccess(url: directory)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private func persist(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key)
    }
}

/// Holds the security-scoped access lease for the lifetime of an active native
/// project selection. Outside App Sandbox `startAccessing…` can return false;
/// the resolved URL remains usable in the current unsandboxed distribution.
public final class ProjectAccess: @unchecked Sendable {
    public let url: URL
    private let holdsSecurityScope: Bool

    fileprivate init(url: URL) {
        self.url = url
        holdsSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if holdsSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

public enum ProjectAuthorizationError: LocalizedError, Equatable, Sendable {
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .notDirectory(path):
            return "Pi Agent can only authorize a project directory: \(path)"
        }
    }
}
