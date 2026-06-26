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
    @State private var providerSaveError: String?
    @State private var someIMSettings = SomeIMIntegrationStore.loadSettings()
    @State private var someIMAPIKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var someIMStatus = ""

    private let curatedPresets: [AgentProviderPreset] = AgentProviderPreset.all.filter {
        ["claude", "openai", "deepseek", "openrouter", "dashscope", AgentProviderPreset.customID].contains($0.id)
    }

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
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                L10n.Onboarding.Provider.title,
                subtitle: L10n.Onboarding.Provider.subtitle
            )

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
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.Onboarding.Provider.labelModel) {
                    TextField("", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
            }

            if let err = providerSaveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
    }

    private func applyPreset(id: String) {
        guard let p = curatedPresets.first(where: { $0.id == id }) else { return }
        baseURL = p.baseURL
        model = p.defaultFlashModel
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

                LabeledContent(L10n.Settings.SomeIM.regionLabel) {
                    Picker("", selection: someIMRelayRegionBinding) {
                        ForEach(SomeIMRelayRegion.allCases) { region in
                            Text(L10n.Settings.SomeIM.regionName(region)).tag(region)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                LabeledContent(L10n.Settings.SomeIM.baseURLLabel) {
                    TextField("", text: $someIMSettings.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                LabeledContent(L10n.Settings.SomeIM.apiKeyLabel) {
                    SecureField("", text: $someIMAPIKey)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.Settings.SomeIM.imageModelLabel) {
                    TextField("", text: $someIMSettings.preferredImageModel)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                LabeledContent(L10n.Settings.SomeIM.videoModelLabel) {
                    TextField("", text: $someIMSettings.preferredVideoModel)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .disabled(true)
                }
                Text(L10n.Settings.SomeIM.videoHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.Onboarding.SomeIM.note)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !someIMStatus.isEmpty {
                Text(someIMStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var someIMRelayRegionBinding: Binding<SomeIMRelayRegion> {
        Binding {
            SomeIMRelayRegion.resolved(for: someIMSettings.baseURL)
        } set: { region in
            if let baseURL = region.baseURL {
                someIMSettings.baseURL = baseURL
            }
        }
    }

    private func commitSomeIM() {
        let normalized = someIMSettings.normalized
        someIMSettings = normalized
        let trimmedKey = someIMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        SomeIMIntegrationStore.saveSettings(normalized)
        SomeIMIntegrationStore.saveAPIKey(trimmedKey)
        appState.syncSomeIMProvider(settings: normalized, apiKey: trimmedKey)
        appState.syncSomeIMImageUnderstanding(apiKey: trimmedKey)
        someIMStatus = L10n.Settings.savedStatus
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
