//
//  VoiceSettingsView.swift
//  WillDeep
//
//  1.86.0 起独占 Settings → Voice tab。整页布局,把下载/导入按钮放到
//  最显眼的位置,并展示模型路径、占用、状态。语音相关的所有 UI 入口
//  以后都收敛到这里。
//

import SwiftUI
import AppKit

struct VoiceSettingsView: View {
    @StateObject private var downloader = VoiceModelDownloader.shared
    @ObservedObject private var preferences = UserPreferences.shared
    @State private var preloadOnLaunch: Bool = VoiceLifecyclePrefs.preloadOnLaunch
    @State private var modelInMemory: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                actionRow
                progressView
                Divider().padding(.vertical, 4)
                overlaySection
                Divider().padding(.vertical, 4)
                lifecycleSection
                footer
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .task {
            await refreshMemoryStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On-device Voice (SenseVoice)", systemImage: "waveform")
                .font(.title3.weight(.semibold))
            Text("Push-to-talk in the composer transcribes 100% on-device. Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: VoiceModelDownloader.isModelInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 22))
                .foregroundStyle(VoiceModelDownloader.isModelInstalled ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(VoiceModelDownloader.isModelInstalled
                     ? "SenseVoice model installed"
                     : "Model not installed yet")
                    .font(.system(size: 13, weight: .medium))
                Text(VoiceModelDownloader.isModelInstalled
                     ? "Mic button in composer is enabled. Press and hold to record, release to transcribe. Tip: hold the Fn key anywhere in the app for the same push-to-talk."
                     : "Click Download below (~937 MB). After install the mic button in composer goes live and the Fn-key push-to-talk shortcut starts working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if !VoiceModelDownloader.isModelInstalled {
                Button {
                    Task { await downloader.download() }
                } label: {
                    Label("Download model (~937 MB)", systemImage: "arrow.down.to.line")
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)

                if VoiceModelDownloader.canImportFromFastv {
                    Button {
                        Task { try? await downloader.importFromFastv() }
                    } label: {
                        Label("Import from fastv (0 MB)", systemImage: "link")
                    }
                    .disabled(isBusy)
                    .help("Symlink an existing fastv model copy — no download.")
                }
            } else {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([VoiceModelLocation.modelDirectory])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }

            if isBusy {
                Button("Cancel") { downloader.cancel() }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var progressView: some View {
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
                Text("\(formatBytes(received)) / \(formatBytes(total)) — \(formatBytes(Int64(speed)))/s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Settings.Voice.overlaySection)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(L10n.Settings.Voice.overlayPositionLabel) {
                    Picker("", selection: $preferences.waveformOverlayPosition) {
                        ForEach(WaveformOverlayWindowPosition.allCases) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                LabeledContent(L10n.Settings.Voice.overlaySizeLabel) {
                    Picker("", selection: $preferences.waveformOverlayStyle) {
                        ForEach(WaveformOverlayWindowStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                LabeledContent(L10n.Settings.Voice.overlayColorLabel) {
                    Picker("", selection: $preferences.waveformOverlayColorStyle) {
                        ForEach(WaveformOverlayWindowColorStyle.allCases) { colorStyle in
                            HStack(spacing: 8) {
                                WaveformOverlayColorSwatch(colorStyle: colorStyle)
                                Text(colorStyle.displayName)
                            }
                            .tag(colorStyle)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                WaveformOverlayPreviewSwatch(
                    style: preferences.waveformOverlayStyle,
                    colorStyle: preferences.waveformOverlayColorStyle
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Settings.Voice.overlayPreviewTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(L10n.Settings.Voice.overlayPreviewDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    showOverlayPreview()
                } label: {
                    Label(L10n.Settings.Voice.overlayPreviewButton, systemImage: "play.circle")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
            )

            Text(L10n.Settings.Voice.overlayDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lifecycleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory")
                .font(.headline)

            Toggle(isOn: Binding(
                get: { preloadOnLaunch },
                set: { newValue in
                    preloadOnLaunch = newValue
                    VoiceLifecyclePrefs.preloadOnLaunch = newValue
                    if newValue {
                        VoiceModelLifecycleController.shared.preloadIfWarranted()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preload on launch")
                        .font(.system(size: 13))
                    Text("After your first transcription, warm the ~937 MB model on each app start so push-to-talk responds instantly. Disable to save memory at the cost of a 1-5 s cold start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(modelInMemory ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(modelInMemory ? "Loaded in memory" : "Not in memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if modelInMemory {
                    Button("Unload now") {
                        Task {
                            await VoiceModelLifecycleController.shared.unloadNow()
                            await refreshMemoryStatus()
                        }
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    Task { await refreshMemoryStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh status")
            }

            Text("The model also auto-unloads after 5 minutes of foreground idle, 10 minutes of background, or when the app's resident memory exceeds 4 GB.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshMemoryStatus() async {
        modelInMemory = await VoiceModelLifecycleController.shared.isLoaded()
    }

    private func showOverlayPreview() {
        WaveformOverlayWindowManager.shared.show()
        WaveformOverlayWindowManager.shared.updateAudioLevel(0.75)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            WaveformOverlayWindowManager.shared.hide()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model location")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(VoiceModelLocation.modelDirectory.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var isBusy: Bool {
        switch downloader.state {
        case .downloading, .importing: return true
        default: return false
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 100 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.1f MB", mb)
    }
}

private struct WaveformOverlayPreviewSwatch: View {
    let style: WaveformOverlayWindowStyle
    let colorStyle: WaveformOverlayWindowColorStyle

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let config = colorStyle.colorConfig(for: colorScheme)
        let size = style.size

        ZStack {
            background(config: config)

            if style.isMinimal {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [config.barColor, config.barColor.opacity(0.6)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 6
                        )
                    )
                    .frame(width: 8, height: 8)
                    .shadow(color: config.barColor.opacity(0.5), radius: 3)
            } else {
                HStack(spacing: style.barSpacing) {
                    ForEach(Array([0.35, 0.65, 0.9, 0.58, 0.4].enumerated()), id: \.offset) { _, height in
                        RoundedRectangle(cornerRadius: style.barWidth / 2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        config.barColor.opacity(0.95),
                                        config.barColor.opacity(0.7),
                                        config.barColor.opacity(0.45),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: style.barWidth, height: CGFloat(height) * style.maxBarHeight)
                    }
                }
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(width: 142, height: 56)
    }

    @ViewBuilder
    private func background(config: WaveformOverlayColorConfig) -> some View {
        if config.useMaterial {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .background {
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(config.backgroundColor.opacity(config.backgroundOpacity))
                }
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(config.backgroundColor.opacity(config.backgroundOpacity))
        }
    }
}

private struct WaveformOverlayColorSwatch: View {
    let colorStyle: WaveformOverlayWindowColorStyle

    var body: some View {
        let config = colorStyle.colorConfig(for: .dark)

        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(config.backgroundColor.opacity(config.backgroundOpacity))
                .frame(width: 26, height: 16)

            HStack(spacing: 2) {
                ForEach(Array([0.5, 0.8, 0.65].enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(config.barColor)
                        .frame(width: 2, height: CGFloat(height) * 12)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
    }
}
