import Darwin
import Foundation
import PiAgentCore

@main
struct PiAgentUninstaller {
    private static let maximumWaitSeconds: TimeInterval = 120

    static func main() {
        do {
            let plan = try parsePlan(arguments: Array(CommandLine.arguments.dropFirst()))
            try waitForParentToExit(plan.waitForProcessID)
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: plan.appBundleURL, resultingItemURL: &trashedURL)
                let response = UninstallResponse(
                    removedAppPath: plan.appBundleURL.path,
                    trashPath: trashedURL?.path,
                    retainedDataPath: plan.retainedDataURL.path
                )
                try write(response)
            } catch {
                throw NativeAppMaintenanceError.moveToTrashFailed(error.localizedDescription)
            }
        } catch {
            fputs("Pi Agent uninstall failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func parsePlan(arguments: [String]) throws -> NativeAppUninstallPlan {
        guard arguments.count == 5,
              arguments[0] == "--uninstall-when-parent-exits",
              arguments[1] == "--wait-for-pid",
              let pid = Int32(arguments[2]),
              arguments[3] == "--app-path"
        else { throw NativeAppMaintenanceError.invalidAppBundle("invalid uninstall request") }
        return try NativeAppUninstallPlan.prepare(
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

    private static func write(_ response: UninstallResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(response))
    }
}

private struct UninstallResponse: Encodable {
    let removedAppPath: String
    let trashPath: String?
    let retainedDataPath: String
}
