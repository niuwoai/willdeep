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
        case 2: voiceStep
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
            Text("Welcome to WillDeep")
                .font(.system(size: 26, weight: .semibold))
            Text("An editor that codes, transcribes, and ships alongside you. Let's get you set up in three quick steps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 10) {
                bullet("Bring your own AI provider — Claude, OpenAI, DeepSeek and more")
                bullet("Push-to-talk voice transcription runs 100% on-device")
                bullet("Settings, models and skills you can change anytime")
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
                "Connect an AI provider",
                subtitle: "Pick one to start with — you can add more later in Settings → AI Providers. Skip if you'll only use voice features."
            )

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Provider") {
                    Picker("", selection: $presetID) {
                        ForEach(curatedPresets) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: presetID) { _, newID in
                        applyPreset(id: newID)
                    }
                }

                LabeledContent("Base URL") {
                    TextField("", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                LabeledContent("API key") {
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Default model") {
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
            return "Unknown provider preset."
        }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty || preset.id == AgentProviderPreset.customID else {
            return "Base URL is required for this provider."
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return "Please specify a model id."
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

    // MARK: - Step 3: Voice

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                "Set up voice transcription",
                subtitle: "Optional — but if you want to talk to your agent or use push-to-talk in the composer, you'll need the on-device SenseVoice model (~937 MB)."
            )

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: VoiceModelDownloader.isModelInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(VoiceModelDownloader.isModelInstalled ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(VoiceModelDownloader.isModelInstalled
                         ? "Model installed"
                         : "Model not installed")
                        .font(.system(size: 13, weight: .medium))
                    Text(VoiceModelDownloader.isModelInstalled
                         ? "Push-to-talk is ready. Press and hold the mic button in the composer, or hold the Fn key anywhere in the app."
                         : "Click Download for the full file, or import a copy you already have from fastv (no bytes transferred).")
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
                        Label("Download (~937 MB)", systemImage: "arrow.down.to.line")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isVoiceBusy)

                    if VoiceModelDownloader.canImportFromFastv {
                        Button {
                            Task { try? await downloader.importFromFastv() }
                        } label: {
                            Label("Import from fastv", systemImage: "link")
                        }
                        .disabled(isVoiceBusy)
                    }
                }
                if isVoiceBusy {
                    Button("Cancel") { downloader.cancel() }
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
                Text("Importing from fastv…")
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

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.system(size: 24, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                tip("Open the Agent panel from the toolbar, ask anything in plain language.")
                tip("Hold the mic button in the composer, or hold Fn anywhere, to talk instead of type.")
                tip("Need to tweak providers, voice, memory, or skills? Cmd-, opens Settings.")
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
            if currentStep > 0 && currentStep < 3 {
                Button("Back") { currentStep -= 1 }
            }
            if currentStep == 1 {
                Button("Skip") {
                    providerSaveError = nil
                    currentStep += 1
                }
            }
            if currentStep == 2 {
                Button("Skip") { currentStep += 1 }
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
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch currentStep {
        case 0: return "Continue"
        case 1: return apiKey.isEmpty ? "Continue" : "Save & Continue"
        case 2: return "Continue"
        default: return "Get started"
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
            currentStep = 3
        default:
            controller.markCompleted()
        }
    }
}
