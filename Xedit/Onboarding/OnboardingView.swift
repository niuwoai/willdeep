//
//  OnboardingView.swift
//  WillDeep
//
//  首次启动引导。主路径优先连接 some.im，再提供自有 AI Provider 与本地语音模型配置。
//

import SwiftUI
import AppKit

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case someIM
    case provider
    case voice
    case done

    var id: Int { rawValue }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var controller = OnboardingFlowController.shared
    @ObservedObject private var downloader = VoiceModelDownloader.shared

    @State private var currentStep: OnboardingStep = .welcome
    @State private var presetID = "claude"
    @State private var baseURL = "https://api.anthropic.com"
    @State private var apiKey = ""
    @State private var model = "claude-sonnet-4-5"
    @State private var visionProviderID = AgentImageDescriptionConfiguration.default.providerID
    @State private var visionBaseURL = AgentImageDescriptionConfiguration.default.baseURL
    @State private var visionAPIKey = ""
    @State private var visionModel = AgentImageDescriptionConfiguration.default.model
    @State private var providerSaveError: String?
    @State private var someIMSettings = SomeIMIntegrationStore.loadSettings()
    @State private var someIMAPIKey: String
    @State private var someIMAccount: SomeIMAccount?
    @State private var someIMBrowserLoginRequest: SomeIMBrowserLoginRequest?
    @State private var someIMBrowserLoginWatcher: Task<Void, Never>?
    @State private var isWatchingSomeIMBrowserLogin = false
    @State private var someIMBrowserLoginLastError: String?
    @State private var someIMStatus = ""

    private let preparesSomeIMBrowserLogin: Bool

    private let curatedPresets: [AgentProviderPreset] = AgentProviderPreset.all.filter {
        ["claude", "openai", "deepseek", "openrouter", "dashscope", AgentProviderPreset.customID].contains($0.id)
    }

    private let visionPresets = AgentProviderPreset.all.filter(\.supportsImageInput)

    init(
        initialStep: OnboardingStep = .welcome,
        usesStoredSomeIMState: Bool = true,
        preparesSomeIMBrowserLogin: Bool = true
    ) {
        let storedAPIKey = usesStoredSomeIMState ? SomeIMIntegrationStore.loadAPIKey() : ""
        let storedAccount = usesStoredSomeIMState ? SomeIMIntegrationStore.loadAccount() : nil
        _currentStep = State(initialValue: initialStep)
        _someIMAPIKey = State(initialValue: storedAPIKey)
        _someIMAccount = State(initialValue: SomeIMIntegrationStore.authenticatedAccount(
            cachedAccount: storedAccount,
            apiKey: storedAPIKey
        ))
        self.preparesSomeIMBrowserLogin = preparesSomeIMBrowserLogin
    }

    var body: some View {
        HStack(spacing: 0) {
            navigationRail
                .frame(width: 218)

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: 490, alignment: .topLeading)
                        .frame(maxWidth: .infinity, minHeight: 485, alignment: .top)
                        .padding(.horizontal, 36)
                        .padding(.top, 34)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                Divider()
                footer
            }
        }
        .frame(width: 780, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            someIMBrowserLoginWatcher?.cancel()
        }
    }

    // MARK: - Navigation

    private var navigationRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("DesktopPetPenguin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Onboarding.Navigation.productName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.Onboarding.Navigation.setupTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    navigationRow(for: step)
                }
            }

            Spacer()

            Label(L10n.Onboarding.Navigation.changeLater, systemImage: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func navigationRow(for step: OnboardingStep) -> some View {
        let isCurrent = step == currentStep
        let isComplete = step.rawValue < currentStep.rawValue
        let isReachable = step.rawValue <= currentStep.rawValue

        return Button {
            guard isReachable else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                currentStep = step
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 28, height: 28)

                    Image(systemName: isComplete ? "checkmark" : stepIcon(for: step))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color.white : (isComplete ? Color.accentColor : Color.secondary))
                }

                Text(stepTitle(for: step))
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .allowsHitTesting(isReachable)
        .accessibilityIdentifier("onboarding.step.\(stepAccessibilityName(step))")
    }

    private func stepTitle(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: L10n.Onboarding.Navigation.welcome
        case .someIM: L10n.Onboarding.Navigation.someIM
        case .provider: L10n.Onboarding.Navigation.provider
        case .voice: L10n.Onboarding.Navigation.voice
        case .done: L10n.Onboarding.Navigation.done
        }
    }

    private func stepIcon(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: "sparkles"
        case .someIM: "person.crop.circle.badge.checkmark"
        case .provider: "key.horizontal"
        case .voice: "waveform"
        case .done: "checkmark.seal"
        }
    }

    private func stepAccessibilityName(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: "welcome"
        case .someIM: "some-im"
        case .provider: "provider"
        case .voice: "voice"
        case .done: "done"
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch currentStep {
        case .welcome: welcomeStep
        case .someIM: someIMStep
        case .provider: providerStep
        case .voice: voiceStep
        case .done: doneStep
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    eyebrow(L10n.Onboarding.Welcome.eyebrow, color: .accentColor)
                    Text(L10n.Onboarding.Welcome.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("onboarding.welcome.title")
                    Text(L10n.Onboarding.Welcome.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image("DesktopPetPenguin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 124, height: 124)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 10) {
                benefitRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: L10n.Onboarding.Welcome.someIMTitle,
                    detail: L10n.Onboarding.Welcome.someIMDetail,
                    tint: .accentColor
                )
                benefitRow(
                    icon: "key.horizontal",
                    title: L10n.Onboarding.Welcome.providerTitle,
                    detail: L10n.Onboarding.Welcome.providerDetail,
                    tint: .orange
                )
                benefitRow(
                    icon: "waveform",
                    title: L10n.Onboarding.Welcome.voiceTitle,
                    detail: L10n.Onboarding.Welcome.voiceDetail,
                    tint: .purple
                )
            }
        }
    }

    private func benefitRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .background(cardBackground)
    }

    // MARK: - some.im

    private var someIMStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                eyebrow: L10n.Onboarding.Common.recommended,
                eyebrowColor: .accentColor,
                title: L10n.Onboarding.SomeIM.title,
                subtitle: L10n.Onboarding.SomeIM.subtitle
            )

            someIMConnectionCard

            HStack(spacing: 10) {
                capabilityCard(icon: "bubble.left.and.bubble.right", title: L10n.Onboarding.SomeIM.chatCapability)
                capabilityCard(icon: "photo.on.rectangle.angled", title: L10n.Onboarding.SomeIM.mediaCapability)
                capabilityCard(icon: "eye", title: L10n.Onboarding.SomeIM.visionCapability)
            }

            Label(L10n.Onboarding.SomeIM.note, systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if preparesSomeIMBrowserLogin {
                ensureSomeIMBrowserLoginRequestIfNeeded()
            }
        }
        .accessibilityIdentifier("onboarding.some-im.content")
    }

    private var someIMConnectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let account = someIMAccount {
                HStack(alignment: .top, spacing: 13) {
                    statusIcon(systemName: "checkmark", tint: .green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.SomeIM.browserLoginConnectedTitle)
                            .font(.system(size: 15, weight: .semibold))
                        Text(L10n.Settings.SomeIM.accountSummary(account.displayName, account.displayCredits))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("onboarding.some-im.connected")
            } else {
                HStack(alignment: .top, spacing: 13) {
                    statusIcon(
                        systemName: isWatchingSomeIMBrowserLogin ? "clock" : "person.crop.circle",
                        tint: .accentColor
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Onboarding.SomeIM.signInTitle)
                            .font(.system(size: 15, weight: .semibold))
                        Text(L10n.Onboarding.SomeIM.signInDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                Button {
                    openSomeIMBrowserLogin()
                } label: {
                    Label(L10n.Settings.SomeIM.openBrowserLoginLink, systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!SomeIMIntegrationStore.clientLoginSecretConfigured)
                .accessibilityIdentifier("onboarding.some-im.login")

                HStack(spacing: 7) {
                    if isWatchingSomeIMBrowserLogin {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: someIMBrowserLoginLastError == nil ? "info.circle" : "exclamationmark.triangle")
                            .foregroundStyle(someIMBrowserLoginLastError == nil ? Color.secondary : Color.orange)
                    }
                    Text(someIMBrowserLoginStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .background(cardBackground)
    }

    private func capabilityCard(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusIcon(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: Circle())
    }

    private var someIMBrowserLoginStatusText: String {
        guard someIMBrowserLoginRequest != nil else {
            return someIMStatus.isEmpty ? L10n.Settings.SomeIM.browserLoginReady : someIMStatus
        }
        if let someIMBrowserLoginLastError, !someIMBrowserLoginLastError.isEmpty {
            return someIMBrowserLoginLastError
        }
        if isWatchingSomeIMBrowserLogin {
            return L10n.Settings.SomeIM.browserLoginWaiting
        }
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
                            commitSomeIM()
                            someIMBrowserLoginRequest = nil
                            isWatchingSomeIMBrowserLogin = false
                            someIMStatus = L10n.Settings.SomeIM.accountSummary(account.displayName, account.displayCredits)
                        }
                        return
                    }
                    if result.state == .connected {
                        await MainActor.run {
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
                        someIMBrowserLoginLastError = L10n.Onboarding.SomeIM.statusCheckFailed(error.localizedDescription)
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

    // MARK: - Provider

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                eyebrow: L10n.Onboarding.Common.optional,
                eyebrowColor: .orange,
                title: L10n.Onboarding.Provider.title,
                subtitle: L10n.Onboarding.Provider.subtitle
            )

            if someIMAccount != nil {
                Label(L10n.Onboarding.Provider.someIMConnected, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 14) {
                providerField(L10n.Onboarding.Provider.labelProvider) {
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

                providerField(L10n.Onboarding.Provider.labelBaseURL) {
                    TextField(L10n.Onboarding.Provider.placeholderBaseURL, text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                providerField(L10n.Onboarding.Provider.labelAPIKey) {
                    SecureField(L10n.Onboarding.Provider.placeholderAPIKey, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                providerField(L10n.Onboarding.Provider.labelModel) {
                    TextField(L10n.Onboarding.Provider.placeholderModel, text: $model)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
            }
            .padding(18)
            .background(cardBackground)

            if needsVisionFallback {
                visionFallbackSection
            }

            if let providerSaveError {
                Label(providerSaveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("onboarding.provider.content")
    }

    private func providerField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity)
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
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                providerField(L10n.Onboarding.Provider.labelVisionProvider) {
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
                providerField(L10n.Onboarding.Provider.labelVisionBaseURL) {
                    TextField(L10n.Onboarding.Provider.placeholderBaseURL, text: $visionBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                providerField(L10n.Onboarding.Provider.labelVisionAPIKey) {
                    SecureField(L10n.Onboarding.Provider.placeholderAPIKey, text: $visionAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                providerField(L10n.Onboarding.Provider.labelVisionModel) {
                    TextField(L10n.Onboarding.Provider.placeholderModel, text: $visionModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 12)
        } label: {
            Label(L10n.Onboarding.Provider.visionRequired, systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func applyPreset(id: String) {
        guard let preset = curatedPresets.first(where: { $0.id == id }) else { return }
        baseURL = preset.baseURL
        model = preset.defaultFlashModel
    }

    private func applyVisionPreset(id: String) {
        guard let preset = visionPresets.first(where: { $0.id == id }) else { return }
        visionBaseURL = preset.baseURL
        visionModel = preset.defaultVisionModel
    }

    private func commitProvider() -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return nil
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
            if selectedVisionPreset?.requiresAPIKey ?? true, trimmedVisionKey.isEmpty {
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

    // MARK: - Voice

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                eyebrow: L10n.Onboarding.Common.optional,
                eyebrowColor: .purple,
                title: L10n.Onboarding.Voice.title,
                subtitle: L10n.Onboarding.Voice.subtitle
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 13) {
                    statusIcon(
                        systemName: VoiceModelDownloader.isModelInstalled ? "checkmark" : "arrow.down",
                        tint: VoiceModelDownloader.isModelInstalled ? .green : .purple
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(VoiceModelDownloader.isModelInstalled
                            ? L10n.Onboarding.Voice.installedTitle
                            : L10n.Onboarding.Voice.notInstalledTitle)
                            .font(.system(size: 15, weight: .semibold))
                        Text(VoiceModelDownloader.isModelInstalled
                            ? L10n.Onboarding.Voice.installedDetail
                            : L10n.Onboarding.Voice.notInstalledDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if !VoiceModelDownloader.isModelInstalled {
                    HStack(spacing: 10) {
                        Button {
                            Task { await downloader.download() }
                        } label: {
                            Label(L10n.Onboarding.Voice.downloadButton, systemImage: "arrow.down.to.line")
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

                        if isVoiceBusy {
                            Button(L10n.Onboarding.Voice.cancel) {
                                downloader.cancel()
                            }
                        }
                    }
                }

                voiceProgress
            }
            .padding(18)
            .background(cardBackground)

            Label(L10n.Onboarding.Voice.privacyNote, systemImage: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var voiceProgress: some View {
        switch downloader.state {
        case .idle, .finished:
            EmptyView()
        case .importing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(L10n.Onboarding.Voice.importing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let progress, let received, let total, let speed):
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: progress, total: 1)
                Text(L10n.Onboarding.Voice.downloadProgress(
                    formatMB(received),
                    formatMB(total),
                    formatMB(Int64(speed))
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(4)
        }
    }

    private var isVoiceBusy: Bool {
        switch downloader.state {
        case .downloading, .importing: true
        default: false
        }
    }

    private func formatMB(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        return megabytes >= 100
            ? String(format: "%.0f MB", megabytes)
            : String(format: "%.1f MB", megabytes)
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader(
                eyebrow: L10n.Onboarding.Done.eyebrow,
                eyebrowColor: .green,
                title: L10n.Onboarding.Done.title,
                subtitle: L10n.Onboarding.Done.subtitle
            )

            VStack(spacing: 10) {
                summaryRow(
                    icon: "brain.head.profile",
                    title: L10n.Onboarding.Done.aiTitle,
                    detail: aiSetupSummary,
                    isReady: isAIReady
                )
                summaryRow(
                    icon: "waveform",
                    title: L10n.Onboarding.Done.voiceTitle,
                    detail: VoiceModelDownloader.isModelInstalled
                        ? L10n.Onboarding.Done.voiceReady
                        : L10n.Onboarding.Done.voiceLater,
                    isReady: VoiceModelDownloader.isModelInstalled
                )
                summaryRow(
                    icon: "gearshape",
                    title: L10n.Onboarding.Done.settingsTitle,
                    detail: L10n.Onboarding.Done.settingsDetail,
                    isReady: true
                )
            }

            Label(L10n.Onboarding.Done.tipAgent, systemImage: "lightbulb.max.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isAIReady: Bool {
        someIMAccount != nil
            || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || appState.agentProviderLibrary.active != nil
    }

    private var aiSetupSummary: String {
        if let account = someIMAccount {
            return L10n.Onboarding.Done.someIMReady(account.displayName)
        }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.Onboarding.Done.providerReady
        }
        if let active = appState.agentProviderLibrary.active {
            return L10n.Onboarding.Done.existingProviderReady(active.displayName)
        }
        return L10n.Onboarding.Done.aiLater
    }

    private func summaryRow(icon: String, title: String, detail: String, isReady: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isReady ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
                .background(
                    (isReady ? Color.accentColor : Color.secondary).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: isReady ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(isReady ? Color.green : Color.secondary)
        }
        .padding(13)
        .background(cardBackground)
    }

    // MARK: - Shared presentation

    private func eyebrow(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
    }

    private func stepHeader(eyebrow: String, eyebrowColor: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            self.eyebrow(eyebrow, color: eyebrowColor)
            Text(title)
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L10n.Onboarding.Footer.stepProgress(
                String(currentStep.rawValue + 1),
                String(OnboardingStep.allCases.count)
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Spacer()

            if let previous = currentStep.previous {
                Button(L10n.Onboarding.Footer.back) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        currentStep = previous
                    }
                }
            }

            Button(primaryButtonTitle) {
                handlePrimary()
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding.footer.primary")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var primaryButtonTitle: String {
        switch currentStep {
        case .welcome:
            L10n.Onboarding.Footer.startSetup
        case .someIM:
            someIMAccount == nil ? L10n.Onboarding.Footer.skipForNow : L10n.Onboarding.Footer.continue
        case .provider:
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L10n.Onboarding.Footer.skipForNow
                : L10n.Onboarding.Footer.saveContinue
        case .voice:
            VoiceModelDownloader.isModelInstalled
                ? L10n.Onboarding.Footer.continue
                : L10n.Onboarding.Footer.skipForNow
        case .done:
            L10n.Onboarding.Footer.getStarted
        }
    }

    private func handlePrimary() {
        switch currentStep {
        case .welcome:
            advance()
        case .someIM:
            if !someIMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitSomeIM()
            }
            advance()
        case .provider:
            if let error = commitProvider() {
                providerSaveError = error
                return
            }
            providerSaveError = nil
            advance()
        case .voice:
            advance()
        case .done:
            controller.markCompleted()
        }
    }

    private func advance() {
        guard let next = currentStep.next else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            currentStep = next
        }
    }
}
