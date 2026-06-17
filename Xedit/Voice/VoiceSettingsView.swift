//
//  VoiceSettingsView.swift
//  WillDeep
//
//  Phase 2 voice-to-text settings panel. Lives inside the existing
//  EditorSettingsView "AI Providers" tab as its own Section. Surfaces
//  three actions:
//   1. Import from fastv (0-download symlink)
//   2. Download SenseVoice model (~937 MB)
//   3. Show where the model lives + how to wipe it
//

import SwiftUI

struct VoiceSettingsView: View {
    @StateObject private var downloader = VoiceModelDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: VoiceModelDownloader.isModelInstalled ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(VoiceModelDownloader.isModelInstalled ? .green : .secondary)
                Text(VoiceModelDownloader.isModelInstalled
                     ? "SenseVoice model installed"
                     : "SenseVoice model not yet downloaded")
                    .font(.system(size: 12))
            }

            Text("`/transcribe` and other voice features run 100% on-device using SenseVoice ONNX. The ~937 MB model lives at `\(VoiceModelLocation.modelDirectory.path)`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            stateView

            HStack(spacing: 8) {
                if VoiceModelDownloader.canImportFromFastv && !VoiceModelDownloader.isModelInstalled {
                    Button("Import from fastv") {
                        Task { try? await downloader.importFromFastv() }
                    }
                    .disabled(isBusy)
                    .help("Symlink an existing fastv model copy — 0 bytes downloaded.")
                }

                if !VoiceModelDownloader.isModelInstalled {
                    Button("Download (~937 MB)") {
                        Task { await downloader.download() }
                    }
                    .disabled(isBusy)
                    .help("Stream the model file from the CDN. Resume on failure is NOT supported in this rc — start over if interrupted.")
                }

                if isBusy {
                    Button("Cancel") {
                        downloader.cancel()
                    }
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch downloader.state {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Importing from fastv…").font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let progress, let received, let total, let speed):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress, total: 1.0)
                Text("\(formatBytes(received)) / \(formatBytes(total)) — \(formatBytes(Int64(speed)))/s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .finished:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready. Use `/transcribe <path>` in agent composer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
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
