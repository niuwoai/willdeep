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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                actionRow
                progressView
                footer
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
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
