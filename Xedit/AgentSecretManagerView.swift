//
//  AgentSecretManagerView.swift
//  WillDeep
//
//  The one saved-secret list, shared by the Composer's lock sheet and the
//  Settings pane. Two entry points used to mean two list implementations
//  drifting apart; this view is the single one, with `mode` deciding whether
//  a row can be inserted into the Composer.
//
//  Values never appear here. Copy authenticates the device owner first
//  (`AgentSecretStore.revealSecretForCopy`), everything else operates on the
//  label and the identifier only.
//

import SwiftUI

struct AgentSecretManagerView: View {
    enum Mode {
        /// Composer sheet: rows insert a `${secret:...}` placeholder.
        case insert
        /// Settings pane: manage only.
        case manage
    }

    let mode: Mode
    var maxListHeight: CGFloat = 240
    var onInsertPlaceholder: ((String) -> Void)?

    @State private var secrets: [AgentSavedSecret] = []
    @State private var query = ""
    @State private var pageIndex = 0
    @State private var copiedSecretID: String?
    @State private var renameTarget: AgentSavedSecret?
    @State private var renameDraft = ""
    @State private var deleteTarget: AgentSavedSecret?

    private var filtered: [AgentSavedSecret] {
        AgentSecretSearch.filter(secrets, query: query)
    }

    private var pageCount: Int {
        AgentSecretSearch.pageCount(itemCount: filtered.count)
    }

    private var visible: [AgentSavedSecret] {
        AgentSecretSearch.page(filtered, pageIndex: pageIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField

            if secrets.isEmpty {
                emptyState(L10n.Composer.savedSecretsEmpty)
            } else if filtered.isEmpty {
                emptyState(L10n.SecretManager.noResults)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { secret in
                            row(secret)
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)

                if pageCount > 1 {
                    paginator
                }
            }
        }
        .onAppear(perform: reload)
        // A filtered list is shorter than the full one, so the page the user
        // was on may no longer exist.
        .onCompatibleChange(of: query) { _, _ in
            pageIndex = 0
        }
        .alert(L10n.SecretManager.renameTitle, isPresented: renameAlertBinding) {
            TextField(L10n.Composer.secretLabelPlaceholder, text: $renameDraft)
            Button(L10n.Automation.cancel, role: .cancel) { renameTarget = nil }
            Button(L10n.SecretManager.renameConfirm) { commitRename() }
        } message: {
            Text(L10n.SecretManager.renameMessage(renameTarget?.placeholder ?? ""))
        }
        .alert(L10n.SecretManager.deleteTitle, isPresented: deleteAlertBinding) {
            Button(L10n.Automation.cancel, role: .cancel) { deleteTarget = nil }
            Button(L10n.SecretManager.deleteConfirm, role: .destructive) { commitDelete() }
        } message: {
            Text(L10n.SecretManager.deleteMessage(deleteTarget.map(displayLabel) ?? ""))
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L10n.SecretManager.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.SecretManager.clearSearch)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private func row(_ secret: AgentSavedSecret) -> some View {
        HStack(spacing: 6) {
            if mode == .insert {
                Button {
                    onInsertPlaceholder?(secret.placeholder)
                } label: {
                    rowLabel(secret, showsInsertAffordance: true)
                }
                .buttonStyle(.plain)
                .help(L10n.Composer.savedSecretInsertHelp)
            } else {
                rowLabel(secret, showsInsertAffordance: false)
            }

            Button {
                copy(secret)
            } label: {
                Image(systemName: copiedSecretID == secret.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.Composer.savedSecretCopyHelp)

            Menu {
                Button(L10n.SecretManager.rename) {
                    renameDraft = secret.label
                    renameTarget = secret
                }
                Divider()
                Button(L10n.SecretManager.delete, role: .destructive) {
                    deleteTarget = secret
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help(L10n.SecretManager.rowActions)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func rowLabel(_ secret: AgentSavedSecret, showsInsertAffordance: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AgentComposerChrome.iconPrimary)
                .frame(width: 22, height: 22)
                .background(AgentComposerChrome.selectedControlFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayLabel(secret))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(secret.placeholder)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsInsertAffordance {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(AgentComposerChrome.iconPrimary)
            }
        }
        .contentShape(Rectangle())
    }

    private var paginator: some View {
        HStack(spacing: 8) {
            Button {
                pageIndex = max(0, pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pageIndex <= 0)
            .help(L10n.SecretManager.previousPage)

            Text(L10n.SecretManager.pageIndicator(pageIndex + 1, pageCount))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                pageIndex = min(pageCount - 1, pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pageIndex >= pageCount - 1)
            .help(L10n.SecretManager.nextPage)

            Spacer()

            Text(L10n.SecretManager.totalCount(filtered.count))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    func reload() {
        secrets = AgentSecretStore.savedSecrets()
        pageIndex = AgentSecretSearch.clampedPageIndex(pageIndex, itemCount: filtered.count)
    }

    private func displayLabel(_ secret: AgentSavedSecret) -> String {
        guard secret.label.isEmpty else { return secret.label }
        return L10n.Composer.legacySecretLabel(String(secret.identifier.prefix(8)))
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        AgentSecretStore.renameSecret(identifier: target.identifier, label: renameDraft)
        renameTarget = nil
        reload()
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        AgentSecretStore.deleteSecret(identifier: target.identifier)
        deleteTarget = nil
        reload()
    }

    private func copy(_ secret: AgentSavedSecret) {
        Task { @MainActor in
            guard let value = await AgentSecretStore.revealSecretForCopy(
                identifier: secret.identifier,
                reason: L10n.Composer.savedSecretCopyReason
            ) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            copiedSecretID = secret.id
            try? await Task.sleep(for: .seconds(1.5))
            if copiedSecretID == secret.id {
                copiedSecretID = nil
            }
        }
    }
}

// MARK: - New-secret editor

/// The "add secrets" half of the lock sheet, extracted so the Settings pane
/// can add secrets without the Composer's insert flow.
struct AgentSecretRowsEditor: View {
    @Binding var rows: [AgentSecretInput]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                AgentSecretInputRow(
                    ordinal: index + 1,
                    label: $rows[index].label,
                    secret: $rows[index].secret,
                    shouldFocusOnAppear: index == 0,
                    canRemove: rows.count > 1,
                    onRemove: { removeRow(at: index) }
                )
            }
            if rows.count < AgentSecretStore.maxBatchInsertCount {
                Button {
                    rows.append(AgentSecretInput(label: "", secret: ""))
                } label: {
                    Label(L10n.Composer.addSecretAction, systemImage: "plus")
                }
                .buttonStyle(.link)
                .help(L10n.Composer.addSecretHelp)
            }
        }
    }

    private func removeRow(at index: Int) {
        guard rows.indices.contains(index), rows.count > 1 else { return }
        rows.remove(at: index)
    }
}

struct AgentSecretInputRow: View {
    let ordinal: Int
    @Binding var label: String
    @Binding var secret: String
    let shouldFocusOnAppear: Bool
    let canRemove: Bool
    let onRemove: () -> Void
    @FocusState private var labelFocused: Bool
    @FocusState private var secretFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(ordinal)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                TextField(L10n.Composer.secretLabelPlaceholder, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .focused($labelFocused)
                SecureField(L10n.Composer.secretValuePlaceholder, text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .focused($secretFocused)
                if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(AgentSecretStore.placeholder(identifier: AgentSecretStore.normalizedAlias(label)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(canRemove ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .help(L10n.Composer.removeSecretHelp)
            .padding(.top, 4)
        }
        .onAppear {
            guard shouldFocusOnAppear else { return }
            DispatchQueue.main.async { labelFocused = true }
        }
    }
}

/// Rows valid enough to save: both halves filled in.
enum AgentSecretRowValidation {
    static func validCount(_ rows: [AgentSecretInput]) -> Int {
        rows.filter {
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    static func hasIncompleteRow(_ rows: [AgentSecretInput]) -> Bool {
        rows.contains {
            let hasLabel = !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSecret = !$0.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasLabel != hasSecret
        }
    }
}
