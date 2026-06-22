//
//  AgentSkillSettingsView.swift
//  WillDeep
//
//  Settings tab for built-in and user-created Agent skills.
//

import SwiftUI
import AppKit

struct AgentSkillSettingsView: View {
    @State private var settings = AgentSkillSettingsStore.load()
    @State private var skills: [AgentSkillEntry] = AgentSkillDirectory.list(includeDisabled: true)
    @State private var marketplaceEntries = AgentSkillMarketplaceStore.entries()
    @State private var marketplaceCredentialInputs: [String: String] = [:]
    @State private var searchQuery = ""
    @State private var isCreatingSkill = false
    @State private var statusMessage = L10n.Settings.allChangesSaved
    @State private var expandedSkillIdentifiers: Set<String> = []

    private var filteredMarketplaceEntries: [AgentSkillMarketplaceEntry] {
        let query = normalizedSearchQuery
        guard !query.isEmpty else { return marketplaceEntries }
        return marketplaceEntries.filter { entry in
            entry.id.lowercased().contains(query)
                || entry.skillName.lowercased().contains(query)
                || entry.displayName.lowercased().contains(query)
                || entry.tagline.lowercased().contains(query)
                || entry.detail.lowercased().contains(query)
                || entry.category.lowercased().contains(query)
                || entry.tags.contains { $0.lowercased().contains(query) }
        }
    }

    private var filteredSkills: [AgentSkillEntry] {
        let query = normalizedSearchQuery
        guard !query.isEmpty else { return skills }
        return skills.filter {
            AgentSkillLocalization.searchableText(for: $0).contains(query)
        }
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var enabledSkillCount: Int {
        skills.filter(\.isEnabled).count
    }

    var body: some View {
        Form {
            Section(L10n.Settings.Skill.autoExtractSection) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.Skill.autoExtractTitle)
                            .font(.headline)
                        Text(L10n.Settings.Skill.autoExtractDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: setting(\.autoExtractionEnabled))
                        .labelsHidden()
                }

                LabeledContent(L10n.Settings.Skill.minimumToolCallsLabel) {
                    HStack {
                        Slider(value: doubleSetting(\.minimumToolCallCount), in: 1...50, step: 1)
                        Text("\(settings.minimumToolCallCount)")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text(L10n.Settings.Skill.minimumToolCallsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(L10n.Settings.Skill.availableCount("\(enabledSkillCount)", "\(skills.count)"))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        refreshSkills()
                    } label: {
                        Label(L10n.Settings.Skill.refresh, systemImage: "arrow.clockwise")
                    }

                    Button {
                        openUserSkillsFolder()
                    } label: {
                        Label(L10n.Settings.Skill.openFolder, systemImage: "folder")
                    }

                    Button {
                        isCreatingSkill = true
                    } label: {
                        Label(L10n.Settings.Skill.newSkill, systemImage: "plus")
                    }
                }

                TextField(L10n.Settings.Skill.searchPlaceholder, text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            marketplaceSection
            skillSection(title: L10n.Settings.Skill.builtInSkills, source: .bundled, systemImage: "shippingbox")
            skillSection(title: L10n.Settings.Skill.userSkills, source: .user, systemImage: "person.crop.square")
            skillSection(title: L10n.Settings.Skill.pluginSkills, source: .plugin, systemImage: "puzzlepiece.extension")
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .sheet(isPresented: $isCreatingSkill) {
            AgentSkillCreationSheet { createdURL in
                isCreatingSkill = false
                refreshSkills()
                statusMessage = L10n.Settings.Skill.createdSkill(createdURL.deletingLastPathComponent().lastPathComponent)
            } onCancel: {
                isCreatingSkill = false
            }
        }
    }

    private var marketplaceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.Settings.Skill.marketplaceCount("\(filteredMarketplaceEntries.count)"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(L10n.Settings.Skill.marketplaceStaticSource, systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.Settings.Skill.marketplaceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredMarketplaceEntries.isEmpty {
                Text(L10n.Settings.Skill.marketplaceNoResults)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredMarketplaceEntries) { entry in
                    marketplaceRow(entry)
                }
            }
        } header: {
            Label(L10n.Settings.Skill.marketplaceSection, systemImage: "sparkles")
        }
    }

    private func marketplaceRow(_ entry: AgentSkillMarketplaceEntry) -> some View {
        let status = AgentSkillMarketplaceStore.status(for: entry)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(entry.displayName)
                            .font(.headline)
                        Text(L10n.Settings.Skill.marketplaceVersion(entry.version))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        marketplaceBadge(entry.category, systemImage: "tag")
                        marketplaceBadge(entry.author, systemImage: "person.crop.circle")
                        marketplaceBadge(L10n.Settings.Skill.marketplaceMinimumVersion(entry.minimumAppVersion), systemImage: "checkmark.seal")
                    }

                    if !entry.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }

                    marketplaceCredentialsView(entry)

                    Text(marketplaceStatusText(for: entry, status: status))
                        .font(.caption2)
                        .foregroundStyle(status == .conflict ? .red : .secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        installOrUpdateMarketplaceEntry(entry, status: status)
                    } label: {
                        Label(marketplacePrimaryActionTitle(for: status), systemImage: marketplacePrimaryActionIcon(for: status))
                    }
                    .disabled(!canInstallMarketplaceEntry(entry, status: status))

                    if status.isInstalled {
                        Button(role: .destructive) {
                            uninstallMarketplaceEntry(entry)
                        } label: {
                            Label(L10n.Settings.Skill.marketplaceUninstall, systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func marketplaceCredentialsView(_ entry: AgentSkillMarketplaceEntry) -> some View {
        if !entry.credentialRequirements.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.credentialRequirements) { requirement in
                    HStack(spacing: 8) {
                        Label(requirement.label, systemImage: "key")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)

                        SecureField(requirement.detail, text: credentialInputBinding(entry: entry, requirement: requirement))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)

                        if AgentSkillMarketplaceStore.isCredentialConfigured(for: entry, requirement: requirement) {
                            Label(L10n.Settings.Skill.marketplaceCredentialConfigured, systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(L10n.Settings.Skill.marketplaceCredentialClear) {
                                clearMarketplaceCredential(entry: entry, requirement: requirement)
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        } else if requirement.isRequired {
                            Text(L10n.Settings.Skill.marketplaceCredentialRequired)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func marketplaceBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func marketplacePrimaryActionTitle(for status: AgentSkillMarketplaceStatus) -> String {
        switch status {
        case .available:
            return L10n.Settings.Skill.marketplaceInstall
        case .installed:
            return L10n.Settings.Skill.marketplaceInstalled
        case .updateAvailable:
            return L10n.Settings.Skill.marketplaceUpdate
        case .conflict:
            return L10n.Settings.Skill.marketplaceConflictLabel
        }
    }

    private func marketplacePrimaryActionIcon(for status: AgentSkillMarketplaceStatus) -> String {
        switch status {
        case .available:
            return "square.and.arrow.down"
        case .installed:
            return "checkmark.circle"
        case .updateAvailable:
            return "arrow.down.circle"
        case .conflict:
            return "exclamationmark.triangle"
        }
    }

    private func marketplaceStatusText(for entry: AgentSkillMarketplaceEntry, status: AgentSkillMarketplaceStatus) -> String {
        switch status {
        case .available:
            return entry.skillName
        case .installed:
            return L10n.Settings.Skill.marketplaceInstalledStatus(entry.version)
        case .updateAvailable(let installedVersion):
            return L10n.Settings.Skill.marketplaceUpdateStatus(installedVersion, entry.version)
        case .conflict:
            return L10n.Settings.Skill.marketplaceConflict(entry.slug)
        }
    }

    private func credentialInputBinding(
        entry: AgentSkillMarketplaceEntry,
        requirement: AgentSkillCredentialRequirement
    ) -> Binding<String> {
        let key = credentialInputKey(entry: entry, requirement: requirement)
        return Binding {
            marketplaceCredentialInputs[key] ?? ""
        } set: { value in
            marketplaceCredentialInputs[key] = value
        }
    }

    private func credentialInputKey(
        entry: AgentSkillMarketplaceEntry,
        requirement: AgentSkillCredentialRequirement
    ) -> String {
        "\(entry.id)::\(requirement.id)"
    }

    private func credentialsForInstall(_ entry: AgentSkillMarketplaceEntry) -> [String: String] {
        Dictionary(uniqueKeysWithValues: entry.credentialRequirements.compactMap { requirement in
            let key = credentialInputKey(entry: entry, requirement: requirement)
            guard let value = marketplaceCredentialInputs[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return (requirement.id, value)
        })
    }

    private func hasCredentialInputOrStored(
        entry: AgentSkillMarketplaceEntry,
        requirement: AgentSkillCredentialRequirement
    ) -> Bool {
        let key = credentialInputKey(entry: entry, requirement: requirement)
        let input = marketplaceCredentialInputs[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !input.isEmpty || AgentSkillMarketplaceStore.isCredentialConfigured(for: entry, requirement: requirement)
    }

    private func canInstallMarketplaceEntry(
        _ entry: AgentSkillMarketplaceEntry,
        status: AgentSkillMarketplaceStatus
    ) -> Bool {
        guard status != .installed, status != .conflict else { return false }
        return entry.credentialRequirements.allSatisfy { requirement in
            !requirement.isRequired || hasCredentialInputOrStored(entry: entry, requirement: requirement)
        }
    }

    private func clearMarketplaceCredential(
        entry: AgentSkillMarketplaceEntry,
        requirement: AgentSkillCredentialRequirement
    ) {
        AgentCredentialStore.delete(account: AgentSkillMarketplaceStore.credentialAccount(for: entry, requirement: requirement))
        marketplaceCredentialInputs[credentialInputKey(entry: entry, requirement: requirement)] = ""
        statusMessage = L10n.Settings.Skill.marketplaceCredentialCleared(requirement.label)
    }

    private func skillSection(title: String, source: AgentSkillSource, systemImage: String) -> some View {
        let sourceSkills = filteredSkills.filter { $0.source == source }
        return Section {
            if sourceSkills.isEmpty {
                Text(L10n.Settings.Skill.noSkills)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sourceSkills) { skill in
                    skillRow(skill)
                }
            }
        } header: {
            Label("\(title)  \(sourceSkills.count)", systemImage: systemImage)
        }
    }

    private func skillRow(_ skill: AgentSkillEntry) -> some View {
        let displayName = skill.source == .bundled
            ? AgentSkillLocalization.displayName(for: skill)
            : skill.identifier
        let displayDescription = skill.source == .bundled
            ? AgentSkillLocalization.displayDescription(for: skill)
            : skill.description
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.headline)
                    if displayName != skill.identifier {
                        Text(skill.identifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(displayDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(skill.url.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { skill.isEnabled },
                    set: { enabled in
                        AgentSkillSettingsStore.setSkillEnabled(identifier: skill.identifier, enabled: enabled)
                        settings = AgentSkillSettingsStore.load()
                        refreshSkills()
                        statusMessage = L10n.Settings.allChangesSaved
                    }
                ))
                .labelsHidden()
            }

            DisclosureGroup(isExpanded: skillContentExpansionBinding(for: skill.identifier)) {
                ScrollView {
                    Text(AgentSkillDirectory.loadBody(for: skill, maxCharacters: 12_000) ?? L10n.Settings.Skill.unableToRead)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 240)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: {
                Button {
                    toggleSkillContentExpansion(for: skill.identifier)
                } label: {
                    Text(L10n.Settings.Skill.viewContent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private func skillContentExpansionBinding(for identifier: String) -> Binding<Bool> {
        Binding {
            expandedSkillIdentifiers.contains(identifier)
        } set: { isExpanded in
            if isExpanded {
                expandedSkillIdentifiers.insert(identifier)
            } else {
                expandedSkillIdentifiers.remove(identifier)
            }
        }
    }

    private func toggleSkillContentExpansion(for identifier: String) {
        if expandedSkillIdentifiers.contains(identifier) {
            expandedSkillIdentifiers.remove(identifier)
        } else {
            expandedSkillIdentifiers.insert(identifier)
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AgentSkillSettings, Value>) -> Binding<Value> {
        Binding {
            settings[keyPath: keyPath]
        } set: { value in
            settings[keyPath: keyPath] = value
            settings = settings.normalized
            AgentSkillSettingsStore.save(settings)
            statusMessage = L10n.Settings.allChangesSaved
        }
    }

    private func doubleSetting(_ keyPath: WritableKeyPath<AgentSkillSettings, Int>) -> Binding<Double> {
        Binding {
            Double(settings[keyPath: keyPath])
        } set: { value in
            settings[keyPath: keyPath] = Int(value.rounded())
            settings = settings.normalized
            AgentSkillSettingsStore.save(settings)
            statusMessage = L10n.Settings.allChangesSaved
        }
    }

    private func refreshSkills() {
        settings = AgentSkillSettingsStore.load()
        marketplaceEntries = AgentSkillMarketplaceStore.entries()
        skills = AgentSkillDirectory.list(includeDisabled: true)
    }

    private func installOrUpdateMarketplaceEntry(_ entry: AgentSkillMarketplaceEntry, status: AgentSkillMarketplaceStatus) {
        do {
            _ = try AgentSkillMarketplaceStore.install(entry, credentials: credentialsForInstall(entry))
            for requirement in entry.credentialRequirements {
                marketplaceCredentialInputs[credentialInputKey(entry: entry, requirement: requirement)] = ""
            }
            refreshSkills()
            switch status {
            case .updateAvailable:
                statusMessage = L10n.Settings.Skill.marketplaceUpdatedMessage(entry.displayName)
            case .available, .installed, .conflict:
                statusMessage = L10n.Settings.Skill.marketplaceInstalledMessage(entry.displayName)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func uninstallMarketplaceEntry(_ entry: AgentSkillMarketplaceEntry) {
        do {
            try AgentSkillMarketplaceStore.uninstall(entry)
            refreshSkills()
            statusMessage = L10n.Settings.Skill.marketplaceUninstalledMessage(entry.displayName)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func openUserSkillsFolder() {
        do {
            try FileManager.default.createDirectory(
                at: AgentSkillDirectory.userSkillsRoot,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(AgentSkillDirectory.userSkillsRoot)
            statusMessage = L10n.Settings.Skill.openedFolder
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct AgentSkillCreationSheet: View {
    @State private var name = ""
    @State private var description = ""
    @State private var skillBody = ""
    @State private var errorMessage = ""

    let onCreate: (URL) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Settings.Skill.newUserSkillTitle)
                .font(.title3)
                .fontWeight(.semibold)

            TextField(L10n.Settings.Skill.skillNamePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)

            TextField(L10n.Settings.Skill.descriptionPlaceholder, text: $description)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $skillBody)
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.Settings.Skill.cancelButton) {
                    onCancel()
                }
                Button(L10n.Settings.Skill.createButton) {
                    createSkill()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func createSkill() {
        do {
            let url = try AgentSkillFileManager.createUserSkill(
                name: name,
                description: description,
                body: skillBody.isEmpty ? L10n.Settings.Skill.defaultBody : skillBody
            )
            onCreate(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
