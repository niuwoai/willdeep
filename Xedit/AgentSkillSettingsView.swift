//
//  AgentSkillSettingsView.swift
//  VeilWriter
//
//  Settings tab for built-in and user-created Agent skills.
//

import SwiftUI
import AppKit

struct AgentSkillSettingsView: View {
    @State private var settings = AgentSkillSettingsStore.load()
    @State private var skills: [AgentSkillEntry] = AgentSkillDirectory.list(includeDisabled: true)
    @State private var searchQuery = ""
    @State private var isCreatingSkill = false
    @State private var statusMessage = L10n.Settings.allChangesSaved

    private var filteredSkills: [AgentSkillEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.identifier.lowercased().contains(query)
                || $0.name.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
                || $0.url.path.lowercased().contains(query)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.identifier)
                        .font(.headline)
                    Text(skill.description)
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

            DisclosureGroup(L10n.Settings.Skill.viewContent) {
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
            }
        }
        .padding(.vertical, 6)
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
        skills = AgentSkillDirectory.list(includeDisabled: true)
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
