//
//  AgentLocalModelSettingsView.swift
//  WillDeep
//
//  Settings UI for local OpenAI-compatible auxiliary models.
//

import SwiftUI
import AppKit

struct AgentLocalModelSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    @ObservedObject private var downloader = AgentLocalModelDownloader.shared
    @ObservedObject private var finder = AgentLocalModelFileFinder.shared

    @State private var settings = AgentSettingsStore.loadLocalModelSettings()
    @State private var savedSettings = AgentSettingsStore.loadLocalModelSettings()
    @State private var statusMessage = ""

    private let package = AgentLocalModelPackage.recommended

    var body: some View {
        Section(L10n.Settings.sectionLocalModelAcceleration) {
            Toggle(L10n.Settings.LocalModel.enabled, isOn: $settings.enabled)
                .onCompatibleChange(of: settings.enabled) { _, _ in save() }

            LabeledContent(L10n.Settings.LocalModel.baseURL) {
                TextField("", text: $settings.baseURL, onCommit: save)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.LocalModel.visionModel) {
                TextField("", text: $settings.visionModel, onCommit: save)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.LocalModel.llmModel) {
                TextField("", text: $settings.summaryModel, onCommit: save)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(L10n.Settings.LocalModel.preferVision, isOn: $settings.preferForImageUnderstanding)
                .onCompatibleChange(of: settings.preferForImageUnderstanding) { _, _ in save() }
            Toggle(L10n.Settings.LocalModel.preferTitle, isOn: $settings.preferForTitles)
                .onCompatibleChange(of: settings.preferForTitles) { _, _ in save() }
            Toggle(L10n.Settings.LocalModel.preferContextSummary, isOn: $settings.preferForContextSummaries)
                .onCompatibleChange(of: settings.preferForContextSummaries) { _, _ in save() }
            Toggle(L10n.Settings.LocalModel.preferWorkerRouting, isOn: $settings.preferForWorkerRouting)
                .onCompatibleChange(of: settings.preferForWorkerRouting) { _, _ in save() }
            Text(L10n.Settings.LocalModel.workerRoutingHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(L10n.Settings.LocalModel.exposeComposerModel, isOn: $settings.exposeAsComposerModel)
                .onCompatibleChange(of: settings.exposeAsComposerModel) { _, _ in save() }

            LabeledContent(L10n.Settings.LocalModel.composerModelName) {
                TextField(L10n.Settings.LocalModel.composerModelNamePlaceholder, text: $settings.composerDisplayName, onCommit: save)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.exposeAsComposerModel)
            }

            HStack {
                Button(L10n.Settings.buttonSave) { save() }
                    .disabled(!settingsDiffer)
                Button(L10n.Settings.buttonRevert) { revert() }
                    .disabled(!settingsDiffer)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.Settings.LocalModel.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Settings.LocalModel.localProviderListed)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section(L10n.Settings.LocalModel.downloadSection) {
            LabeledContent(L10n.Settings.LocalModel.packageLabel) {
                Text(package.displayName)
            }

            LabeledContent(L10n.Settings.LocalModel.filesLabel) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(package.files) { file in
                        Text(file.fileName)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }

            LabeledContent(L10n.Settings.LocalModel.locationLabel) {
                Text(AgentLocalModelLocation.packageDirectory(package).path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            downloadStatusView
            finderStatusView

            HStack {
                Button(downloadButtonTitle) {
                    Task { await downloader.downloadRecommendedPackage() }
                }
                .disabled(isDownloading)

                Button(L10n.Settings.LocalModel.cancel) {
                    downloader.cancel()
                }
                .disabled(!isDownloading)

                Button(L10n.Settings.LocalModel.openFolder) {
                    openModelDirectory()
                }

                Button(findButtonTitle) {
                    Task { await finder.searchRecommendedPackage() }
                }
                .disabled(isFinding)

                Spacer()
            }

            Text(L10n.Settings.LocalModel.downloadHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            let loaded = AgentSettingsStore.loadLocalModelSettings()
            settings = loaded
            savedSettings = loaded
        }
    }

    @ViewBuilder
    private var downloadStatusView: some View {
        switch downloader.state {
        case .idle:
            Text(packageStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let fileName, let fileIndex, let fileCount, let fileProgress, let overallProgress, let bytesReceived, let totalBytes, let speed):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: max(0, min(1, overallProgress)))
                Text(L10n.Settings.LocalModel.progress("\(fileIndex)", "\(fileCount)", fileName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(L10n.Settings.LocalModel.downloaded(formatBytes(bytesReceived), formatBytes(totalBytes)))
                    Spacer()
                    Text("\(Int(fileProgress * 100))% · \(formatBytes(Int64(speed)))/s")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        case .finished:
            Label(L10n.Settings.LocalModel.installed, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(L10n.Settings.LocalModel.failed(message), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .canceled:
            Text(L10n.Settings.LocalModel.canceled)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var finderStatusView: some View {
        switch finder.state {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.Settings.LocalModel.findingLocalFiles)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let matches):
            if matches.isEmpty {
                Text(L10n.Settings.LocalModel.findNoResults)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Settings.LocalModel.findResults)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(matches.prefix(8)) { match in
                        localFileMatchRow(match)
                    }
                }
            }
        case .failed(let message):
            Label(L10n.Settings.LocalModel.findFailed(message), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func localFileMatchRow(_ match: AgentLocalModelFileMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.fileName)
                    .font(.system(size: 11, design: .monospaced))
                Text(match.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(matchQualityLabel(match.quality))
                    .font(.caption2)
                    .foregroundStyle(matchQualityColor(match.quality))
                Text(L10n.Settings.LocalModel.findSize(formatBytes(match.bytes), formatBytes(match.expectedBytes)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsDiffer: Bool {
        settings.normalized != savedSettings.normalized
    }

    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        return false
    }

    private var isFinding: Bool {
        if case .searching = finder.state { return true }
        return false
    }

    private var downloadButtonTitle: String {
        isDownloading ? L10n.Settings.LocalModel.downloading : L10n.Settings.LocalModel.download
    }

    private var findButtonTitle: String {
        isFinding ? L10n.Settings.LocalModel.findingLocalFiles : L10n.Settings.LocalModel.findLocalFiles
    }

    private var packageStatusText: String {
        if AgentLocalModelLocation.isInstalled(package) {
            return L10n.Settings.LocalModel.installed
        }
        return L10n.Settings.LocalModel.notInstalled
    }

    private func save() {
        let normalized = settings.normalized
        settings = normalized
        savedSettings = normalized
        AgentSettingsStore.saveLocalModelSettings(normalized)
        appState.syncLocalModelComposerProvider(settings: normalized)
        statusMessage = L10n.Settings.savedStatus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if statusMessage == L10n.Settings.savedStatus {
                statusMessage = ""
            }
        }
    }

    private func revert() {
        settings = savedSettings
        statusMessage = ""
    }

    private func openModelDirectory() {
        let directory = AgentLocalModelLocation.packageDirectory(package)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func matchQualityLabel(_ quality: AgentLocalModelFileMatch.Quality) -> String {
        switch quality {
        case .matched: return L10n.Settings.LocalModel.findMatched
        case .close: return L10n.Settings.LocalModel.findClose
        case .mismatch: return L10n.Settings.LocalModel.findMismatch
        }
    }

    private func matchQualityColor(_ quality: AgentLocalModelFileMatch.Quality) -> Color {
        switch quality {
        case .matched: return .green
        case .close: return .orange
        case .mismatch: return .secondary
        }
    }
}
