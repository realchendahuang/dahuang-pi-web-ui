import Darwin
import Foundation
import PiAgentCore
import Security

/// Executes only after the parent Pi Agent process exits. This deliberately
/// uses Trash for recoverable filesystem state instead of recursive deletion.
@main
struct PiAgentDataEraser {
    private static let maximumWaitSeconds: TimeInterval = 120
    private static let credentialService = "com.realchendahuang.pi-agent.credentials.v1"

    static func main() {
        do {
            let plan = try parsePlan(arguments: Array(CommandLine.arguments.dropFirst()))
            try waitForParentToExit(plan.waitForProcessID)
            let trashedDataPath = try moveDataToTrash(plan.dataDirectoryURL)
            erasePreferences()
            try eraseKeychainCredentials()
            try write(
                DataEraseResponse(
                    dataPath: plan.dataDirectoryURL.path,
                    trashPath: trashedDataPath,
                    preferencesDomain: NativeAppDataErasePlan.preferencesDomain,
                    credentialsErased: true
                )
            )
        } catch {
            fputs("Pi Agent data erase failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func parsePlan(arguments: [String]) throws -> NativeAppDataErasePlan {
        guard arguments.count == 5,
              arguments[0] == "--erase-data-when-parent-exits",
              arguments[1] == "--wait-for-pid",
              let pid = Int32(arguments[2]),
              arguments[3] == "--app-path"
        else { throw NativeAppMaintenanceError.invalidAppBundle("invalid data erase request") }
        return try NativeAppDataErasePlan.prepare(
            appBundleURL: URL(fileURLWithPath: arguments[4], isDirectory: true),
            helperURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            waitForProcessID: pid
        )
    }

    private static func waitForParentToExit(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(maximumWaitSeconds)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NativeAppMaintenanceError.parentDidNotExit(pid)
    }

    private static func moveDataToTrash(_ dataURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return nil }
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: dataURL, resultingItemURL: &trashedURL)
            return trashedURL?.path
        } catch {
            throw NativeAppMaintenanceError.eraseDataMoveToTrashFailed(error.localizedDescription)
        }
    }

    private static func erasePreferences() {
        UserDefaults.standard.removePersistentDomain(
            forName: NativeAppDataErasePlan.preferencesDomain
        )
        UserDefaults.standard.synchronize()
    }

    private static func eraseKeychainCredentials() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: credentialService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeAppMaintenanceError.eraseKeychainCredentialsFailed("Security status \(status)")
        }
    }

    private static func write(_ response: DataEraseResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(response))
    }
}

private struct DataEraseResponse: Encodable {
    let dataPath: String
    let trashPath: String?
    let preferencesDomain: String
    let credentialsErased: Bool
}
