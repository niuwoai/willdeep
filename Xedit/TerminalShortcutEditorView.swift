import SwiftUI

struct TerminalShortcutEditorRequest: Codable, Hashable {
    let shortcutID: UUID
}

struct TerminalShortcutEditorWindowRoot: View {
    @Binding var request: TerminalShortcutEditorRequest?
    @ObservedObject private var registry = EditorAppStateRegistry.shared

    var body: some View {
        Group {
            if let request, let appState = registry.current {
                TerminalShortcutEditorView(
                    controller: appState.agentTerminalController,
                    shortcutID: request.shortcutID
                )
                .environmentObject(appState)
            } else {
                ProgressView()
            }
        }
        .onAppear { registry.ensureHeadlessFallback() }
    }
}

private enum TerminalShortcutSecretStatus: String, CaseIterable, Identifiable {
    case all
    case saved
    case missing

    var id: String { rawValue }
}

private struct TerminalShortcutSecretRow: Identifiable {
    let event: TerminalShortcutEvent
    let index: Int
    let account: String
    let isSaved: Bool

    var id: UUID { event.id }
    var name: String {
        event.protectedPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? L10n.AgentTerminal.shortcutSecretDefaultName("\(index + 1)")
    }
}

private struct TerminalShortcutEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: AgentInteractiveTerminalController
    let shortcutID: UUID

    @State private var jsonText = ""
    @State private var parsedShortcut: TerminalShortcut?
    @State private var validationError: String?
    @State private var searchText = ""
    @State private var statusFilter: TerminalShortcutSecretStatus = .all
    @State private var pageSize = 25
    @State private var page = 0
    @State private var secretDrafts: [UUID: String] = [:]
    @State private var savedSecretAccounts: Set<String> = []
    @State private var saveMessage: String?
    @State private var isDirty = false

    private var palette: EditorInterfaceSkinPalette { appState.editorSettings.interfaceSkin.palette }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            jsonEditor
            Divider()
            secretsDrawer
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(appState.editorSettings.interfaceSkin.windowBackground)
        .onAppear(perform: loadCanonicalShortcut)
        .onChange(of: jsonText) { _ in
            validateJSON()
            isDirty = true
        }
        .navigationTitle(L10n.AgentTerminal.shortcutEditorTitle)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(L10n.AgentTerminal.shortcutEditorTitle)
                .font(.system(size: 14, weight: .semibold))
            Divider().frame(height: 20)
            Text(parsedShortcut?.title ?? L10n.AgentTerminal.shortcutDefaultTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            validationBadge
            Spacer()
            if let saveMessage {
                Text(saveMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
            }
            Button(L10n.AgentTerminal.shortcutEditorCancel) { dismiss() }
            Button(L10n.AgentTerminal.shortcutEditorSave) { save() }
                .buttonStyle(.borderedProminent)
                .disabled(validationError != nil || !isDirty)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(palette.panelFill)
    }

    @ViewBuilder
    private var validationBadge: some View {
        Label(
            validationError == nil ? L10n.AgentTerminal.shortcutEditorJSONValid : L10n.AgentTerminal.shortcutEditorJSONInvalid,
            systemImage: validationError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(validationError == nil ? Color.green : Color.orange)
    }

    private var jsonEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $jsonText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(palette.previewBase)
            HStack {
                if let validationError {
                    Text(validationError).foregroundStyle(Color.orange)
                } else {
                    Text(L10n.AgentTerminal.shortcutEditorJSONHint)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Text(L10n.AgentTerminal.shortcutEditorJSON)
                    .foregroundStyle(palette.secondaryText)
            }
            .font(.system(size: 10))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(palette.panelFill)
        }
        .frame(minHeight: 260)
    }

    private var secretsDrawer: some View {
        VStack(spacing: 0) {
            secretsHeader
            Divider()
            secretColumnHeaders
            Divider()
            if pagedSecrets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.AgentTerminal.shortcutSecretsEmpty)
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.AgentTerminal.shortcutSecretsEmptyDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pagedSecrets) { row in
                            secretRow(row)
                            Divider()
                        }
                    }
                }
            }
            secretsFooter
        }
        .frame(minHeight: 230, idealHeight: 285, maxHeight: 330)
        .background(palette.panelFill)
    }

    private var secretsHeader: some View {
        HStack(spacing: 10) {
            Label(L10n.AgentTerminal.shortcutSecretsCount("\(secretRows.count)"), systemImage: "key.horizontal")
                .font(.system(size: 12, weight: .semibold))
            TextField(L10n.AgentTerminal.shortcutSecretsSearch, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onChange(of: searchText) { _ in page = 0 }
            Picker(L10n.AgentTerminal.shortcutSecretsStatus, selection: $statusFilter) {
                Text(L10n.AgentTerminal.shortcutSecretsAll).tag(TerminalShortcutSecretStatus.all)
                Text(L10n.AgentTerminal.shortcutSecretsSaved).tag(TerminalShortcutSecretStatus.saved)
                Text(L10n.AgentTerminal.shortcutSecretsMissing).tag(TerminalShortcutSecretStatus.missing)
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: statusFilter) { _ in page = 0 }
            Spacer()
            Text(L10n.AgentTerminal.shortcutSecretsSafety)
                .font(.system(size: 10))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            Button {
                addSecretEvent()
            } label: {
                Label(L10n.AgentTerminal.shortcutSecretsAdd, systemImage: "plus")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var secretColumnHeaders: some View {
        HStack(spacing: 12) {
            Text(L10n.AgentTerminal.shortcutSecretName).frame(width: 150, alignment: .leading)
            Text(L10n.AgentTerminal.shortcutSecretReference).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.AgentTerminal.shortcutSecretValue).frame(width: 240, alignment: .leading)
            Text(L10n.AgentTerminal.shortcutSecretState).frame(width: 80, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func secretRow(_ row: TerminalShortcutSecretRow) -> some View {
        HStack(spacing: 12) {
            Text(row.name).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(row.account)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            SecureField(
                row.isSaved ? L10n.AgentTerminal.shortcutSecretReplacePlaceholder : L10n.AgentTerminal.shortcutSecretEnterPlaceholder,
                text: secretBinding(for: row.id)
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            Label(
                row.isSaved ? L10n.AgentTerminal.shortcutSecretsSaved : L10n.AgentTerminal.shortcutSecretsMissing,
                systemImage: row.isSaved ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(row.isSaved ? Color.green : Color.orange)
            .frame(width: 80, alignment: .leading)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var secretsFooter: some View {
        HStack {
            Picker(L10n.AgentTerminal.shortcutSecretsPageSize, selection: $pageSize) {
                Text(L10n.AgentTerminal.shortcutSecretsPerPage("25")).tag(25)
                Text(L10n.AgentTerminal.shortcutSecretsPerPage("50")).tag(50)
                Text(L10n.AgentTerminal.shortcutSecretsPerPage("100")).tag(100)
            }
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: pageSize) { _ in page = 0 }
            Spacer()
            Text(pageSummary)
                .font(.system(size: 10))
                .foregroundStyle(palette.secondaryText)
            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0)
            Button { page = min(maxPage, page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(page >= maxPage)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var secretRows: [TerminalShortcutSecretRow] {
        guard let parsedShortcut else { return [] }
        return parsedShortcut.events.enumerated().compactMap { index, event in
            guard event.requiresEchoOff else { return nil }
            let account = event.protectedBytesReference
                ?? TerminalShortcutStore.protectedInputAccount(shortcutID: shortcutID, eventID: event.id)
            return TerminalShortcutSecretRow(
                event: event,
                index: index,
                account: account,
                isSaved: savedSecretAccounts.contains(account)
            )
        }
    }

    private var filteredSecrets: [TerminalShortcutSecretRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return secretRows.filter { row in
            let statusMatches = statusFilter == .all
                || (statusFilter == .saved && row.isSaved)
                || (statusFilter == .missing && !row.isSaved)
            let queryMatches = query.isEmpty
                || row.name.localizedCaseInsensitiveContains(query)
                || row.account.localizedCaseInsensitiveContains(query)
            return statusMatches && queryMatches
        }
    }

    private var pagedSecrets: [TerminalShortcutSecretRow] {
        let start = min(page * pageSize, filteredSecrets.count)
        let end = min(start + pageSize, filteredSecrets.count)
        return Array(filteredSecrets[start..<end])
    }

    private var maxPage: Int { max(0, (filteredSecrets.count - 1) / pageSize) }

    private var pageSummary: String {
        guard !filteredSecrets.isEmpty else { return L10n.AgentTerminal.shortcutSecretsPageSummary("0", "0", "0") }
        let start = page * pageSize + 1
        let end = min((page + 1) * pageSize, filteredSecrets.count)
        return L10n.AgentTerminal.shortcutSecretsPageSummary("\(start)", "\(end)", "\(filteredSecrets.count)")
    }

    private func secretBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { secretDrafts[id, default: ""] },
            set: { secretDrafts[id] = $0; isDirty = true }
        )
    }

    private func loadCanonicalShortcut() {
        do {
            guard let shortcut = try TerminalShortcutStore.loadEditableShortcuts().first(where: { $0.id == shortcutID }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            jsonText = try TerminalShortcutStore.editableJSON(for: shortcut)
            savedSecretAccounts = TerminalShortcutProtectedVault.existingAccounts()
            parsedShortcut = shortcut
            validationError = nil
            isDirty = false
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func validateJSON() {
        do {
            parsedShortcut = try TerminalShortcutStore.decodeEditableShortcut(jsonText, expectedID: shortcutID)
            validationError = nil
            page = min(page, maxPage)
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func addSecretEvent() {
        guard var shortcut = parsedShortcut else { return }
        let eventID = UUID()
        shortcut.events.append(
            TerminalShortcutEvent(
                id: eventID,
                delayMilliseconds: 0,
                bytes: [],
                requiresEchoOff: true,
                protectedBytesReference: TerminalShortcutStore.protectedInputAccount(
                    shortcutID: shortcutID,
                    eventID: eventID
                ),
                protectedPlaceholder: L10n.AgentTerminal.shortcutSecretDefaultName("\(secretRows.count + 1)")
            )
        )
        shortcut.hasProtectedInput = true
        if let updatedJSON = try? TerminalShortcutStore.editableJSON(for: shortcut) {
            jsonText = updatedJSON
        }
    }

    private func save() {
        do {
            try controller.saveShortcutEdit(id: shortcutID, json: jsonText, protectedValues: secretDrafts)
            secretDrafts.removeAll()
            loadCanonicalShortcut()
            saveMessage = L10n.AgentTerminal.shortcutEditorSaved
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
