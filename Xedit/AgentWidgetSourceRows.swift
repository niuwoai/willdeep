//
//  AgentWidgetSourceRows.swift
//  WillDeep
//
//  Source metadata and local reveal actions for Widget side-panel entries.
//

import AppKit
import SwiftUI

struct AgentWidgetSourceRows: View {
    @EnvironmentObject private var appState: AppState
    let widget: AgentWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(widget.sourceSummary, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let sourcePath = widget.sourcePath, !sourcePath.isEmpty {
                sourcePathRow(
                    path: sourcePath,
                    systemImage: "folder",
                    help: "在 Finder 中定位网页组件源文件"
                )
            }
            if let packageDirectory = widget.packageDirectory, !packageDirectory.isEmpty, packageDirectory != widget.sourcePath {
                sourcePathRow(
                    path: packageDirectory,
                    systemImage: "shippingbox",
                    help: "在 Finder 中定位制作包目录"
                )
            }
            if let note = widget.widgetContextNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func sourcePathRow(path: String, systemImage: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 0)
            if let url = resolvedWidgetSourceURL(path) {
                if isReloadableWidgetHTML(url) {
                    Button {
                        reloadWidgetHTML(from: url)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("重新载入网页组件源文件")
                }
                Button {
                    revealWidgetURL(url)
                } label: {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(help)
            }
        }
    }

    private func revealWidgetURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reloadWidgetHTML(from url: URL) {
        guard let runtimeID = appState.activeRuntime?.id,
              isReloadableWidgetHTML(url),
              let data = try? Data(contentsOf: url),
              data.count <= 1_048_576,
              let html = String(data: data, encoding: .utf8),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        var contextLines = widget.contextLines.filter { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("reloaded_from_widget_id:")
                && !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("reloaded_at:")
        }
        contextLines.append("reloaded_from_widget_id: \(widget.id.uuidString)")
        contextLines.append("reloaded_at: \(Self.isoFormatter.string(from: Date()))")
        contextLines.append("html_path: \(url.path)")
        let reloaded = AgentWidget(
            title: widget.title,
            html: html,
            contextLines: contextLines,
            sourceBaseURL: url.deletingLastPathComponent()
        )
        AgentWidgetRegistry.shared.add(reloaded, forRuntime: runtimeID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func isReloadableWidgetHTML(_ url: URL) -> Bool {
        ["html", "htm", "svg"].contains(url.pathExtension.lowercased())
    }

    private func resolvedWidgetSourceURL(_ rawPath: String) -> URL? {
        AgentWidgetPathResolver.resolveExisting(rawPath, workspaceRoot: resolvedWorkspaceRoot())
    }

    private func resolvedWorkspaceRoot() -> URL? {
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return appState.rootDirectory?.standardizedFileURL
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
