import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// In-app settings page shown inside the main window: a back row and
/// searchable icon nav column on the left, the selected section's
/// card-grouped content on the right. Only covers capabilities the current
/// Runtime contract actually exposes.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var navigation = SettingsNavigation()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        model.closeSettingsPage()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    Spacer()
                }
                List(selection: $navigation.selection) {
                    ForEach(navigation.filteredSections) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                .listStyle(.sidebar)
            }
            .searchable(text: $navigation.query, placement: .sidebar, prompt: "搜索设置…")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            switch navigation.selection {
            case .general: GeneralSettingsDetail(model: model)
            case .providers: ProvidersSettingsDetail(model: model)
            case .data: DataSettingsDetail(model: model)
            case .migration: MigrationSettingsDetail(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "卸载 Pi Agent 并保留数据？",
            isPresented: $model.showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("将 Pi Agent.app 移入废纸篓", role: .destructive) { model.confirmUninstallKeepingData() }
            Button("取消", role: .cancel) { model.cancelUninstallKeepingData() }
        } message: {
            Text("Pi Agent 会确认没有活跃会话，退出后仅将经过 bundle ID 验证的自身应用移入废纸篓。Pi Agent 数据、项目文件夹、旧版 PI WEB 状态和 Keychain 凭据都会保留。")
        }
        .sheet(isPresented: $model.showDataEraseConfirmation, onDismiss: model.cancelDataErase) {
            NativeDataEraseSheet(model: model)
        }
        .confirmationDialog(
            "回滚最近一次项目迁移？",
            isPresented: $model.showLegacyProjectMigrationRollbackConfirmation,
            titleVisibility: .visible
        ) {
            Button("回滚原生书签", role: .destructive) { model.rollbackLegacyProjectMigration() }
            Button("取消", role: .cancel) { model.cancelLegacyProjectMigrationRollback() }
        } message: {
            Text("此操作仅移除该迁移新建的原生项目库书签，不会改动旧版 PI WEB 的 projects.json、所选目录、会话、凭据或手动添加的项目。")
        }
        .confirmationDialog(
            "将旧版凭据迁移到 Keychain？",
            isPresented: $model.showLegacyAuthMigrationConfirmation,
            titleVisibility: .visible
        ) {
            Button("迁移到 Keychain") { model.migrateLegacyAuth() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅复制列出的提供商。现有 Keychain 凭据不会被覆盖，旧的 auth.json 保持不变。")
        }
    }
}

// MARK: - Navigation

enum SettingsSectionID: String, CaseIterable, Identifiable {
    case general, providers, data, migration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .providers: return "提供商"
        case .data: return "数据"
        case .migration: return "迁移"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gear"
        case .providers: return "key"
        case .data: return "externaldrive"
        case .migration: return "arrow.triangle.2.circlepath"
        }
    }
}

/// Selection and search live in an ObservableObject because the build
/// toolchain cannot expand the macro-based `@State` property wrapper.
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSectionID = .general
    @Published var query = ""

    var filteredSections: [SettingsSectionID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SettingsSectionID.allCases }
        return SettingsSectionID.allCases.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
}

// MARK: - Detail scaffolding

/// One settings page: large title followed by headed card groups.
private struct SettingsDetail<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text(title)
                    .font(.title.bold())
                content
            }
            .padding(Theme.Spacing.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A bold group heading above a card.
private struct SettingsGroup<Content: View>: View {
    let heading: String?
    let content: Content

    init(_ heading: String? = nil, @ViewBuilder content: () -> Content) {
        self.heading = heading
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let heading {
                Text(heading)
                    .font(.headline)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                content
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .subtleCard()
        }
    }
}

/// A card row: bold label with an optional gray description, trailing control.
private struct SettingsRow<Control: View>: View {
    let title: String
    var description: String?
    let control: Control

    init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.large)
            control
        }
    }
}

// MARK: - General

private struct GeneralSettingsDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsDetail("常规") {
            SettingsGroup("Runtime") {
                RuntimeStatusRow(model: model)
            }
            SettingsGroup("项目") {
                SettingsRow("当前项目", description: model.projectPath) {
                    Button("选择…") { model.openProject() }
                }
                Divider()
                SettingsRow("Runtime 访问权限", description: model.projectRuntimeAuthorizationLabel) {
                    EmptyView()
                }
            }
            if let taskNotifications = model.taskNotifications {
                SettingsGroup("通知") {
                    NativeTaskNotificationRows(coordinator: taskNotifications)
                }
            }
            SettingsGroup("支持") {
                SettingsRow(
                    "支持报告",
                    description: "经过脱敏的 Runtime 元数据，不包含提示词、对话记录、工作区内容和凭据。"
                ) {
                    Button("导出…") { model.exportSupportReport() }
                        .disabled(model.isSupportReportExporting)
                }
                if model.isSupportReportExporting {
                    ProgressView("正在收集 Runtime 元数据…")
                } else if let message = model.supportReportMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("已将") ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Visual runtime status: colored state dot, state text, socket path in mono,
/// and a reconnect action.
private struct RuntimeStatusRow: View {
    @ObservedObject var model: AppModel

    private var statusColor: SwiftUI.Color {
        switch model.runtimeState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.runtimeState {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnected: return "已断开"
        case .failed: return "不可用"
        }
    }

    var body: some View {
        SettingsRow("Runtime", description: model.runtimeLabel) {
            HStack(spacing: Theme.Spacing.medium) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(statusText)
                    .foregroundStyle(.secondary)
                Button("重新连接") { model.refreshRuntime() }
                    .disabled(model.isLoading)
            }
        }
        .accessibilityElement(children: .combine)
        Divider()
        HStack {
            Text("套接字")
                .font(.body.weight(.medium))
            Spacer()
            Text(model.runtimeClientSocketDescription)
                .font(Theme.codeCaptionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct NativeTaskNotificationRows: View {
    @ObservedObject var coordinator: NativeTaskNotificationCoordinator

    var body: some View {
        SettingsRow("任务通知", description: "任务需要处理时提醒。") {
            Toggle(
                "",
                isOn: Binding(
                    get: { coordinator.enabled },
                    set: { coordinator.setEnabled($0) }
                )
            )
            .labelsHidden()
        }
        Divider()
        SettingsRow("macOS 权限", description: coordinator.authorizationLabel) {
            EmptyView()
        }
        if !coordinator.enabled {
            Text("Runtime 会继续运行，但 Pi Agent 不会创建 macOS 提醒。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Providers

private struct ProvidersSettingsDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsDetail("提供商") {
            SettingsGroup {
                if model.isAuthLoading {
                    ProgressView("正在加载提供商状态…")
                } else if model.authProviders.isEmpty {
                    Text("此 Runtime 没有可用的交互式提供商配置。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.authProviders.enumerated()), id: \.element.displayID) { index, provider in
                        if index > 0 { Divider() }
                        ProviderRow(provider: provider) { model.startAuthFlow(provider) }
                    }
                }
                if let error = model.authErrorMessage {
                    Divider()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            SettingsGroup {
                SettingsRow("提供商状态", description: "从 Runtime 重新加载登录状态。") {
                    Button("刷新") { model.refreshAuthProviders() }
                        .disabled(model.isAuthLoading || !model.canUseProjectRuntime)
                }
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: RuntimeAuthProvider
    let configure: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: provider.status.configured ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(provider.status.configured ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(provider.name)
                        .font(.body.weight(.medium))
                    Text(authTypeLabel(provider.authType))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Text(providerStatusLabel(provider))
                    .font(.caption)
                    .foregroundStyle(provider.status.configured ? Color.green : Color.secondary)
            }
            Spacer()
            Button(provider.status.configured ? "重新配置…" : "配置…", action: configure)
        }
    }

    private func authTypeLabel(_ authType: String) -> String {
        switch authType.lowercased() {
        case "oauth": return "OAuth"
        case "apikey", "api-key", "api_key": return "API key"
        default: return authType
        }
    }
}

// MARK: - Data

private struct DataSettingsDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsDetail("数据") {
            SettingsGroup("安装") {
                SettingsRow("Pi Agent 数据", description: model.nativeAppDataPath) {
                    Button("在 Finder 中显示") { model.revealNativeAppData() }
                }
            }
            SettingsGroup("维护") {
                SettingsRow("卸载 Pi Agent", description: "仅将 Pi Agent.app 移入废纸篓，数据、项目和凭据都会保留。") {
                    Button("卸载…", role: .destructive) {
                        model.requestUninstallKeepingData()
                    }
                    .disabled(model.isUninstallPreparing)
                }
                if model.isUninstallPreparing {
                    ProgressView("正在检查活跃会话…")
                } else if let message = model.uninstallMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                SettingsRow("抹掉所有 Pi Agent 数据", description: "将 Pi Agent 数据移入废纸篓并清除 Keychain 凭据，应用和你的项目都会保留。") {
                    Button("抹掉…", role: .destructive) {
                        model.requestDataErase()
                    }
                    .disabled(model.isDataErasePreparing)
                }
                if model.isDataErasePreparing {
                    ProgressView("正在检查活跃会话…")
                } else if let message = model.dataEraseMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
        }
    }
}

// MARK: - Migration

private struct MigrationSettingsDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsDetail("迁移") {
            SettingsGroup("旧版数据清单") {
                Text("旧版 PI WEB 状态的只读清单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isLegacyMigrationOverviewLoading {
                    ProgressView("正在检查旧版 PI WEB 状态…")
                } else if let overview = model.legacyMigrationOverview {
                    LabeledContent("旧版数据", value: overview.legacyDataDir)
                    ForEach(overview.items) { item in
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(legacyMigrationItemLabel(item.id), value: legacyMigrationActionLabel(item.action))
                            Text(item.source)
                                .font(Theme.codeCaptionFont)
                                .foregroundStyle(.secondary)
                            if let count = item.itemCount {
                                Text("发现 \(count) 个项目")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let issue = item.issue {
                                Text(issue)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let error = model.legacyMigrationOverviewError {
                    Text("无法检查旧版 PI WEB 状态：\(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("检查旧版迁移") { model.refreshLegacyMigrationOverview() }
                        .disabled(model.isLegacyMigrationOverviewLoading)
                }
            }
            SettingsGroup("旧版项目") {
                if model.isLegacyProjectPreviewLoading {
                    ProgressView("正在检查旧版项目…")
                } else if let preview = model.legacyProjectPreview {
                    if let issue = preview.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    else if preview.candidates.isEmpty { Text(preview.sourceExists ? "未找到有效的旧版项目。" : "未找到旧版 projects.json。").foregroundStyle(.secondary) }
                    else {
                        Text("请重新选择每个原始目录以创建新的 macOS 书签，仅凭 PI WEB 路径无法授予 Pi Agent 访问权限。").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(preview.candidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider() }
                            HStack { VStack(alignment: .leading) { Text(candidate.name).font(.body.weight(.medium)); Text(candidate.path).font(Theme.codeCaptionFont).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Button("重新授权…") { model.reauthorizeLegacyProject(candidate) } }
                        }
                    }
                }
                if model.isLegacyProjectMigrationInFlight {
                    ProgressView("正在更新原生项目迁移…")
                } else if let migration = model.legacyProjectMigration {
                    Divider()
                    LabeledContent("最近迁移", value: migration.state.rawValue)
                    if migration.rollbackEligible {
                        Button("回滚最近一次项目迁移…", role: .destructive) {
                            model.requestLegacyProjectMigrationRollback()
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("检查旧版项目") { model.refreshLegacyProjectPreview() }
                        .disabled(model.isLegacyProjectPreviewLoading || model.isLegacyProjectMigrationInFlight)
                }
            }
            SettingsGroup("旧版凭据") {
                Text("将兼容的凭据从 auth.json 复制到此 Mac 的 Keychain，源文件保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isLegacyAuthMigrationLoading {
                    ProgressView("正在检查旧版凭据…")
                } else if let preview = model.legacyAuthMigrationPreview {
                    if preview.credentials.isEmpty {
                        Text(preview.issue ?? "未找到旧版凭据。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(preview.credentials) { credential in
                            LabeledContent(credential.providerId, value: credential.type == "oauth" ? "OAuth" : "API key")
                            if credential.status != "ready" {
                                Text("已存在于 Keychain，迁移不会覆盖。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let issue = preview.issue {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("迁移到 Keychain…") { model.requestLegacyAuthMigration() }
                            .disabled(!preview.eligible)
                    }
                } else {
                    Text("此 Runtime 未报告旧版凭据迁移能力。")
                        .foregroundStyle(.secondary)
                }
                if let migration = model.legacyAuthMigration {
                    Divider()
                    LabeledContent("最近迁移", value: migration.state)
                    if migration.rollbackEligible {
                        Button("回滚最近迁移", role: .destructive) { model.rollbackLegacyAuthMigration() }
                    }
                }
                HStack {
                    Spacer()
                    Button("检查旧版凭据") { model.refreshLegacyAuthMigrationPreview() }
                        .disabled(model.isLegacyAuthMigrationLoading || !model.canUseProjectRuntime)
                }
            }
        }
    }
}

private func legacyMigrationItemLabel(_ id: String) -> String {
    switch id {
    case "projects": return "项目"
    case "credentials": return "提供商凭据"
    case "archived-sessions": return "已归档对话"
    case "machines": return "远程机器"
    case "unread": return "未读状态"
    default: return id
    }
}

private func legacyMigrationActionLabel(_ action: String) -> String {
    switch action {
    case "reauthorize-projects": return "在项目中重新授权"
    case "migrate-to-keychain": return "迁移到 Keychain"
    case "copied-and-retained": return "已复制，源文件保留"
    case "retained": return "已保留，暂无原生目标"
    default: return action
    }
}

private func providerStatusLabel(_ provider: RuntimeAuthProvider) -> String {
    guard provider.status.configured else { return "未配置" }
    if let label = provider.status.label, !label.isEmpty { return label }
    if let source = provider.status.source, !source.isEmpty { return "已通过 \(source) 配置" }
    return "已配置"
}
