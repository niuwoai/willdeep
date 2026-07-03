//
//  AgentMemorySettingsView.swift
//  WillDeep
//
//  Settings tab for local Agent memory configuration and management.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentMemorySettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var memoryState = AgentMemoryState()

    @State private var newMemoryContent = ""
    @State private var newMemoryLifetime: AgentMemoryLifetime = .longTerm
    @State private var newMemoryScope: AgentMemoryScope = .global
    @State private var searchQuery = ""
    @State private var includeArchived = false
    @State private var scopeFilter: MemoryScopeFilter = .all

    enum MemoryScopeFilter: Hashable {
        case all
        case globalOnly
        case currentProject
    }
    @State private var editingMemoryID: UUID?
    @State private var editingMemoryContent = ""
    @State private var editingMemoryLifetime: AgentMemoryLifetime = .longTerm
    @State private var editingMemoryScope: AgentMemoryScope = .global
    @State private var exportStatus = ""

    private var visibleMemories: [AgentMemoryRecord] {
        let matching = memoryState.memories(matching: searchQuery, includeArchived: includeArchived)
        switch scopeFilter {
        case .all:
            return matching
        case .globalOnly:
            return matching.filter { $0.scope == .global }
        case .currentProject:
            return matching.filter { $0.scope == .project && isBoundToCurrentWorkspace($0) }
        }
    }

    private var currentWorkspaceFingerprint: String? {
        AgentMemoryEngine.projectFingerprint(for: appState.rootDirectory)
    }

    private func isBoundToCurrentWorkspace(_ memory: AgentMemoryRecord) -> Bool {
        guard let root = appState.rootDirectory else { return false }
        return AgentMemoryEngine.applies(
            memory,
            projectID: currentWorkspaceFingerprint,
            rootPath: root.standardizedFileURL.path
        ) && memory.scope == .project
    }

    private var autoMemoryCount: Int {
        memoryState.memories.filter { $0.source == .automatic }.count
    }

    private var manualMemoryCount: Int {
        memoryState.memories.filter { $0.source == .manual }.count
    }

    private var modelOptions: [String] {
        var seen = Set<String>()
        let candidates = [
            appState.agentConfiguration.flashModel,
            appState.agentConfiguration.proModel,
            appState.agentConfiguration.model
        ]
        + appState.agentKnownModelIDs
        + appState.agentProviderLibrary.entries.flatMap { entry in
            entry.allFlashModels + entry.allProModels
        }
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            AgentLearningReviewSettingsSection()

            Section(L10n.Settings.Memory.featuresSection) {
                Toggle(L10n.Settings.Memory.enableToggle, isOn: setting(\.isMemoryEnabled))
                Text(L10n.Settings.Memory.enableDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.Memory.retrievalSection) {
                Toggle(L10n.Settings.Memory.autoRetrievalToggle, isOn: setting(\.autoRetrievalEnabled))
                Text(L10n.Settings.Memory.autoRetrievalDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.Settings.Memory.queryRewriteToggle, isOn: setting(\.queryRewriteEnabled))
                Text(L10n.Settings.Memory.queryRewriteDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L10n.Settings.Memory.maxRetrievedLabel) {
                    HStack {
                        Slider(value: doubleSetting(\.maxRetrievedMemories), in: 1...20, step: 1)
                        Text("\(memoryState.settings.maxRetrievedMemories)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                LabeledContent(L10n.Settings.Memory.similarityThresholdLabel) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Slider(value: setting(\.similarityThreshold), in: 0...1, step: 0.01)
                            Text("\(Int(memoryState.settings.similarityThreshold * 100))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.Settings.Memory.similarityBroad)
                            Spacer()
                            Text(L10n.Settings.Memory.similarityStrict)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L10n.Settings.Memory.summariesSection) {
                Toggle(L10n.Settings.Memory.autoSummaryToggle, isOn: setting(\.autoSummaryEnabled))
                Text(L10n.Settings.Memory.autoSummaryDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                maintenanceHeader
                Toggle(L10n.Settings.Memory.dailyMaintenanceToggle, isOn: setting(\.dailyMaintenanceEnabled))
                Text(L10n.Settings.Memory.maintenanceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let run = memoryState.settings.lastMaintenanceRun {
                    maintenanceRunCard(run)
                }

                HStack {
                    Button {
                        memoryState.runMaintenance()
                    } label: {
                        Label(L10n.Settings.Memory.runMaintenanceButton, systemImage: "play")
                    }

                    Button {
                        memoryState.runMaintenance(preview: true)
                    } label: {
                        Label(L10n.Settings.Memory.previewMaintenanceButton, systemImage: "eye")
                    }
                }

                DatePicker(L10n.Settings.Memory.triggerTimeLabel, selection: maintenanceTimeBinding, displayedComponents: .hourAndMinute)

                Stepper(value: setting(\.transientTTLDays), in: 1...3650) {
                    LabeledContent(L10n.Settings.Memory.transientTTLLabel) {
                        Text(L10n.Settings.Memory.daysFormat("\(memoryState.settings.transientTTLDays)"))
                            .monospacedDigit()
                    }
                }

                Stepper(value: setting(\.archiveRetentionDays), in: 1...3650) {
                    LabeledContent(L10n.Settings.Memory.archiveRetentionLabel) {
                        Text(L10n.Settings.Memory.daysFormat("\(memoryState.settings.archiveRetentionDays)"))
                            .monospacedDigit()
                    }
                }

                DisclosureGroup(L10n.Settings.Memory.mergeParametersLabel) {
                    Text(L10n.Settings.Memory.mergeParametersDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup(L10n.Settings.Memory.archivedMemoriesLabel("\(memoryState.archivedMemories.count)")) {
                    if memoryState.archivedMemories.isEmpty {
                        Text(L10n.Settings.Memory.noArchivedMemories)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memoryState.archivedMemories) { memory in
                            memoryRow(memory)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        exportMemorySnapshot()
                    } label: {
                        Label(L10n.Settings.Memory.exportSnapshotButton, systemImage: "square.and.arrow.down")
                    }
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(L10n.Settings.Memory.maintenanceSection, systemImage: "moon")
            }

            Section(L10n.Settings.Memory.toolModelSection) {
                Picker(L10n.Settings.Memory.toolModelLabel, selection: setting(\.toolModelID)) {
                    Text(L10n.Settings.Memory.useActiveAgentModel).tag("")
                    ForEach(modelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Text(L10n.Settings.Memory.toolModelDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.Memory.embeddingSection) {
                TextField(L10n.Settings.Memory.embeddingPlaceholder, text: setting(\.embeddingModelID))
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.Memory.embeddingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.Memory.statisticsSection) {
                HStack(spacing: 12) {
                    statCard(title: L10n.Settings.Memory.totalMemoriesLabel, value: memoryState.memories.count)
                    statCard(title: L10n.Settings.Memory.autoGeneratedLabel, value: autoMemoryCount)
                    statCard(title: L10n.Settings.Memory.manualLabel, value: manualMemoryCount)
                }
            }

            Section(L10n.Settings.Memory.addMemorySection) {
                TextEditor(text: $newMemoryContent)
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                HStack {
                    Picker(L10n.Settings.Memory.lifetimeLabel, selection: $newMemoryLifetime) {
                        ForEach(AgentMemoryLifetime.allCases) { lifetime in
                            Text(lifetime.displayName).tag(lifetime)
                        }
                    }

                    Picker(L10n.Settings.Memory.scopeLabel, selection: $newMemoryScope) {
                        ForEach(AgentMemoryScope.allCases) { scope in
                            Text(scope.displayName)
                                .tag(scope)
                                .disabled(scope == .project && appState.rootDirectory == nil)
                        }
                    }
                }

                if newMemoryScope == .project, appState.rootDirectory == nil {
                    Text(L10n.Settings.Memory.projectScopeRequiresWorkspace)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    memoryState.addMemory(
                        content: newMemoryContent,
                        lifetime: newMemoryLifetime,
                        scope: newMemoryScope,
                        rootDirectory: appState.rootDirectory
                    )
                    newMemoryContent = ""
                    newMemoryLifetime = .longTerm
                    newMemoryScope = .global
                } label: {
                    Label(L10n.Settings.Memory.addMemoryButton, systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(
                    newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (newMemoryScope == .project && appState.rootDirectory == nil)
                )
            }

            Section(L10n.Settings.Memory.searchSection) {
                HStack {
                    TextField(L10n.Settings.Memory.searchPlaceholder, text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                    Toggle(L10n.Settings.Memory.includeArchivedToggle, isOn: $includeArchived)
                        .toggleStyle(.checkbox)
                }
                Picker(L10n.Settings.Memory.scopeFilterLabel, selection: $scopeFilter) {
                    Text(L10n.Settings.Memory.scopeFilterAll).tag(MemoryScopeFilter.all)
                    Text(L10n.Settings.Memory.scopeFilterGlobal).tag(MemoryScopeFilter.globalOnly)
                    Text(L10n.Settings.Memory.scopeFilterCurrentProject)
                        .tag(MemoryScopeFilter.currentProject)
                }
                .pickerStyle(.segmented)
                if scopeFilter == .currentProject, appState.rootDirectory == nil {
                    Text(L10n.Settings.Memory.projectScopeRequiresWorkspace)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Text(L10n.Settings.Memory.shownCount("\(visibleMemories.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        searchQuery = ""
                    } label: {
                        Label(L10n.Settings.Memory.resetSearchButton, systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        memoryState.clearMemories()
                    } label: {
                        Label(L10n.Settings.Memory.clearAllButton, systemImage: "trash")
                    }
                    .disabled(memoryState.memories.isEmpty)
                }

                if visibleMemories.isEmpty {
                    Text(L10n.Settings.Memory.noMemoriesMatching)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleMemories) { memory in
                        memoryRow(memory)
                    }
                }
            } header: {
                Text(L10n.Settings.Memory.memoryListSection)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Legacy project memories only carry the fingerprint; when the
            // matching workspace is open, write its readable path back so
            // rows can show where each memory is mounted.
            memoryState.backfillProjectPaths(rootDirectory: appState.rootDirectory)
        }
    }

    private var maintenanceHeader: some View {
        HStack {
            Text(L10n.Settings.Memory.dailySleepCycleTitle)
                .font(.headline)
            Spacer()
            Text(maintenanceHeaderSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var maintenanceHeaderSummary: String {
        let archived = memoryState.archivedMemories.count
        let next = memoryState.settings.nextMaintenanceDate().map(formatDate) ?? L10n.Settings.Memory.notScheduled
        return L10n.Settings.Memory.headerSummary("\(archived)", next)
    }

    private var maintenanceTimeBinding: Binding<Date> {
        Binding {
            let settings = memoryState.settings
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = settings.maintenanceHour
            components.minute = settings.maintenanceMinute
            return Calendar.current.date(from: components) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            var settings = memoryState.settings
            settings.maintenanceHour = components.hour ?? settings.maintenanceHour
            settings.maintenanceMinute = components.minute ?? settings.maintenanceMinute
            memoryState.settings = settings.normalized
        }
    }

    private func maintenanceRunCard(_ run: AgentMemoryMaintenanceRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.Settings.Memory.lastStatus(run.status.rawValue))
                    .fontWeight(.semibold)
                Spacer()
                Text(formatDate(run.ranAt))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.Settings.Memory.maintenanceCounts(
                "\(run.inspectedCount)",
                "\(run.archivedCount)",
                "\(run.removedExpiredCount)",
                "\(run.mergedCount)"
            ))
                .foregroundStyle(.secondary)
            Text(L10n.Settings.Memory.tokensLine("\(run.inputTokens)", "\(run.outputTokens)"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func statCard(title: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func memoryRow(_ memory: AgentMemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingMemoryID == memory.id {
                TextEditor(text: $editingMemoryContent)
                    .frame(minHeight: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                HStack {
                    Picker(L10n.Settings.Memory.lifetimeLabel, selection: $editingMemoryLifetime) {
                        ForEach(AgentMemoryLifetime.allCases) { lifetime in
                            Text(lifetime.displayName).tag(lifetime)
                        }
                    }
                    .frame(width: 180)

                    Picker(L10n.Settings.Memory.scopeLabel, selection: $editingMemoryScope) {
                        ForEach(AgentMemoryScope.allCases) { scope in
                            Text(scope.displayName)
                                .tag(scope)
                                .disabled(scope == .project && appState.rootDirectory == nil && memory.projectFingerprint == nil)
                        }
                    }
                    .frame(width: 180)

                    Spacer()
                    Button(L10n.Settings.Memory.cancelButton) {
                        stopEditing()
                    }
                    Button(L10n.Settings.Memory.saveButton) {
                        memoryState.updateMemory(
                            id: memory.id,
                            content: editingMemoryContent,
                            lifetime: editingMemoryLifetime,
                            scope: editingMemoryScope,
                            rootDirectory: appState.rootDirectory
                        )
                        stopEditing()
                    }
                    .disabled(
                        editingMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (editingMemoryScope == .project && appState.rootDirectory == nil && memory.projectFingerprint == nil)
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memory.content)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            tag(memory.source.displayName)
                            tag(memory.lifetime.displayName)
                            tag(memory.scope.displayName)
                            if memory.scope == .project, let name = memory.projectDisplayName {
                                tag(name)
                            }
                            if isBoundToCurrentWorkspace(memory) {
                                tag(L10n.Settings.Memory.currentProjectTag)
                            }
                            tag(L10n.Settings.Memory.confidenceTag("\(Int(memory.confidence * 100))"))
                            if memory.containsSensitiveContent {
                                tag(L10n.Settings.Memory.sensitiveTag)
                            }
                            Text(formatDate(memory.updatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if memory.accessCount > 0 {
                                Text(L10n.Settings.Memory.usedXTimes("\(memory.accessCount)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if memory.isArchived {
                                tag(L10n.Settings.Memory.archivedTag)
                            }
                        }
                        if !memory.topics.isEmpty {
                            Text(L10n.Settings.Memory.topicsLine(memory.topics.prefix(8).joined(separator: ", ")))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let provenance = memory.provenance {
                            Text(L10n.Settings.Memory.provenanceLine(provenance))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if memory.scope == .project {
                            if let projectPath = memory.projectPath {
                                Text(L10n.Settings.Memory.projectPathLine(projectPath))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(projectPath)
                            } else if let projectFingerprint = memory.projectFingerprint {
                                Text(L10n.Settings.Memory.projectUnknownLine(shortFingerprint(projectFingerprint)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let lastAccessedAt = memory.lastAccessedAt {
                            Text(L10n.Settings.Memory.lastAccessedLine(formatDate(lastAccessedAt)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        startEditing(memory)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.Settings.Memory.editTooltip)

                    if memory.isArchived {
                        Button {
                            memoryState.restoreMemory(id: memory.id)
                        } label: {
                            Image(systemName: "tray.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.Settings.Memory.restoreTooltip)
                    } else {
                        Button {
                            memoryState.archiveMemory(id: memory.id)
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.Settings.Memory.archiveTooltip)
                    }

                    Button(role: .destructive) {
                        memoryState.deleteMemory(id: memory.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.Settings.Memory.deleteTooltip)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.10))
            .foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func startEditing(_ memory: AgentMemoryRecord) {
        editingMemoryID = memory.id
        editingMemoryContent = memory.content
        editingMemoryLifetime = memory.lifetime
        editingMemoryScope = memory.scope
    }

    private func stopEditing() {
        editingMemoryID = nil
        editingMemoryContent = ""
        editingMemoryLifetime = .longTerm
        editingMemoryScope = .global
    }

    private func exportMemorySnapshot() {
        let panel = NSSavePanel()
        panel.title = L10n.Settings.Memory.exportPanelTitle
        panel.nameFieldStringValue = "willdeep-memory-snapshot.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = AgentMemorySnapshot(
            exportedAt: Date(),
            settings: memoryState.settings.normalized,
            memories: memoryState.memories
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            exportStatus = L10n.Settings.Memory.exportedTo(url.lastPathComponent)
        } catch {
            exportStatus = error.localizedDescription
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AgentMemorySettings, Value>) -> Binding<Value> {
        Binding {
            memoryState.settings[keyPath: keyPath]
        } set: { value in
            var settings = memoryState.settings
            settings[keyPath: keyPath] = value
            memoryState.settings = settings.normalized
        }
    }

    private func doubleSetting(_ keyPath: WritableKeyPath<AgentMemorySettings, Int>) -> Binding<Double> {
        Binding {
            Double(memoryState.settings[keyPath: keyPath])
        } set: { value in
            var settings = memoryState.settings
            settings[keyPath: keyPath] = Int(value.rounded())
            memoryState.settings = settings.normalized
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        fingerprint.count > 12 ? String(fingerprint.prefix(12)) : fingerprint
    }
}

private struct AgentMemorySnapshot: Codable {
    var exportedAt: Date
    var settings: AgentMemorySettings
    var memories: [AgentMemoryRecord]
}
