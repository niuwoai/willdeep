//
//  AgentProfileSettingsView.swift
//  WillDeep
//
//  Settings → AI → Agent profiles. One pane for what used to be two places:
//  the subagent trades `spawn_agent` picks from, and the execution profiles a
//  dispatch node runs on. See docs/AGENT_PROFILE_UNIFICATION_DESIGN.md.
//
//  What is deliberately NOT editable here:
//   - a built-in trade's tool set and budgets (code, and the reason it is
//     cheap and accurate);
//   - write access (the editor trade's narrow door, gated by approval + lock);
//   - the runner's invariant prompt rules.
//  Fields that cannot apply to a profile's execution form are disabled with
//  the reason stated, rather than accepted and silently ignored.
//

import SwiftUI

struct AgentProfileSettingsView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all, subagent, dispatch
        var id: String { rawValue }

        @MainActor var title: String {
            switch self {
            case .all: return L10n.AgentProfiles.filterAll
            case .subagent: return L10n.AgentProfiles.filterSubagent
            case .dispatch: return L10n.AgentProfiles.filterDispatch
            }
        }

        var usage: AgentProfile.Usage? {
            switch self {
            case .all: return nil
            case .subagent: return .subagent
            case .dispatch: return .dispatch
            }
        }
    }

    @EnvironmentObject private var appState: AppState

    @State private var profiles: [AgentProfile] = []
    @State private var selectedID: String?
    @State private var filter: Filter = .all
    @State private var deleteTarget: AgentProfile?

    private let store = AgentProfileStore()

    private var visibleProfiles: [AgentProfile] {
        let publicProfiles = profiles.filter { profile in
            profile.origin != .builtIn
                || !profile.usages.contains(.subagent)
                || profile.usages.contains(.dispatch)
                || AgentSubagentProfileCatalog.isPublic(id: profile.id)
        }
        guard let usage = filter.usage else { return publicProfiles }
        return publicProfiles.filter { $0.usages.contains(usage) }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return profiles.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        Form {
            Section {
                Text(L10n.AgentProfiles.paneDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ForEach(visibleProfiles) { profile in
                    profileRow(profile)
                }

                HStack {
                    Button {
                        addProfile()
                    } label: {
                        Label(L10n.AgentProfiles.addProfile, systemImage: "plus")
                    }
                    Spacer()
                }
            }

            if let index = selectedIndex {
                editor(index: index)
            } else {
                Section {
                    Text(L10n.AgentProfiles.emptySelection)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .alert(L10n.AgentProfiles.deleteTitle, isPresented: deleteAlertBinding) {
            Button(L10n.Automation.cancel, role: .cancel) { deleteTarget = nil }
            Button(L10n.SecretManager.deleteConfirm, role: .destructive) { commitDelete() }
        } message: {
            Text(L10n.AgentProfiles.deleteMessage(deleteTarget?.localizedName ?? ""))
        }
    }

    // MARK: - List

    private func profileRow(_ profile: AgentProfile) -> some View {
        Button {
            selectedID = profile.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: profile.runtime.executor.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selectedID == profile.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.localizedName)
                            .font(.system(size: 12, weight: .medium))
                        Text(originLabel(profile.origin))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if profile.soul.hasUserContent {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(detailLine(profile))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(usageLabel(profile))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detailLine(_ profile: AgentProfile) -> String {
        // A hosted trade must advertise the model it will actually run on,
        // not the binding it would use signed out — the list is where users
        // check what a trade costs them. An explicit override wins here too,
        // otherwise the row would keep advertising a model the trade no
        // longer calls.
        if profile.runtime.modelBinding.model?.isEmpty != false,
           let hosted = recommendedHostedModel(for: profile) {
            return "some.im · \(hosted)"
        }
        let model = profile.runtime.modelBinding.model ?? L10n.AgentProfiles.modelPlaceholder
        return "\(profile.runtime.executor.displayName) · \(model)"
    }

    private func usageLabel(_ profile: AgentProfile) -> String {
        profile.usages
            .sorted { $0.rawValue < $1.rawValue }
            .map { $0 == .subagent ? L10n.AgentProfiles.filterSubagent : L10n.AgentProfiles.filterDispatch }
            .joined(separator: " · ")
    }

    private func originLabel(_ origin: AgentProfile.Origin) -> String {
        switch origin {
        case .builtIn: return L10n.AgentProfiles.originBuiltIn
        case .managed: return L10n.AgentProfiles.originManaged
        case .discovered: return L10n.AgentProfiles.originDiscovered
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editor(index: Int) -> some View {
        let profile = profiles[index]
        let isManaged = profile.origin == .managed

        Section(L10n.AgentProfiles.sectionProfile) {
            if isManaged {
                TextField(L10n.AgentProfiles.fieldName, text: nameBinding(index))
            } else {
                LabeledContent(L10n.AgentProfiles.fieldName) {
                    Text(profile.localizedName).foregroundStyle(.secondary)
                }
            }

            LabeledContent(L10n.AgentProfiles.fieldUsages) {
                HStack(spacing: 12) {
                    Toggle(L10n.AgentProfiles.usageSubagent, isOn: usageBinding(index, usage: .subagent))
                    Toggle(L10n.AgentProfiles.usageDispatch, isOn: usageBinding(index, usage: .dispatch))
                }
                .toggleStyle(.checkbox)
                // A built-in trade is what `spawn_agent`'s schema documents;
                // repurposing it as a dispatch executor is a custom-profile
                // job, not a checkbox on the built-in.
                .disabled(!isManaged)
            }

            if isManaged {
                Picker(L10n.AgentProfiles.fieldExecutor, selection: executorBinding(index)) {
                    ForEach(AgentExecutionAgent.allCases) { executor in
                        Text(executor.displayName).tag(executor)
                    }
                }
            } else {
                LabeledContent(L10n.AgentProfiles.fieldExecutor) {
                    Text(profile.runtime.executor.displayName).foregroundStyle(.secondary)
                }
            }

            if !profile.runtime.isInProcess {
                TextField(
                    L10n.AgentProfiles.fieldNativeProfile,
                    text: nativeProfileBinding(index)
                )
                .disabled(profile.origin == .discovered)
            }
        }

        Section(L10n.AgentProfiles.sectionModel) {
            // A managed trade recommends its relay-hosted model, and used to
            // be locked to it on the theory that the server-side job prompt
            // and the model it was tuned for must travel together. They still
            // do — but that is enforced where it actually happens
            // (`jobPromptIsHosted` is derived from the model being called, so
            // pointing a trade elsewhere switches it to the client-side copy
            // of the same prompt). Locking the row on top of that only took
            // the choice away.
            if let hostedModel = recommendedHostedModel(for: profile) {
                HStack(spacing: 8) {
                    TextField(
                        hostedModel,
                        text: modelBinding(index)
                    )
                    .textFieldStyle(.roundedBorder)
                    Menu {
                        Button(L10n.AgentProfiles.hostedModelRecommended(hostedModel)) {
                            modelBinding(index).wrappedValue = ""
                        }
                        Divider()
                        ForEach(modelOptions(for: profile), id: \.self) { model in
                            Button(model) { modelBinding(index).wrappedValue = model }
                        }
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 16, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                Text(
                    profile.runtime.modelBinding.model?.isEmpty == false
                        ? L10n.AgentProfiles.hostedModelOverridden
                        : L10n.AgentProfiles.hostedModelUsingRecommended(hostedModel)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(L10n.AgentProfiles.fieldProvider, selection: providerBinding(index)) {
                    Text(L10n.AgentProfiles.modelPlaceholder).tag(Optional<UUID>.none)
                    ForEach(appState.agentProviderLibrary.entries) { entry in
                        Text(entry.displayName).tag(Optional(entry.id))
                    }
                }
                .disabled(profile.origin == .discovered)

                HStack(spacing: 8) {
                    TextField(L10n.AgentProfiles.modelPlaceholder, text: modelBinding(index))
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(modelOptions(for: profile), id: \.self) { model in
                            Button(model) { modelBinding(index).wrappedValue = model }
                        }
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 16, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(modelOptions(for: profile).isEmpty)
                    .help(L10n.AgentDelegation.profilePickFetchedModel)
                }
                .disabled(profile.origin == .discovered)
            }

            contextWindowField(index: index, profile: profile)
        }

        Section(L10n.AgentProfiles.sectionSoul) {
            if !profile.soulApplies {
                Text(L10n.AgentProfiles.soulExternalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isManaged {
                TextField(L10n.AgentProfiles.purposePlaceholder, text: purposeBinding(index), axis: .vertical)
                    .lineLimit(1...3)
            } else {
                LabeledContent(L10n.AgentProfiles.fieldPurpose) {
                    Text(profile.soul.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.AgentProfiles.fieldPrompt)
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: promptBinding(index))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                Text(L10n.AgentProfiles.promptNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!profile.soulApplies)

            LabeledContent(L10n.AgentProfiles.fieldSkills) {
                skillsMenu(index: index, profile: profile)
            }
            .disabled(!profile.soulApplies)
        }

        Section(L10n.AgentProfiles.sectionCapability) {
            if !profile.runtime.isInProcess {
                Text(L10n.AgentProfiles.capabilityExternalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isManaged {
                toolToggles(index: index, profile: profile)
                maxRoundsField(index: index, profile: profile)
                Text(L10n.AgentProfiles.writeAccessNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledContent(L10n.AgentProfiles.fieldTools) {
                    Text((profile.capability?.toolNames ?? []).sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                maxRoundsField(index: index, profile: profile)
                Text(L10n.AgentProfiles.capabilityBuiltInNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if isManaged {
            Section {
                Button(role: .destructive) {
                    deleteTarget = profile
                } label: {
                    Label(L10n.AgentProfiles.deleteProfile, systemImage: "trash")
                }
            }
        }
    }

    /// Forced context window for this trade. Empty means "use the trade's
    /// own default", which is deliberately not the same as the model's real
    /// window — the built-in numbers are deployable-tier budgets chosen per
    /// trade, and a model may hold more than a trade is meant to spend.
    @ViewBuilder
    private func contextWindowField(index: Int, profile: AgentProfile) -> some View {
        let placeholder = defaultContextWindow(for: profile)
            .map(String.init) ?? L10n.AgentProfiles.contextWindowInherits
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L10n.AgentProfiles.fieldContextWindow) {
                TextField(placeholder, text: contextWindowBinding(index))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }
            Text(L10n.AgentProfiles.contextWindowNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(profile.origin == .discovered)
    }

    @ViewBuilder
    private func maxRoundsField(index: Int, profile: AgentProfile) -> some View {
        let range = AgentProfileCapability.roundBudgetRange
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L10n.AgentProfiles.fieldMaxRounds) {
                TextField(
                    String(defaultMaxRounds(for: profile)),
                    text: maxRoundsBinding(index)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            }
            Text(L10n.AgentProfiles.maxRoundsNote(range.lowerBound, range.upperBound))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!profile.runtime.isInProcess)
    }

    /// The code default, i.e. what an empty field falls back to. Read off the
    /// built-in rather than the edited copy, so clearing the field shows the
    /// value it is about to restore instead of the one being replaced.
    private func defaultContextWindow(for profile: AgentProfile) -> Int? {
        AgentProfile.builtIns.first { $0.id == profile.id }?
            .runtime.modelBinding.contextWindowTokens
    }

    private func defaultMaxRounds(for profile: AgentProfile) -> Int {
        AgentProfile.builtIns.first { $0.id == profile.id }?.capability?.maxRounds
            ?? AgentProfileCapability.managedDefault.maxRounds
    }

    @ViewBuilder
    private func skillsMenu(index: Int, profile: AgentProfile) -> some View {
        let installed = AgentSkillDirectory.list(includeDisabled: false)
        Menu {
            if installed.isEmpty {
                Text(L10n.AgentProfiles.skillsNone)
            } else {
                ForEach(installed) { skill in
                    Button {
                        toggleSkill(skill.identifier, index: index)
                    } label: {
                        if profile.soul.skillIdentifiers.contains(skill.identifier) {
                            Label(skill.identifier, systemImage: "checkmark")
                        } else {
                            Text(skill.identifier)
                        }
                    }
                }
            }
        } label: {
            Text(
                profile.soul.skillIdentifiers.isEmpty
                    ? L10n.AgentProfiles.skillsEmpty
                    : profile.soul.skillIdentifiers.joined(separator: ", ")
            )
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 260)
    }

    @ViewBuilder
    private func toolToggles(index: Int, profile: AgentProfile) -> some View {
        let allowed = AgentSubagentRunner.allowedToolNames.sorted()
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.AgentProfiles.fieldTools)
                .font(.system(size: 12, weight: .medium))
            ForEach(allowed, id: \.self) { tool in
                Toggle(tool, isOn: toolBinding(index, tool: tool))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    // MARK: - Bindings

    private func nameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { profiles[index].name },
            set: { profiles[index].name = $0; persist() }
        )
    }

    private func purposeBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { profiles[index].soul.purpose },
            set: { profiles[index].soul.purpose = $0; persist() }
        )
    }

    private func promptBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { profiles[index].soul.promptSection },
            set: { profiles[index].soul.promptSection = $0; persist() }
        )
    }

    private func nativeProfileBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { profiles[index].runtime.nativeProfileName ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                profiles[index].runtime.nativeProfileName = trimmed.isEmpty ? nil : trimmed
                persist()
            }
        )
    }

    private func executorBinding(_ index: Int) -> Binding<AgentExecutionAgent> {
        Binding(
            get: { profiles[index].runtime.executor },
            set: {
                profiles[index].runtime.executor = $0
                // Only an in-process profile can be a subagent trade.
                if $0 != .willDeep {
                    profiles[index].usages.remove(.subagent)
                    profiles[index].usages.insert(.dispatch)
                }
                persist()
            }
        )
    }

    private func providerBinding(_ index: Int) -> Binding<UUID?> {
        Binding(
            get: {
                let binding = profiles[index].runtime.modelBinding
                if let entryID = binding.preferredProviderEntryID { return entryID }
                guard let providerID = binding.preferredProviderID else { return nil }
                return appState.agentProviderLibrary.entries
                    .first { $0.providerID == providerID }?.id
            },
            set: { newValue in
                guard let newValue,
                      let entry = appState.agentProviderLibrary.entries.first(where: { $0.id == newValue }) else {
                    profiles[index].runtime.modelBinding.preferredProviderEntryID = nil
                    profiles[index].runtime.modelBinding.preferredProviderID = nil
                    persist()
                    return
                }
                profiles[index].runtime.modelBinding.preferredProviderEntryID = entry.id
                profiles[index].runtime.modelBinding.preferredProviderID = entry.providerID
                persist()
            }
        )
    }

    /// Digits only, and an empty string means "clear the override". Parsing
    /// leniently (`Int(...)` on whatever was typed) would turn a half-typed
    /// "2 5 6" into a real window of 2 mid-keystroke.
    private func contextWindowBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                profiles[index].runtime.modelBinding.contextWindowTokens.map(String.init) ?? ""
            },
            set: { raw in
                let digits = raw.filter(\.isNumber)
                guard !digits.isEmpty, let value = Int(digits), value > 0 else {
                    profiles[index].runtime.modelBinding.contextWindowTokens = nil
                    persist()
                    return
                }
                profiles[index].runtime.modelBinding.contextWindowTokens = value
                persist()
            }
        )
    }

    private func maxRoundsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { profiles[index].capability.map { String($0.maxRounds) } ?? "" },
            set: { raw in
                guard profiles[index].capability != nil else { return }
                let digits = raw.filter(\.isNumber)
                guard !digits.isEmpty, let value = Int(digits) else { return }
                profiles[index].capability?.maxRounds =
                    AgentProfileCapability.clampRoundBudget(value)
                persist()
            }
        )
    }

    private func modelBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { profiles[index].runtime.modelBinding.model ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                profiles[index].runtime.modelBinding.model = trimmed.isEmpty ? nil : trimmed
                persist()
            }
        )
    }

    private func usageBinding(_ index: Int, usage: AgentProfile.Usage) -> Binding<Bool> {
        Binding(
            get: { profiles[index].usages.contains(usage) },
            set: { isOn in
                if isOn {
                    profiles[index].usages.insert(usage)
                } else if profiles[index].usages.count > 1 {
                    // A profile with no usage at all would vanish from every
                    // picker with no way back; keep the last one.
                    profiles[index].usages.remove(usage)
                }
                persist()
            }
        )
    }

    private func toolBinding(_ index: Int, tool: String) -> Binding<Bool> {
        Binding(
            get: { profiles[index].capability?.toolNames.contains(tool) ?? false },
            set: { isOn in
                var capability = profiles[index].capability ?? .managedDefault
                if isOn {
                    capability.toolNames.insert(tool)
                } else {
                    capability.toolNames.remove(tool)
                }
                profiles[index].capability = capability
                persist()
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    // MARK: - Actions

    /// True while some.im owns this trade's model and job prompt. Only the
    /// managed worker trades qualify; `deep`, `tester`, `reviewer` and every
    /// dispatch profile stay user-configurable. Being signed in is not enough:
    /// a private/on-prem current provider must never be silently rerouted
    /// (docs/SOMEIM_WORKER_VIRTUAL_MODELS.md §3.8).
    /// The hosted model this trade recommends right now, or nil when the
    /// recommendation does not apply (not a managed trade, signed out, or the
    /// session is on a private/on-prem provider that must never be silently
    /// rerouted — docs/SOMEIM_WORKER_VIRTUAL_MODELS.md §3.8).
    ///
    /// Leaving the field empty means "use this"; typing a model overrides it.
    private func recommendedHostedModel(for profile: AgentProfile) -> String? {
        guard profile.usages.contains(.subagent),
              AgentSubagentJobPrompts.hostedTradeIDs.contains(profile.id),
              appState.agentConfiguration.providerID == AgentProviderPreset.someIMID,
              SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults() else {
            return nil
        }
        return AgentSubagentJobPrompts.hostedModel(for: profile.id)
    }

    private func modelOptions(for profile: AgentProfile) -> [String] {
        guard let entryID = providerEntryID(for: profile),
              let entry = appState.agentProviderLibrary.entries.first(where: { $0.id == entryID }) else {
            return []
        }
        return AgentExecutionProfileModelCatalog.models(for: entry)
    }

    private func providerEntryID(for profile: AgentProfile) -> UUID? {
        if let entryID = profile.runtime.modelBinding.preferredProviderEntryID { return entryID }
        guard let providerID = profile.runtime.modelBinding.preferredProviderID else { return nil }
        return appState.agentProviderLibrary.entries.first { $0.providerID == providerID }?.id
    }

    private func reload() {
        profiles = store.profiles()
        if selectedID == nil || !visibleProfiles.contains(where: { $0.id == selectedID }) {
            selectedID = visibleProfiles.first?.id
        }
    }

    private func addProfile() {
        let profile = AgentProfile(
            id: "managed:\(UUID().uuidString.lowercased())",
            name: L10n.AgentProfiles.newProfileName,
            origin: .managed,
            usages: [.subagent],
            soul: AgentProfileSoul(
                purpose: "",
                basePromptSection: "",
                promptSection: "",
                skillIdentifiers: []
            ),
            runtime: AgentProfileRuntime(
                executor: .willDeep,
                nativeProfileName: nil,
                modelBinding: .inheritsParent
            ),
            capability: .managedDefault
        )
        profiles.append(profile)
        selectedID = profile.id
        persist()
    }

    private func toggleSkill(_ identifier: String, index: Int) {
        var identifiers = profiles[index].soul.skillIdentifiers
        if let existing = identifiers.firstIndex(of: identifier) {
            identifiers.remove(at: existing)
        } else {
            identifiers.append(identifier)
        }
        profiles[index].soul.skillIdentifiers = identifiers
        persist()
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        profiles.removeAll { $0.id == target.id && $0.origin == .managed }
        deleteTarget = nil
        selectedID = visibleProfiles.first?.id
        persist()
    }

    private func persist() {
        store.save(profiles: profiles)
    }
}
