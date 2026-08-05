import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension AppModel {
    func exportSupportReport() {
        guard !isSupportReportExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Pi-Agent-Support-Report.json"
        panel.message = "报告仅包含 App 与 Runtime 的版本和状态元数据，绝不包含提示词、对话记录、项目文件内容、凭据或能力令牌。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isSupportReportExporting = true
        supportReportMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let health: RuntimeHealth?
            let hello: RuntimeHello?
            var errors: [String] = []
            do { health = try await self.runtimeClient.health() }
            catch { health = nil; errors.append("health: \(error.localizedDescription)") }
            if let helloClient = self.runtimeClient as? any RuntimeHelloClient {
                do { hello = try await helloClient.hello() }
                catch { hello = nil; errors.append("hello: \(error.localizedDescription)") }
            } else {
                hello = nil
                errors.append("hello: unavailable from this Runtime client")
            }
            let bundle = Bundle.main
            let report = NativeSupportReport(
                application: .init(
                    bundleIdentifier: bundle.bundleIdentifier,
                    version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    bundlePath: bundle.bundleURL.path
                ),
                runtime: .init(
                    socket: self.runtimeClientSocketDescription,
                    connectionState: self.runtimeLabel,
                    health: health,
                    hello: hello,
                    diagnosticError: errors.isEmpty ? nil : errors.joined(separator: "; ")
                ),
                project: .init(path: self.projectPath, authorization: self.projectRuntimeAuthorizationLabel),
                providers: self.authProviders.map {
                    .init(id: $0.id, authType: $0.authType, configured: $0.status.configured, source: $0.status.source)
                }
            )
            do {
                try report.encodedJSON().write(to: url, options: .atomic)
                self.supportReportMessage = "已将脱敏报告保存到 \(url.path)"
            } catch {
                self.supportReportMessage = "无法保存支持报告：\(error.localizedDescription)"
            }
            self.isSupportReportExporting = false
        }
    }

    /// Opens only the App-owned data folder. Project checkouts, legacy PI WEB
    /// state and Keychain credentials are intentionally outside this operation.
    func revealNativeAppData() {
        let dataURL = URL(fileURLWithPath: nativeAppDataPath, isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dataURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dataURL])
        } else {
            NSWorkspace.shared.open(dataURL.deletingLastPathComponent())
        }
    }

    func requestUninstallKeepingData() {
        guard !isUninstallPreparing, !maintenanceHelperLaunched else { return }
        guard runtimeSupervisor != nil else {
            uninstallMessage = "仅当使用 Pi Agent.app 捆绑的 Runtime 时才能自动卸载。此连接为外部连接，Pi Agent 不会停止或移除它。"
            return
        }
        do {
            let bundleURL = Bundle.main.bundleURL
            let helperURL = bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent(NativeAppUninstallPlan.helperName)
            uninstallPlan = try NativeAppUninstallPlan.prepare(
                appBundleURL: bundleURL,
                helperURL: helperURL,
                waitForProcessID: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            uninstallMessage = error.localizedDescription
            return
        }

        isUninstallPreparing = true
        uninstallMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.runtimeClient.health()
                guard health.activeSessions == 0 else {
                    throw RuntimeClientError.serverError(409, "请先结束或停止 \(health.activeSessions) 个活跃会话，再卸载 Pi Agent。")
                }
                self.isUninstallPreparing = false
                self.showUninstallConfirmation = true
            } catch {
                self.isUninstallPreparing = false
                self.uninstallMessage = "Pi Agent 未能开始卸载：\(error.localizedDescription)"
            }
        }
    }

    func cancelUninstallKeepingData() {
        showUninstallConfirmation = false
        uninstallPlan = nil
    }

    func confirmUninstallKeepingData() {
        guard let uninstallPlan, !isUninstallPreparing, !maintenanceHelperLaunched else { return }
        showUninstallConfirmation = false
        isUninstallPreparing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.runtimeClient.health()
                guard health.activeSessions == 0 else {
                    throw RuntimeClientError.serverError(409, "卸载前有会话开始运行。Pi Agent 未改动应用包。")
                }
                let process = Process()
                process.executableURL = uninstallPlan.helperURL
                process.arguments = uninstallPlan.helperArguments
                try process.run()
                self.maintenanceHelperLaunched = true
                self.isUninstallPreparing = false
                NSApp.terminate(nil)
            } catch {
                self.isUninstallPreparing = false
                self.uninstallMessage = "Pi Agent 未能开始卸载：\(error.localizedDescription)"
            }
        }
    }

    func requestDataErase() {
        guard !isDataErasePreparing, !maintenanceHelperLaunched else { return }
        guard runtimeSupervisor != nil else {
            dataEraseMessage = "仅当使用 Pi Agent.app 捆绑的 Runtime 时才能自动抹掉数据。此连接为外部连接，Pi Agent 不会移除任何数据。"
            return
        }
        do {
            let bundleURL = Bundle.main.bundleURL
            let helperURL = bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent(NativeAppDataErasePlan.helperName)
            dataErasePlan = try NativeAppDataErasePlan.prepare(
                appBundleURL: bundleURL,
                helperURL: helperURL,
                waitForProcessID: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            dataEraseMessage = error.localizedDescription
            return
        }

        isDataErasePreparing = true
        dataEraseMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.runtimeClient.health()
                guard health.activeSessions == 0 else {
                    throw RuntimeClientError.serverError(409, "有会话正在运行。Pi Agent 未改动任何数据。")
                }
                self.isDataErasePreparing = false
                self.dataEraseConfirmationText = ""
                self.showDataEraseConfirmation = true
            } catch {
                self.isDataErasePreparing = false
                self.dataEraseMessage = "Pi Agent 未能开始抹掉数据：\(error.localizedDescription)"
            }
        }
    }

    func cancelDataErase() {
        showDataEraseConfirmation = false
        dataEraseConfirmationText = ""
        dataErasePlan = nil
    }

    func confirmDataErase() {
        guard let dataErasePlan,
              canConfirmDataErase,
              !isDataErasePreparing,
              !maintenanceHelperLaunched
        else { return }
        showDataEraseConfirmation = false
        isDataErasePreparing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.runtimeClient.health()
                guard health.activeSessions == 0 else {
                    throw RuntimeClientError.serverError(409, "抹掉数据前有会话开始运行。Pi Agent 未改动任何数据。")
                }
                let process = Process()
                process.executableURL = dataErasePlan.helperURL
                process.arguments = dataErasePlan.helperArguments
                try process.run()
                self.maintenanceHelperLaunched = true
                self.isDataErasePreparing = false
                NSApp.terminate(nil)
            } catch {
                self.isDataErasePreparing = false
                self.dataEraseMessage = "Pi Agent 未能开始抹掉数据：\(error.localizedDescription)"
            }
        }
    }

    /// Inspection is read-only and its projection contains provider/type only.
}
