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
    @State private var statusMessage = "All changes saved"

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
            Section("Automatic Skill Extraction") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-extract reusable skills from conversations")
                            .font(.headline)
                        Text("When enabled, VeilWriter can surface reusable workflows as skill candidates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: setting(\.autoExtractionEnabled))
                        .labelsHidden()
                }

                LabeledContent("Minimum tool calls") {
                    HStack {
                        Slider(value: doubleSetting(\.minimumToolCallCount), in: 1...50, step: 1)
                        Text("\(settings.minimumToolCallCount)")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text("Conversations with fewer tool calls are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("\(enabledSkillCount) of \(skills.count) skills available")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        refreshSkills()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        openUserSkillsFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }

                    Button {
                        isCreatingSkill = true
                    } label: {
                        Label("New Skill", systemImage: "plus")
                    }
                }

                TextField("Search by skill name, description, or path...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            skillSection(title: "Built-in Skills", source: .bundled, systemImage: "shippingbox")
            skillSection(title: "User Skills", source: .user, systemImage: "person.crop.square")
            skillSection(title: "Plugin Skills", source: .plugin, systemImage: "puzzlepiece.extension")
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
                statusMessage = "Created \(createdURL.deletingLastPathComponent().lastPathComponent)."
            } onCancel: {
                isCreatingSkill = false
            }
        }
    }

    private func skillSection(title: String, source: AgentSkillSource, systemImage: String) -> some View {
        let sourceSkills = filteredSkills.filter { $0.source == source }
        return Section {
            if sourceSkills.isEmpty {
                Text("No skills in this group.")
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
                        statusMessage = "All changes saved"
                    }
                ))
                .labelsHidden()
            }

            DisclosureGroup("View content") {
                ScrollView {
                    Text(AgentSkillDirectory.loadBody(for: skill, maxCharacters: 12_000) ?? "Unable to read skill content.")
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
            statusMessage = "All changes saved"
        }
    }

    private func doubleSetting(_ keyPath: WritableKeyPath<AgentSkillSettings, Int>) -> Binding<Double> {
        Binding {
            Double(settings[keyPath: keyPath])
        } set: { value in
            settings[keyPath: keyPath] = Int(value.rounded())
            settings = settings.normalized
            AgentSkillSettingsStore.save(settings)
            statusMessage = "All changes saved"
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
            statusMessage = "Opened user skills folder."
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
            Text("New User Skill")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Skill name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Description", text: $description)
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
                Button("Cancel") {
                    onCancel()
                }
                Button("Create") {
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
                body: skillBody.isEmpty ? "Describe when and how the Agent should use this skill." : skillBody
            )
            onCreate(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
