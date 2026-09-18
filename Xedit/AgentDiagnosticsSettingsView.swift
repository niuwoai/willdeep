import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings page for handing a support bundle to someone who can read it.
///
/// The screen is built around one decision the user has to make with their
/// eyes open: whether the zip carries their own material. Both levels state
/// what they contain in a sentence, and the counts are computed and shown
/// before the export button does anything — no quiet packing.
struct AgentDiagnosticsSettingsView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case project
        case session
        var id: String { rawValue }
    }

    @EnvironmentObject private var appState: AppState

    @State private var scope: Scope = .session
    @State private var selectedProjectID: UUID?
    @State private var selectedSessionID: AgentSession.ID?
    @State private var level: AgentDiagnosticsBundle.Level = .full
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text(L10n.Diagnostics.pageSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Diagnostics.scopeSection) {
                if appState.agentSessions.isEmpty {
                    Text(L10n.Diagnostics.scopeEmpty).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $scope) {
                        Text(L10n.Diagnostics.scopeProject).tag(Scope.project)
                        Text(L10n.Diagnostics.scopeSession).tag(Scope.session)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch scope {
                    case .project:
                        Picker(L10n.Diagnostics.scopeProjectPicker, selection: $selectedProjectID) {
                            ForEach(appState.agentProjects) { project in
                                Text(project.resolvedDisplayName).tag(Optional(project.id))
                            }
                        }
                    case .session:
                        Picker(L10n.Diagnostics.scopeSessionPicker, selection: $selectedSessionID) {
                            ForEach(sessionChoices, id: \.id) { session in
                                Text(session.title).tag(Optional(session.id))
                            }
                        }
                    }
                }
            }

            Section(L10n.Diagnostics.levelSection) {
                Picker("", selection: $level) {
                    Text(L10n.Diagnostics.levelTimingOnly).tag(AgentDiagnosticsBundle.Level.timingOnly)
                    Text(L10n.Diagnostics.levelFull).tag(AgentDiagnosticsBundle.Level.full)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(level == .timingOnly
                     ? L10n.Diagnostics.levelTimingOnlyHelp
                     : L10n.Diagnostics.levelFullHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Diagnostics.contentsSection) {
                let preview = currentPreview
                Text(L10n.Diagnostics.sessions(preview.sessionCount))
                Text(L10n.Diagnostics.timingLines(preview.timingLineCount))
                if preview.timingLineCount == 0 {
                    Text(L10n.Diagnostics.noTimingRecords)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if level == .full {
                    Text(L10n.Diagnostics.sandboxLines(preview.sandboxLineCount))
                    Text(L10n.Diagnostics.judgeLines(preview.judgeLineCount))
                }
                if let span = windowLabel(preview) {
                    Text(L10n.Diagnostics.window(span))
                }
                Label(
                    preview.includesUserContent
                        ? L10n.Diagnostics.hasUserContent
                        : L10n.Diagnostics.noUserContent,
                    systemImage: preview.includesUserContent ? "exclamationmark.triangle" : "checkmark.shield"
                )
                .foregroundStyle(preview.includesUserContent ? Color.orange : Color.secondary)
            }

            Section {
                HStack {
                    Button(isExporting ? L10n.Diagnostics.exporting : L10n.Diagnostics.exportButton) {
                        export()
                    }
                    .buttonStyle(DiagnosticsExportButtonStyle())
                    .disabled(isExporting || selectedSessionRefs.isEmpty)
                    if let exportedURL {
                        Button(L10n.Diagnostics.revealButton) {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                        }
                    }
                }
                if let exportedURL {
                    Text(L10n.Diagnostics.exported(exportedURL.lastPathComponent))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(L10n.Diagnostics.exportFailed(errorMessage))
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Text(L10n.Diagnostics.logLocation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(.primary)
        .navigationTitle(L10n.Diagnostics.pageTitle)
        .onAppear(perform: seedSelectionIfNeeded)
    }

    // MARK: - Selection

    private var sessionChoices: [AgentSession] {
        Array(appState.agentSessions.prefix(200))
    }

    private func seedSelectionIfNeeded() {
        if selectedSessionID == nil {
            selectedSessionID = appState.activeAgentSessionID ?? appState.agentSessions.first?.id
        }
        if selectedProjectID == nil {
            selectedProjectID = appState.agentProjects.first?.id
        }
    }

    /// The conversations the current scope resolves to. A project exports
    /// every conversation bound to it — a slow turn is rarely in the one
    /// conversation the user happens to remember.
    private var selectedSessionRefs: [AgentDiagnosticsBundle.SessionRef] {
        let sessions: [AgentSession]
        switch scope {
        case .project:
            guard let selectedProjectID else { return [] }
            sessions = appState.agentSessions.filter { $0.projectID == selectedProjectID }
        case .session:
            guard let selectedSessionID,
                  let session = appState.agentSessions.first(where: { $0.id == selectedSessionID }) else { return [] }
            sessions = [session]
        }
        return sessions.map {
            AgentDiagnosticsBundle.SessionRef(id: $0.id, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
    }

    private var bundleInput: AgentDiagnosticsBundle.Input {
        AgentDiagnosticsBundle.Input(
            sessions: selectedSessionRefs,
            level: level,
            auditDirectory: AgentSandboxAuditLog.directory,
            sessionsDirectory: AgentSessionStore.directory,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private var currentPreview: AgentDiagnosticsBundle.Preview {
        AgentDiagnosticsBundle.preview(for: bundleInput)
    }

    private func windowLabel(_ preview: AgentDiagnosticsBundle.Preview) -> String? {
        guard let start = preview.windowStart, let end = preview.windowEnd else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    // MARK: - Export

    private func export() {
        errorMessage = nil
        let panel = NSSavePanel()
        panel.title = L10n.Diagnostics.savePanelTitle
        panel.nameFieldStringValue = AgentDiagnosticsBundle.suggestedFileName(level: level)
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        let input = bundleInput
        Task { @MainActor in
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AgentDiagnosticsExport.write(input, to: destination)
                }.value
                exportedURL = url
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}

/// The one step that has to leave the process: `ditto` turns the staging
/// directory into the zip. Kept apart from the pure builder so the staging
/// logic stays testable without spawning anything.
nonisolated enum AgentDiagnosticsExport {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func write(_ input: AgentDiagnosticsBundle.Input, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("willdeep-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try AgentDiagnosticsBundle.stage(input, into: staging)
        try? fileManager.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errorData, encoding: .utf8) ?? ""
            throw Failure(reason: text.isEmpty ? "ditto exited \(process.terminationStatus)" : text)
        }
        return destination
    }
}

/// The export is the one action on this page, so it reads as the primary
/// button: label-colored fill with inverted text (black on white in light mode).
private struct DiagnosticsExportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(nsColor: .textBackgroundColor))
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.78 : 1))
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}
