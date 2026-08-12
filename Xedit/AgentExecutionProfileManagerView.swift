//
//  AgentExecutionProfileManagerView.swift
//  WillDeep
//

import SwiftUI

struct AgentExecutionProfileManagerView: View {
    @EnvironmentObject private var appState: AppState

    let workspacePath: String?
    let onChanged: () -> Void
    let onClose: () -> Void

    @State private var profiles: [AgentExecutionProfile] = []
    @State private var selectedID: String?
    @State private var draft: AgentExecutionProfile?
    @State private var availableExecutors = AgentDispatchExecutorResolver.localAvailableExecutors()

    private let store = AgentExecutionProfileStore()

    private var providerEntries: [AgentProviderEntry] {
        appState.agentProviderLibrary.entries
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                profileList
                    .frame(minWidth: 250, idealWidth: 280)
                editor
                    .frame(minWidth: 390)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.gearshape")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Dispatch.profileManagerTitle)
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.Dispatch.profileManagerMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(profiles) { profile in
                    HStack(spacing: 9) {
                        Image(systemName: profile.executor.symbol)
                            .frame(width: 18)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(profile.displayDetail)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(originLabel(profile.origin))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if !availableExecutors.contains(profile.executor) {
                            Text(L10n.Dispatch.workerUnavailable)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .tag(profile.id)
                }
            }
            .onChange(of: selectedID) { selectedID in
                if draft?.id != selectedID {
                    saveDraft()
                }
                draft = profiles.first { $0.id == selectedID }
            }
            Divider()
            HStack {
                Button {
                    saveDraft()
                    let profile = AgentExecutionProfile(
                        name: L10n.Dispatch.addProfile,
                        executor: .codexCLI
                    )
                    profiles.append(profile)
                    selectedID = profile.id
                    draft = profile
                } label: {
                    Label(L10n.Dispatch.addProfile, systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let draft {
            Form {
                Section {
                    TextField(
                        L10n.Dispatch.profileName,
                        text: binding(\.name, fallback: "")
                    )
                    .disabled(draft.origin != .managed)
                    Picker(
                        L10n.Dispatch.executor,
                        selection: binding(\.executor, fallback: .willDeep)
                    ) {
                        ForEach(AgentExecutionAgent.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .disabled(draft.origin != .managed)
                    if draft.executor == .willDeep {
                        Picker(
                            L10n.Dispatch.providerID,
                            selection: providerBinding
                        ) {
                            ForEach(providerEntries) { entry in
                                Text(entry.displayName).tag(entry.id)
                            }
                        }
                        .disabled(providerEntries.isEmpty)

                        Picker(
                            L10n.Dispatch.modelID,
                            selection: modelBinding
                        ) {
                            ForEach(selectedProviderModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .disabled(selectedProviderModels.isEmpty)
                    } else {
                        TextField(
                            L10n.Dispatch.modelID,
                            text: optionalBinding(\.modelID)
                        )
                        TextField(
                            L10n.Dispatch.providerID,
                            text: optionalBinding(\.providerID)
                        )
                    }
                    TextField(
                        L10n.Dispatch.nativeProfile,
                        text: optionalBinding(\.nativeProfileName)
                    )
                    .disabled(draft.executor == .willDeep)
                }
                if draft.origin != .managed {
                    Text(originLabel(draft.origin))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(draft.origin == .discovered)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.gearshape")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(L10n.Dispatch.profileManagerTitle)
                    .font(.headline)
                Text(L10n.Dispatch.profileManagerMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                guard let selectedID else { return }
                profiles.removeAll {
                    $0.id == selectedID && $0.origin == .managed
                }
                self.selectedID = profiles.first?.id
                draft = profiles.first
                persist()
            } label: {
                Label(L10n.Dispatch.deleteProfile, systemImage: "trash")
            }
            .disabled(draft?.origin != .managed)
            Spacer()
            Button(L10n.CloseTab.ok) {
                saveDraft()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func reload() {
        availableExecutors = AgentDispatchExecutorResolver.localAvailableExecutors()
        profiles = store.availableProfiles(workspacePath: workspacePath)
        selectedID = profiles.first?.id
        draft = profiles.first
    }

    private func saveDraft() {
        guard let draft, draft.origin != .discovered else { return }
        if let index = profiles.firstIndex(where: { $0.id == draft.id }) {
            profiles[index] = draft
        }
        persist()
    }

    private func persist() {
        store.saveManaged(profiles)
        onChanged()
    }

    private var selectedProviderEntry: AgentProviderEntry? {
        guard let draft else { return nil }
        return providerEntries.first { entry in
            entry.providerID == draft.providerID
                && AgentExecutionProfileModelCatalog.models(for: entry).contains {
                    $0.caseInsensitiveCompare(draft.modelID ?? "") == .orderedSame
                }
        }
            ?? providerEntries.first { $0.providerID == draft.providerID }
            ?? providerEntries.first
    }

    private var selectedProviderModels: [String] {
        guard let entry = selectedProviderEntry else { return [] }
        return AgentExecutionProfileModelCatalog.models(for: entry)
    }

    private var providerBinding: Binding<UUID> {
        Binding(
            get: { selectedProviderEntry?.id ?? providerEntries.first?.id ?? UUID() },
            set: { entryID in
                guard var updated = draft,
                      let entry = providerEntries.first(where: { $0.id == entryID }) else { return }
                let models = AgentExecutionProfileModelCatalog.models(for: entry)
                updated.providerID = entry.providerID
                updated.modelID = models.first
                draft = updated
                appState.materializeProviderLibraryEntryAPIKey(id: entry.id)
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft?.modelID ?? selectedProviderModels.first ?? "" },
            set: { model in
                guard var updated = draft else { return }
                updated.modelID = model
                updated.providerID = selectedProviderEntry?.providerID
                draft = updated
            }
        )
    }

    private func originLabel(_ origin: AgentExecutionProfileOrigin) -> String {
        switch origin {
        case .builtIn: return L10n.Dispatch.profileBuiltIn
        case .managed: return L10n.Dispatch.profileManaged
        case .discovered: return L10n.Dispatch.profileDiscovered
        }
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AgentExecutionProfile, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var updated = draft else { return }
                updated[keyPath: keyPath] = value
                draft = updated
            }
        )
    }

    private func optionalBinding(
        _ keyPath: WritableKeyPath<AgentExecutionProfile, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var updated = draft else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updated[keyPath: keyPath] = trimmed.isEmpty ? nil : value
                draft = updated
            }
        )
    }
}
