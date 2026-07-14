//
//  OnboardingView.swift
//  WillDeep
//
//  1.88.0 起。首次启动 4 步 wizard:
//    1. 欢迎
//    2. 配一个 AI provider(可跳过)
//    3. 下载语音模型(可跳过 / 从 fastv 导入)
//    4. 完成,告知怎么用
//
//  这个 sheet 由 OnboardingFlowController.shared.isPresented 控制,
//  挂在 WindowRootView 的根层级。view 内部用 @State currentStep 在 4
//  步之间切换,没有路由,简单 wizard 即可。
//

import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var controller = OnboardingFlowController.shared
    @ObservedObject private var downloader = VoiceModelDownloader.shared

    @State private var currentStep: Int = 0
    @State private var presetID: String = "claude"
    @State private var baseURL: String = "https://api.anthropic.com"
    @State private var apiKey: String = ""
    @State private var model: String = "claude-sonnet-4-5"
    @State private var visionProviderID: String = AgentImageDescriptionConfiguration.default.providerID
    @State private var visionBaseURL: String = AgentImageDescriptionConfiguration.default.baseURL
    @State private var visionAPIKey: String = ""
    @State private var visionModel: String = AgentImageDescriptionConfiguration.default.model
    @State private var providerSaveError: String?
    @State private var someIMSettings = SomeIMIntegrationStore.loadSettings()
    @State private var someIMAPIKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var someIMAccount = SomeIMIntegrationStore.loadAccount()
    @State private var someIMBrowserLoginRequest: SomeIMBrowserLoginRequest?
    @State private var someIMBrowserLoginWatcher: Task<Void, Never>?
    @State private var isWatchingSomeIMBrowserLogin = false
    @State private var someIMBrowserLoginLastError: String?
    @State private var someIMStatus = ""

    private let curatedPresets: [AgentProviderPreset] = AgentProviderPreset.all.filter {
        ["claude", "openai", "deepseek", "openrouter", "dashscope", AgentProviderPreset.customID].contains($0.id)
    }

    private let visionPresets: [AgentProviderPreset] = AgentProviderPreset.all.filter(\.supportsImageInput)

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 32)
                .padding(.bottom, 16)
            Divider()
            footer
        }
        .frame(width: 600, height: 540)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch currentStep {
        case 0: welcomeStep
        case 1: providerStep
        case 2: someIMStep
        case 3: voiceStep
        default: doneStep
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.linearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                ))
            Text(L10n.Onboarding.Welcome.title)
                .font(.system(size: 26, weight: .semibold))
            Text(L10n.Onboarding.Welcome.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 10) {
                bullet(L10n.Onboarding.Welcome.bulletProvider)
                bullet(L10n.Onboarding.Welcome.bulletVoice)
                bullet(L10n.Onboarding.Welcome.bulletSettings)
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13))
                .padding(.top, 2)
            Text(text).font(.system(size: 13))
        }
    }

    // MARK: - Step 2: Provider

    private var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stepHeader(
                    L10n.Onboarding.Provider.title,
                    subtitle: L10n.Onboarding.Provider.subtitle
                )

                Label {
                    Text(L10n.Onboarding.Provider.someIMRecommendation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(L10n.Onboarding.Provider.labelProvider) {
                        Picker("", selection: $presetID) {
                            ForEach(curatedPresets) { preset in
                                Text(preset.displayName).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onCompatibleChange(of: presetID) { _, newID in
                            applyPreset(id: newID)
                        }
                    }

                    LabeledContent(L10n.Onboarding.Provider.labelBaseURL) {
                        TextField("", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }

                    LabeledContent(L10n.Onboarding.Provider.labelAPIKey) {
                        SecureField("", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent(L10n.Onboarding.Provider.labelModel) {
                        TextField("", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                }

                if needsVisionFallback {
                    visionFallbackSection
                }

                if let err = providerSaveError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var needsVisionFallback: Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return false }
        guard let preset = curatedPresets.first(where: { $0.id == presetID }) else { return false }
        guard preset.supportsImageInput else { return true }
        return !AgentConfiguration.modelAcceptsImageInput(trimmedModel)
    }

    private var selectedVisionPreset: AgentProviderPreset? {
        AgentProviderPreset.preset(id: visionProviderID)
    }

    private var visionFallbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(L10n.Onboarding.Provider.visionRequired)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye")
                    .foregroundStyle(.orange)
            }

            LabeledContent(L10n.Onboarding.Provider.labelVisionProvider) {
                Picker("", selection: $visionProviderID) {
                    ForEach(visionPresets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onCompatibleChange(of: visionProviderID) { _, newID in
                    applyVisionPreset(id: newID)
                }
            }

            LabeledContent(L10n.Onboarding.Provider.labelVisionBaseURL) {
                TextField("", text: $visionBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            LabeledContent(L10n.Onboarding.Provider.labelVisionAPIKey) {
                SecureField("", text: $visionAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Onboarding.Provider.labelVisionModel) {
                TextField("", text: $visionModel)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }

    private func applyPreset(id: String) {
        guard let p = curatedPresets.first(where: { $0.id == id }) else { return }
        baseURL = p.baseURL
        model = p.defaultFlashModel
    }

    private func applyVisionPreset(id: String) {
        guard let preset = visionPresets.first(where: { $0.id == id }) else { return }
        visionBaseURL = preset.baseURL
        visionModel = preset.defaultVisionModel
    }

    /// 写入 provider library。空 apiKey 视为「跳过」—— 不动 library。
    /// 返回错误描述或 nil。
    private func commitProvider() -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return nil  // 用户没填 key,直接跳过保存
        }
        guard let preset = curatedPresets.first(where: { $0.id == presetID }) else {
            return L10n.Onboarding.Provider.errorUnknownPreset
        }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty || preset.id == AgentProviderPreset.customID else {
            return L10n.Onboarding.Provider.errorBaseURLRequired
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return L10n.Onboarding.Provider.errorModelRequired
        }
        let imageDescription: AgentImageDescriptionConfiguration
        if needsVisionFallback {
            let trimmedVisionBaseURL = visionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedVisionModel = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedVisionKey = visionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedVisionBaseURL.isEmpty else {
                return L10n.Onboarding.Provider.errorVisionBaseURLRequired
            }
            guard !trimmedVisionModel.isEmpty else {
                return L10n.Onboarding.Provider.errorVisionModelRequired
            }
            if selectedVisionPreset?.requiresAPIKey ?? true,
               trimmedVisionKey.isEmpty {
                return L10n.Onboarding.Provider.errorVisionAPIKeyRequired
            }
            imageDescription = AgentImageDescriptionConfiguration(
                providerID: visionProviderID,
                baseURL: trimmedVisionBaseURL,
                model: trimmedVisionModel,
                apiKey: trimmedVisionKey
            ).normalized
        } else {
            imageDescription = appState.agentConfiguration.normalized.imageDescription
        }
        let entry = AgentProviderEntry(
            providerID: preset.id,
            displayName: preset.displayName,
            baseURL: trimmedURL,
            apiKey: key,
            flashPrimary: trimmedModel,
            proPrimary: trimmedModel
        )
        var library = appState.agentProviderLibrary
        library.upsert(entry)
        library.activeID = entry.id
        var configuration = appState.agentConfiguration.normalized
        configuration.imageDescription = imageDescription
        appState.agentConfiguration = configuration.normalized
        appState.agentProviderLibrary = library
        return nil
    }

    // MARK: - Step 3: some.im

    private var someIMStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                L10n.Onboarding.SomeIM.title,
                subtitle: L10n.Onboarding.SomeIM.subtitle
            )

            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.Settings.SomeIM.enabledToggle, isOn: $someIMSettings.enabled)

                if let account = someIMAccount {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Settings.SomeIM.browserLoginConnectedTitle)
                                .font(.headline)
                            Text(L10n.Settings.SomeIM.accountSummary(account.displayName, account.displayCredits))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isWatchingSomeIMBrowserLogin ? "person.badge.clock" : "safari")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.Settings.SomeIM.browserLoginPlaceholderTitle)
                                .font(.headline)
                            Text(L10n.Settings.SomeIM.browserLoginPlaceholderDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                if isWatchingSomeIMBrowserLogin {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .controlSize(.small)
                                }
                                Text(someIMBrowserLoginStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        openSomeIMBrowserLogin()
                    } label: {
                        Label(L10n.Settings.SomeIM.openBrowserLoginLink, systemImage: "safari")
                    }
                }

                Text(L10n.Onboarding.SomeIM.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !someIMStatus.isEmpty {
                Text(someIMStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear {
            ensureSomeIMBrowserLoginRequestIfNeeded()
        }
    }

    private var someIMBrowserLoginStatusText: String {
        guard someIMBrowserLoginRequest != nil else { return someIMStatus }
        if let someIMBrowserLoginLastError, !someIMBrowserLoginLastError.isEmpty {
            return someIMBrowserLoginLastError
        }
        if isWatchingSomeIMBrowserLogin { return L10n.Settings.SomeIM.browserLoginWaiting }
        return someIMStatus.isEmpty ? L10n.Settings.SomeIM.browserLoginReady : someIMStatus
    }

    private func commitSomeIM() {
        let normalized = someIMSettings.normalized
        someIMSettings = normalized
        let trimmedKey = someIMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        SomeIMIntegrationStore.saveSettings(normalized)
        if trimmedKey.isEmpty || SomeIMIntegrationStore.saveAPIKey(trimmedKey) {
            appState.syncSomeIMProvider(settings: normalized, apiKey: trimmedKey)
            appState.syncSomeIMImageUnderstanding(apiKey: trimmedKey)
            someIMStatus = L10n.Settings.savedStatus
        } else {
            someIMAPIKey = SomeIMIntegrationStore.loadAPIKey()
            someIMStatus = L10n.Settings.SomeIM.browserLoginCredentialSaveFailed
        }
    }

    private func ensureSomeIMBrowserLoginRequestIfNeeded() {
        guard someIMAccount == nil else { return }
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            someIMStatus = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        if let request = someIMBrowserLoginRequest {
            if !isWatchingSomeIMBrowserLogin {
                startSomeIMBrowserLoginWatcher(for: request)
            }
        } else {
            prepareSomeIMBrowserLoginRequest(openInBrowser: false)
        }
    }

    private func prepareSomeIMBrowserLoginRequest(openInBrowser: Bool) {
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            someIMStatus = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        do {
            let normalized = someIMSettings.normalized
            someIMSettings = normalized
            let request = try SomeIMClient.makeBrowserLoginRequest(settings: normalized)
            someIMBrowserLoginRequest = request
            someIMBrowserLoginLastError = nil
            someIMStatus = L10n.Settings.SomeIM.browserLoginReady
            startSomeIMBrowserLoginWatcher(for: request)
            if openInBrowser {
                _ = NSWorkspace.shared.open(request.url)
                someIMStatus = L10n.Settings.SomeIM.browserLoginOpened
            }
        } catch {
            someIMStatus = error.localizedDescription
        }
    }

    private func openSomeIMBrowserLogin() {
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            someIMStatus = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        if let request = someIMBrowserLoginRequest {
            if !isWatchingSomeIMBrowserLogin {
                startSomeIMBrowserLoginWatcher(for: request)
            }
            _ = NSWorkspace.shared.open(request.url)
            someIMStatus = L10n.Settings.SomeIM.browserLoginOpened
        } else {
            prepareSomeIMBrowserLoginRequest(openInBrowser: true)
        }
    }

    private func startSomeIMBrowserLoginWatcher(for loginRequest: SomeIMBrowserLoginRequest) {
        someIMBrowserLoginWatcher?.cancel()
        isWatchingSomeIMBrowserLogin = true
        someIMBrowserLoginLastError = nil
        someIMStatus = L10n.Settings.SomeIM.browserLoginWaiting
        let currentSettings = someIMSettings.normalized
        someIMBrowserLoginWatcher = Task {
            let deadline = Date().addingTimeInterval(10 * 60)
            var lastError: String?
            while !Task.isCancelled, Date() < deadline {
                do {
                    let result = try await SomeIMClient.checkBrowserLoginStatus(request: loginRequest, settings: currentSettings)
                    if lastError != nil {
                        lastError = nil
                        await MainActor.run {
                            guard someIMBrowserLoginRequest?.code == loginRequest.code else { return }
                            someIMBrowserLoginLastError = nil
                        }
                    }
                    if result.state == .connected, let account = result.account {
                        await MainActor.run {
                            someIMAccount = account
                            someIMAPIKey = SomeIMIntegrationStore.loadAPIKey()
                            someIMSettings = SomeIMIntegrationStore.loadSettings()
                            appState.syncSomeIMProvider(settings: someIMSettings, apiKey: someIMAPIKey)
                            appState.syncSomeIMImageUnderstanding(apiKey: someIMAPIKey)
                            someIMBrowserLoginRequest = nil
                            isWatchingSomeIMBrowserLogin = false
                            someIMStatus = L10n.Settings.SomeIM.accountSummary(account.displayName, account.displayCredits)
                        }
                        return
                    }
                    if result.state == .connected {
                        await MainActor.run {
                            // 丢弃这个已被服务端标记 connected 却没回凭据的一次性 code，
                            // 否则重试会复用它、被秒回同一条错误。清空后重新打开会 mint 新 code。
                            someIMBrowserLoginRequest = nil
                            isWatchingSomeIMBrowserLogin = false
                            someIMStatus = L10n.Settings.SomeIM.browserLoginMissingCredentials
                        }
                        return
                    }
                    if result.state == .expired {
                        await MainActor.run {
                            someIMBrowserLoginRequest = nil
                            isWatchingSomeIMBrowserLogin = false
                            someIMStatus = L10n.Settings.SomeIM.browserLoginExpired
                        }
                        return
                    }
                } catch {
                    lastError = error.localizedDescription
                    await MainActor.run {
                        guard someIMBrowserLoginRequest?.code == loginRequest.code else { return }
                        someIMBrowserLoginLastError = "浏览器登录状态查询失败：\(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await MainActor.run {
                someIMBrowserLoginRequest = nil
                isWatchingSomeIMBrowserLogin = false
                someIMBrowserLoginLastError = nil
                someIMStatus = lastError ?? L10n.Settings.SomeIM.browserLoginExpired
            }
        }
    }

    // MARK: - Step 4: Voice

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                L10n.Onboarding.Voice.title,
                subtitle: L10n.Onboarding.Voice.subtitle
            )

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: VoiceModelDownloader.isModelInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(VoiceModelDownloader.isModelInstalled ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(VoiceModelDownloader.isModelInstalled
                         ? L10n.Onboarding.Voice.installedTitle
                         : L10n.Onboarding.Voice.notInstalledTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(VoiceModelDownloader.isModelInstalled
                         ? L10n.Onboarding.Voice.installedDetail
                         : L10n.Onboarding.Voice.notInstalledDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

            HStack(spacing: 10) {
                if !VoiceModelDownloader.isModelInstalled {
                    Button {
                        Task { await downloader.download() }
                    } label: {
                        Label(L10n.Onboarding.Voice.downloadButton, systemImage: "arrow.down.to.line")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isVoiceBusy)

                    if VoiceModelDownloader.canImportFromFastv {
                        Button {
                            Task { try? await downloader.importFromFastv() }
                        } label: {
                            Label(L10n.Onboarding.Voice.importButton, systemImage: "link")
                        }
                        .disabled(isVoiceBusy)
                    }
                }
                if isVoiceBusy {
                    Button(L10n.Onboarding.Voice.cancel) { downloader.cancel() }
                }
                Spacer()
            }

            voiceProgress

            Spacer()
        }
    }

    @ViewBuilder
    private var voiceProgress: some View {
        switch downloader.state {
        case .idle, .finished:
            EmptyView()
        case .importing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.Onboarding.Voice.importing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let progress, let received, let total, let speed):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress, total: 1.0)
                Text("\(formatMB(received)) / \(formatMB(total)) — \(formatMB(Int64(speed)))/s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
    }

    private var isVoiceBusy: Bool {
        switch downloader.state {
        case .downloading, .importing: return true
        default: return false
        }
    }

    private func formatMB(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 100 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
    }

    // MARK: - Step 5: Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(L10n.Onboarding.Done.title)
                .font(.system(size: 24, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                tip(L10n.Onboarding.Done.tipAgent)
                tip(L10n.Onboarding.Done.tipVoice)
                tip(L10n.Onboarding.Done.tipSettings)
            }
            .padding(.top, 8)
            .frame(maxWidth: 480, alignment: .leading)
            Spacer()
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13))
                .padding(.top, 2)
            Text(text).font(.system(size: 13))
        }
    }

    // MARK: - Step header

    private func stepHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            stepDots
            Spacer()
            if currentStep > 0 && currentStep < 4 {
                Button(L10n.Onboarding.Footer.back) { currentStep -= 1 }
            }
            if currentStep == 1 {
                Button(L10n.Onboarding.Footer.skip) {
                    providerSaveError = nil
                    currentStep += 1
                }
            }
            if currentStep == 2 {
                Button(L10n.Onboarding.Footer.skip) { currentStep += 1 }
            }
            if currentStep == 3 {
                Button(L10n.Onboarding.Footer.skip) { currentStep += 1 }
            }
            Button(primaryButtonTitle) {
                handlePrimary()
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch currentStep {
        case 0: return L10n.Onboarding.Footer.continue
        case 1: return apiKey.isEmpty ? L10n.Onboarding.Footer.continue : L10n.Onboarding.Footer.saveContinue
        case 2: return someIMAPIKey.isEmpty ? L10n.Onboarding.Footer.continue : L10n.Onboarding.Footer.saveContinue
        case 3: return L10n.Onboarding.Footer.continue
        default: return L10n.Onboarding.Footer.getStarted
        }
    }

    private func handlePrimary() {
        switch currentStep {
        case 0:
            currentStep = 1
        case 1:
            if let err = commitProvider() {
                providerSaveError = err
                return
            }
            providerSaveError = nil
            currentStep = 2
        case 2:
            if !someIMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitSomeIM()
            }
            currentStep = 3
        case 3:
            currentStep = 4
        default:
            controller.markCompleted()
        }
    }
}
