import Foundation

/// A deliberately narrow uninstall hand-off. The native App may remove its
/// own bundle only after it has stopped its Runtime and exited; project state,
/// bookmarks, migration journals and Keychain credentials remain untouched.
public struct NativeAppUninstallPlan: Equatable, Sendable {
    public static let expectedBundleIdentifier = "com.realchendahuang.pi-agent"
    public static let expectedBundleName = "Pi Agent.app"
    public static let helperName = "PiAgentUninstaller"

    public let appBundleURL: URL
    public let helperURL: URL
    public let waitForProcessID: Int32
    public let retainedDataURL: URL

    public init(
        appBundleURL: URL,
        helperURL: URL,
        waitForProcessID: Int32,
        retainedDataURL: URL
    ) {
        self.appBundleURL = appBundleURL
        self.helperURL = helperURL
        self.waitForProcessID = waitForProcessID
        self.retainedDataURL = retainedDataURL
    }

    public var helperArguments: [String] {
        [
            "--uninstall-when-parent-exits",
            "--wait-for-pid", String(waitForProcessID),
            "--app-path", appBundleURL.path,
        ]
    }

    public static func prepare(
        appBundleURL: URL,
        helperURL: URL,
        waitForProcessID: Int32,
        fileManager: FileManager = .default
    ) throws -> NativeAppUninstallPlan {
        let target = try NativeAppMaintenanceTarget.verify(
            appBundleURL: appBundleURL,
            helperURL: helperURL,
            helperName: helperName,
            waitForProcessID: waitForProcessID,
            fileManager: fileManager
        )

        let retainedDataURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pi Agent", isDirectory: true)
        return NativeAppUninstallPlan(
            appBundleURL: target.appBundleURL,
            helperURL: target.helperURL,
            waitForProcessID: waitForProcessID,
            retainedDataURL: retainedDataURL
        )
    }
}

/// A deliberately explicit full reset hand-off. The helper is allowed to move
/// only Pi Agent's own Application Support directory to Trash, remove this
/// App's preferences domain, and delete credentials under Pi Agent's exact
/// Keychain service. It never receives a project path or a legacy PI WEB path.
public struct NativeAppDataErasePlan: Equatable, Sendable {
    public static let helperName = "PiAgentDataEraser"
    public static let preferencesDomain = NativeAppUninstallPlan.expectedBundleIdentifier

    public let appBundleURL: URL
    public let helperURL: URL
    public let waitForProcessID: Int32
    public let dataDirectoryURL: URL

    public init(
        appBundleURL: URL,
        helperURL: URL,
        waitForProcessID: Int32,
        dataDirectoryURL: URL
    ) {
        self.appBundleURL = appBundleURL
        self.helperURL = helperURL
        self.waitForProcessID = waitForProcessID
        self.dataDirectoryURL = dataDirectoryURL
    }

    public var helperArguments: [String] {
        [
            "--erase-data-when-parent-exits",
            "--wait-for-pid", String(waitForProcessID),
            "--app-path", appBundleURL.path,
        ]
    }

    public static func prepare(
        appBundleURL: URL,
        helperURL: URL,
        waitForProcessID: Int32,
        fileManager: FileManager = .default
    ) throws -> NativeAppDataErasePlan {
        let target = try NativeAppMaintenanceTarget.verify(
            appBundleURL: appBundleURL,
            helperURL: helperURL,
            helperName: helperName,
            waitForProcessID: waitForProcessID,
            fileManager: fileManager
        )
        let dataDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pi Agent", isDirectory: true)
        return NativeAppDataErasePlan(
            appBundleURL: target.appBundleURL,
            helperURL: target.helperURL,
            waitForProcessID: waitForProcessID,
            dataDirectoryURL: dataDirectoryURL
        )
    }
}

private struct NativeAppMaintenanceTarget {
    let appBundleURL: URL
    let helperURL: URL

    static func verify(
        appBundleURL: URL,
        helperURL: URL,
        helperName: String,
        waitForProcessID: Int32,
        fileManager: FileManager
    ) throws -> NativeAppMaintenanceTarget {
        guard waitForProcessID > 0 else { throw NativeAppMaintenanceError.invalidParentProcess }
        let appURL = appBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard appURL.lastPathComponent == NativeAppUninstallPlan.expectedBundleName,
              appURL.pathExtension.lowercased() == "app",
              appURL.hasDirectoryPath
        else { throw NativeAppMaintenanceError.invalidAppBundle(appURL.path) }
        guard fileManager.fileExists(atPath: appURL.path) else {
            throw NativeAppMaintenanceError.appBundleMissing(appURL.path)
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              info["CFBundleIdentifier"] as? String == NativeAppUninstallPlan.expectedBundleIdentifier
        else { throw NativeAppMaintenanceError.unexpectedBundleIdentifier(appURL.path) }

        let expectedHelperURL = appURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(helperName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let actualHelperURL = helperURL.standardizedFileURL.resolvingSymlinksInPath()
        guard actualHelperURL == expectedHelperURL,
              fileManager.isExecutableFile(atPath: actualHelperURL.path)
        else { throw NativeAppMaintenanceError.invalidHelper(actualHelperURL.path) }
        return NativeAppMaintenanceTarget(appBundleURL: appURL, helperURL: actualHelperURL)
    }
}

public enum NativeAppMaintenanceError: LocalizedError, Equatable, Sendable {
    case invalidParentProcess
    case invalidAppBundle(String)
    case appBundleMissing(String)
    case unexpectedBundleIdentifier(String)
    case invalidHelper(String)
    case parentDidNotExit(Int32)
    case moveToTrashFailed(String)
    case eraseDataMoveToTrashFailed(String)
    case eraseKeychainCredentialsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidParentProcess:
            return "Pi Agent could not establish a valid parent process for uninstall."
        case let .invalidAppBundle(path):
            return "Pi Agent will uninstall only its own Pi Agent.app bundle, not \(path)."
        case let .appBundleMissing(path):
            return "Pi Agent.app is no longer available at \(path)."
        case let .unexpectedBundleIdentifier(path):
            return "The selected app bundle is not Pi Agent: \(path)."
        case let .invalidHelper(path):
            return "Pi Agent's bundled uninstall helper is missing or invalid: \(path)."
        case let .parentDidNotExit(pid):
            return "Pi Agent did not exit in time (process \(pid)); the app bundle was left untouched."
        case let .moveToTrashFailed(message):
            return "Pi Agent could not move its app bundle to the Trash: \(message)"
        case let .eraseDataMoveToTrashFailed(message):
            return "Pi Agent could not move its local data to the Trash: \(message)"
        case let .eraseKeychainCredentialsFailed(message):
            return "Pi Agent could not erase its Keychain credentials: \(message)"
        }
    }
}
