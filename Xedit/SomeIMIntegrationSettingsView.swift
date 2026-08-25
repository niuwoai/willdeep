//
//  SomeIMIntegrationSettingsView.swift
//  WillDeep
//
//  some.im 集成的设置界面：登录与浏览器授权、模型选择、余额与套餐展示。
//
//  从 SomeIMIntegration.swift 抽出来：那个文件逼近 complexity_guard 的
//  3000 行硬上限，界面层与存储层、客户端层本就分属三层。
//

import Foundation
import AppKit
import SwiftUI

struct SomeIMIntegrationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settingsNavigation = EditorSettingsNavigation.shared
    @State private var settings = SomeIMIntegrationStore.loadSettings()
    @State private var apiKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var account = SomeIMIntegrationStore.loadAuthenticatedAccount()
    @State private var fetchedModels: [SomeIMModel] = []
    @State private var isFetching = false
    @State private var isRefreshingBalance = false
    @State private var browserLoginRequest: SomeIMBrowserLoginRequest?
    @State private var browserLoginWatcher: Task<Void, Never>?
    @State private var isWatchingBrowserLogin = false
    @State private var browserLoginLastError: String?
    @State private var handledBrowserLoginAutogenerateRequestID: UUID?
    @State private var status = ""
    @State private var showLogoutConfirm = false
    @State private var defaultModelModePreference = AgentSettingsStore.loadDefaultModelModePreference()

    private var imageModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsImageGeneration)
    }

    private var videoModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsVideoGeneration)
    }

    var body: some View {
        Form {
            Section(L10n.Settings.SomeIM.browserLoginSection) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.Settings.SomeIM.browserLoginDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let account {
                        ConnectorUnavailablePlaceholder(
                            title: L10n.Settings.SomeIM.browserLoginConnectedTitle,
                            systemImage: "checkmark.circle",
                            description: L10n.Settings.SomeIM.browserLoginConnectedDescription(account.displayName)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isWatchingBrowserLogin ? "person.badge.clock" : "safari")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.Settings.SomeIM.browserLoginPlaceholderTitle)
                                    .font(.headline)
                                Text(L10n.Settings.SomeIM.browserLoginPlaceholderDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    if isWatchingBrowserLogin {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .controlSize(.small)
                                    }
                                    Text(browserLoginStatusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    HStack {
                        Button(L10n.Settings.SomeIM.openBrowserLoginLink) {
                            openBrowserLoginLink()
                        }
                        .disabled(account != nil)
                    }
                }
            }

            Section(L10n.Settings.SomeIM.accountSection) {
                if let account {
                    LabeledContent(L10n.Settings.SomeIM.accountConnected) {
                        Text(L10n.Settings.SomeIM.accountSummary(account.displayName, account.compactDisplayCredits))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.Settings.SomeIM.defaultModelLabel) {
                        Text(account.defaultModel)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(isRefreshingBalance ? L10n.Settings.SomeIM.fetchingModels : L10n.Settings.SomeIM.refreshBalance) {
                            refreshBalance()
                        }
                        .disabled(isRefreshingBalance)
                        Button(L10n.Settings.SomeIM.openSomeIM) {
                            openSomeIM()
                        }
                        Spacer()
                        Button(L10n.Settings.SomeIM.logout, role: .destructive) {
                            showLogoutConfirm = true
                        }
                    }
                    .confirmationDialog(
                        L10n.Settings.SomeIM.logoutConfirmTitle,
                        isPresented: $showLogoutConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.Settings.SomeIM.logout, role: .destructive) {
                            performLogout()
                        }
                        Button(L10n.Settings.SomeIM.logoutCancel, role: .cancel) {}
                    } message: {
                        Text(L10n.Settings.SomeIM.logoutConfirmMessage)
                    }
                } else {
                    Text(L10n.Settings.SomeIM.accountNotConnected)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.Settings.SomeIM.newTabDefaultSection) {
                Picker(
                    L10n.Settings.SomeIM.newTabDefaultLabel,
                    selection: newTabDefaultUsesManagedRoutingBinding
                ) {
                    Text(L10n.Settings.SomeIM.newTabDefaultManaged).tag(true)
                    Text(L10n.Settings.SomeIM.newTabDefaultModel).tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!isSomeIMAuthenticated)

                Text(newTabDefaultHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.SomeIM.imageSection) {
                modelPicker(
                    L10n.Settings.SomeIM.imageModelLabel,
                    selection: $settings.preferredImageModel,
                    candidates: imageModels,
                    fallbackModels: settings.preferredImageModels
                )
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityImageModelsBinding)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.SomeIM.imageHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.SomeIM.videoSection) {
                modelPicker(
                    L10n.Settings.SomeIM.videoModelLabel,
                    selection: $settings.preferredVideoModel,
                    candidates: videoModels,
                    fallbackModels: settings.preferredVideoModels
                )
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityVideoModelsBinding)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.SomeIM.videoHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ensureBrowserLoginRequestIfNeeded()
        }
        .task {
            await appState.refreshSomeIMRelayRouting()
            reloadSharedSessionState()
            if !apiKey.isEmpty, fetchedModels.isEmpty {
                fetchModels()
            }
        }
        .onChange(of: settings) { updated in
            persistModelPreferences(updated)
        }
        .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.accountDidChangeNotification)) { _ in
            reloadSharedSessionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
            reloadSharedSessionState()
        }
        .onReceive(settingsNavigation.$someIMBrowserLoginAutogenerateRequestID) { _ in
            consumeBrowserLoginAutogenerateRequestIfNeeded()
        }
    }

    private var browserLoginStatusText: String {
        guard browserLoginRequest != nil else { return status }
        if let browserLoginLastError, !browserLoginLastError.isEmpty {
            return browserLoginLastError
        }
        if isWatchingBrowserLogin { return L10n.Settings.SomeIM.browserLoginWaiting }
        return status.isEmpty ? L10n.Settings.SomeIM.browserLoginReady : status
    }

    private var isSomeIMAuthenticated: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var newTabDefaultUsesManagedRoutingBinding: Binding<Bool> {
        Binding {
            defaultModelModePreference.usesManagedRoutingForNewSessions
        } set: { enabled in
            let preference: AgentDefaultModelModePreference = enabled ? .managed : .explicitModel
            defaultModelModePreference = preference
            AgentSettingsStore.saveDefaultModelModePreference(preference)
        }
    }

    private var newTabDefaultHelp: String {
        guard isSomeIMAuthenticated else {
            return L10n.Settings.SomeIM.newTabDefaultLoginRequired
        }
        return defaultModelModePreference.usesManagedRoutingForNewSessions
            ? L10n.Settings.SomeIM.newTabDefaultManagedHelp
            : L10n.Settings.SomeIM.newTabDefaultModelHelp
    }

    private func modelPicker(
        _ title: String,
        selection: Binding<String>,
        candidates: [SomeIMModel],
        fallbackModels: [String]
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: selection)
                    .textFieldStyle(.roundedBorder)
                let ids = candidateIDs(candidates: candidates, fallbackModels: fallbackModels)
                if !ids.isEmpty {
                    Picker("", selection: selection) {
                        ForEach(ids, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    private func candidateIDs(candidates: [SomeIMModel], fallbackModels: [String]) -> [String] {
        var seen = Set<String>()
        return (candidates.map(\.model) + fallbackModels)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private var priorityImageModelsBinding: Binding<String> {
        Binding {
            settings.preferredImageModels.joined(separator: ", ")
        } set: { value in
            settings.preferredImageModels = splitPriorityModels(value)
            if settings.preferredImageModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = settings.preferredImageModels.first {
                settings.preferredImageModel = first
            }
        }
    }

    private var priorityVideoModelsBinding: Binding<String> {
        Binding {
            settings.preferredVideoModels.joined(separator: ", ")
        } set: { value in
            settings.preferredVideoModels = splitPriorityModels(value)
            if settings.preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = settings.preferredVideoModels.first {
                settings.preferredVideoModel = first
            }
        }
    }

    private func splitPriorityModels(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func persistModelPreferences(_ updated: SomeIMIntegrationSettings) {
        let normalized = updated.normalized
        SomeIMIntegrationStore.saveSettings(normalized)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        appState.syncSomeIMProvider(settings: normalized, apiKey: trimmedKey, activate: false)
    }

    private func reloadSharedSessionState() {
        let latestSettings = SomeIMIntegrationStore.loadSettings()
        let authentication = SomeIMIntegrationStore.loadAuthenticationSnapshot()
        settings = latestSettings
        apiKey = authentication.apiKey
        account = authentication.account
        guard authentication.isAuthenticated else { return }
        appState.syncSomeIMProvider(settings: latestSettings, apiKey: authentication.apiKey)
        appState.syncSomeIMImageUnderstanding(apiKey: authentication.apiKey)
    }

    private func prepareBrowserLoginRequest(openInBrowser: Bool) {
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            status = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        do {
            let request = try SomeIMClient.makeBrowserLoginRequest(settings: settings.normalized)
            browserLoginRequest = request
            browserLoginLastError = nil
            status = L10n.Settings.SomeIM.browserLoginReady
            startBrowserLoginWatcher(for: request)
            if openInBrowser {
                _ = NSWorkspace.shared.open(request.url)
                status = L10n.Settings.SomeIM.browserLoginOpened
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func consumeBrowserLoginAutogenerateRequestIfNeeded() {
        guard let requestID = settingsNavigation.someIMBrowserLoginAutogenerateRequestID,
              handledBrowserLoginAutogenerateRequestID != requestID else {
            return
        }
        handledBrowserLoginAutogenerateRequestID = requestID
        ensureBrowserLoginRequestIfNeeded()
    }

    private func ensureBrowserLoginRequestIfNeeded() {
        guard account == nil else { return }
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            status = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        if let request = browserLoginRequest {
            if !isWatchingBrowserLogin {
                startBrowserLoginWatcher(for: request)
            }
        } else {
            prepareBrowserLoginRequest(openInBrowser: false)
        }
    }

    private func openBrowserLoginLink() {
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            status = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        if let request = browserLoginRequest {
            if !isWatchingBrowserLogin {
                startBrowserLoginWatcher(for: request)
            }
            _ = NSWorkspace.shared.open(request.url)
            status = L10n.Settings.SomeIM.browserLoginOpened
        } else {
            prepareBrowserLoginRequest(openInBrowser: true)
        }
    }

    private func startBrowserLoginWatcher(for loginRequest: SomeIMBrowserLoginRequest) {
        stopBrowserLoginWatcher()
        isWatchingBrowserLogin = true
        browserLoginLastError = nil
        status = L10n.Settings.SomeIM.browserLoginWaiting
        let currentSettings = settings.normalized
        browserLoginWatcher = Task {
            let deadline = Date().addingTimeInterval(10 * 60)
            var lastError: String?
            while !Task.isCancelled, Date() < deadline {
                do {
                    let result = try await SomeIMClient.checkBrowserLoginStatus(request: loginRequest, settings: currentSettings)
                    if lastError != nil {
                        lastError = nil
                        await MainActor.run {
                            guard browserLoginRequest?.code == loginRequest.code else { return }
                            browserLoginLastError = nil
                        }
                    }
                    if result.state == .connected, let linked = result.account {
                        await MainActor.run {
                            reloadSharedSessionState()
                            account = SomeIMIntegrationStore.loadAuthenticatedAccount() ?? linked
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginConnected
                            AgentTelemetry.recordLoginFinished(status: .succeeded, surface: .settings)
                        }
                        return
                    }
                    if result.state == .credentialSaveFailed {
                        await MainActor.run {
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginCredentialSaveFailed
                            AgentTelemetry.recordLoginFinished(
                                status: .failed,
                                surface: .settings,
                                errorCode: "credential_save_failed"
                            )
                        }
                        return
                    }
                    if result.state == .connected {
                        await MainActor.run {
                            // some.im 认为浏览器已登录，却没回 WillDeep 可识别的 API Key。
                            // 必须丢弃这个已被服务端标记为 connected 的一次性 code，否则下次点
                            // 「在浏览器打开」会复用它、被秒回同一条错误。清空后再点会自动 mint 新 code。
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginMissingCredentials
                            AgentTelemetry.recordLoginFinished(
                                status: .failed,
                                surface: .settings,
                                errorCode: "missing_credentials"
                            )
                        }
                        return
                    }
                    if result.state == .expired {
                        await MainActor.run {
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginExpired
                        }
                        return
                    }
                } catch {
                    lastError = error.localizedDescription
                    await MainActor.run {
                        guard browserLoginRequest?.code == loginRequest.code else { return }
                        browserLoginLastError = "浏览器登录状态查询失败：\(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await MainActor.run {
                browserLoginRequest = nil
                isWatchingBrowserLogin = false
                browserLoginLastError = nil
                status = lastError ?? L10n.Settings.SomeIM.browserLoginExpired
            }
        }
    }

    private func stopBrowserLoginWatcher() {
        browserLoginWatcher?.cancel()
        browserLoginWatcher = nil
        isWatchingBrowserLogin = false
    }

    private func refreshBalance() {
        isRefreshingBalance = true
        status = ""
        Task {
            let result: Result<SomeIMAccount, Error>
            do {
                result = .success(try await SomeIMClient.fetchAccountBalance())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isRefreshingBalance = false
                switch result {
                case .success(let refreshed):
                    account = refreshed
                    status = L10n.Settings.savedStatus
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    private func performLogout() {
        // Clears the shared session (broadcasting to every app on this Mac) and
        // this app's local caches. The AppState observer also drops the agent
        // provider off the sessionDidChange broadcast; do it here too for an
        // immediate, in-view response.
        SomeIMIntegrationStore.logout()
        appState.clearSomeIMProvider()
        account = nil
        apiKey = ""
        settings.enabled = false
        status = L10n.Settings.SomeIM.loggedOut
    }

    private func openSomeIM() {
        _ = NSWorkspace.shared.open(SomeIMClient.customerPortalURL)
    }

    private func fetchModels() {
        isFetching = true
        status = ""
        let currentSettings = settings.normalized
        let currentKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result: Result<[SomeIMModel], Error>
            do {
                result = .success(try await SomeIMClient.fetchModels(settings: currentSettings, apiKey: currentKey))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isFetching = false
                switch result {
                case .success(let models):
                    fetchedModels = models
                    appState.recordFetchedAgentModelDiscoveries(models.map(\.agentDiscovery))
                    adoptFetchedDefaults(models)
                    status = L10n.Settings.SomeIM.fetchedModels("\(models.count)")
                case .failure(let error):
                    fetchedModels = []
                    status = error.localizedDescription
                }
            }
        }
    }

    private func adoptFetchedDefaults(_ models: [SomeIMModel]) {
        let imageIDs = models.filter(\.supportsImageGeneration).map(\.model)
        let videoIDs = models.filter(\.supportsVideoGeneration).map(\.model)
        if let gptImage = imageIDs.first(where: { $0 == SomeIMIntegrationSettings.defaultImageModel }) {
            settings.preferredImageModel = gptImage
        } else if settings.preferredImageModel.isEmpty, let first = imageIDs.first {
            settings.preferredImageModel = first
        }
        settings.preferredImageModels = mergePriority(primary: settings.preferredImageModel, existing: settings.preferredImageModels, fetched: imageIDs)
        if settings.preferredVideoModel.isEmpty, let first = videoIDs.first {
            settings.preferredVideoModel = first
        }
        settings.preferredVideoModels = mergePriority(primary: settings.preferredVideoModel, existing: settings.preferredVideoModels, fetched: videoIDs)
    }

    private func mergePriority(primary: String, existing: [String], fetched: [String]) -> [String] {
        var seen = Set<String>()
        return ([primary] + existing + fetched)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}
