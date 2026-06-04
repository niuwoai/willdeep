//
//  AgentMemorySettingsView.swift
//  VeilWriter
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
    @State private var searchQuery = ""
    @State private var includeArchived = false
    @State private var editingMemoryID: UUID?
    @State private var editingMemoryContent = ""
    @State private var editingMemoryLifetime: AgentMemoryLifetime = .longTerm
    @State private var exportStatus = ""

    private var visibleMemories: [AgentMemoryRecord] {
        memoryState.memories(matching: searchQuery, includeArchived: includeArchived)
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
            Section("Memory Features") {
                Toggle("Enable memory", isOn: setting(\.isMemoryEnabled))
                Text("When enabled, the Agent can use saved preferences, recurring facts, and project notes as personalization context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Memory Retrieval") {
                Toggle("Auto-retrieve memories", isOn: setting(\.autoRetrievalEnabled))
                Text("Automatically search related memories before each Agent turn and inject the best matches as compact context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Rewrite retrieval query", isOn: setting(\.queryRewriteEnabled))
                Text("Use the tool model to turn conversational wording into a focused semantic search query.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Max retrieved memories") {
                    HStack {
                        Slider(value: doubleSetting(\.maxRetrievedMemories), in: 1...20, step: 1)
                        Text("\(memoryState.settings.maxRetrievedMemories)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                LabeledContent("Similarity threshold") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Slider(value: setting(\.similarityThreshold), in: 0...1, step: 0.01)
                            Text("\(Int(memoryState.settings.similarityThreshold * 100))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        HStack {
                            Text("Broad (0%)")
                            Spacer()
                            Text("Strict (100%)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Memory Summaries") {
                Toggle("Auto-summarize conversations", isOn: setting(\.autoSummaryEnabled))
                Text("Extract durable facts from conversations and save them as candidate memories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                maintenanceHeader
                Toggle("Run daily memory maintenance", isOn: setting(\.dailyMaintenanceEnabled))
                Text("Archives duplicate or stale transient entries, removes expired archived entries, and records the last maintenance result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let run = memoryState.settings.lastMaintenanceRun {
                    maintenanceRunCard(run)
                }

                HStack {
                    Button {
                        memoryState.runMaintenance()
                    } label: {
                        Label("Run maintenance cycle", systemImage: "play")
                    }

                    Button {
                        memoryState.runMaintenance(preview: true)
                    } label: {
                        Label("Preview next cycle", systemImage: "eye")
                    }
                }

                DatePicker("Trigger time", selection: maintenanceTimeBinding, displayedComponents: .hourAndMinute)

                Stepper(value: setting(\.transientTTLDays), in: 1...3650) {
                    LabeledContent("Transient memory TTL") {
                        Text("\(memoryState.settings.transientTTLDays) days")
                            .monospacedDigit()
                    }
                }

                Stepper(value: setting(\.archiveRetentionDays), in: 1...3650) {
                    LabeledContent("Archive retention") {
                        Text("\(memoryState.settings.archiveRetentionDays) days")
                            .monospacedDigit()
                    }
                }

                DisclosureGroup("Similarity and merge parameters") {
                    Text("The current local maintenance pass handles retention and archiving. LLM-assisted duplicate merging can be wired into this section once the Agent memory retrieval pipeline starts consuming embeddings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Archived memories (\(memoryState.archivedMemories.count))") {
                    if memoryState.archivedMemories.isEmpty {
                        Text("No archived memories.")
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
                        Label("Export memory snapshot", systemImage: "square.and.arrow.down")
                    }
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Memory Maintenance", systemImage: "moon")
            }

            Section("Memory Tool Model") {
                Picker("Tool model", selection: setting(\.toolModelID)) {
                    Text("Use active Agent model").tag("")
                    ForEach(modelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Text("Used for query rewriting and future LLM-assisted memory maintenance. Leave blank to follow the active Agent model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Embedding Model") {
                TextField("Embedding model", text: setting(\.embeddingModelID))
                    .textFieldStyle(.roundedBorder)
                Text("Used for semantic retrieval. Leave the default unless your provider exposes a compatible embedding model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Statistics") {
                HStack(spacing: 12) {
                    statCard(title: "Total memories", value: memoryState.memories.count)
                    statCard(title: "Auto-generated", value: autoMemoryCount)
                    statCard(title: "Manual", value: manualMemoryCount)
                }
            }

            Section("Add Memory") {
                TextEditor(text: $newMemoryContent)
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                Picker("Lifetime", selection: $newMemoryLifetime) {
                    ForEach(AgentMemoryLifetime.allCases) { lifetime in
                        Text(lifetime.displayName).tag(lifetime)
                    }
                }

                Button {
                    memoryState.addMemory(content: newMemoryContent, lifetime: newMemoryLifetime)
                    newMemoryContent = ""
                    newMemoryLifetime = .longTerm
                } label: {
                    Label("Add memory", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Search Memories") {
                HStack {
                    TextField("Search by text...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Include archived", isOn: $includeArchived)
                        .toggleStyle(.checkbox)
                }
            }

            Section {
                HStack {
                    Text("\(visibleMemories.count) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        searchQuery = ""
                    } label: {
                        Label("Reset search", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        memoryState.clearMemories()
                    } label: {
                        Label("Clear all", systemImage: "trash")
                    }
                    .disabled(memoryState.memories.isEmpty)
                }

                if visibleMemories.isEmpty {
                    Text("No memories match the current filters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleMemories) { memory in
                        memoryRow(memory)
                    }
                }
            } header: {
                Text("Memory List")
            }
        }
        .formStyle(.grouped)
    }

    private var maintenanceHeader: some View {
        HStack {
            Text("Daily sleep cycle")
                .font(.headline)
            Spacer()
            Text(maintenanceHeaderSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var maintenanceHeaderSummary: String {
        let archived = memoryState.archivedMemories.count
        let next = memoryState.settings.nextMaintenanceDate().map(formatDate) ?? "Not scheduled"
        return "Archived \(archived) · Next: \(next)"
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
                Text("Last: \(run.status.rawValue)")
                    .fontWeight(.semibold)
                Spacer()
                Text(formatDate(run.ranAt))
                    .foregroundStyle(.secondary)
            }
            Text("Inspected \(run.inspectedCount), archived \(run.archivedCount), removed \(run.removedExpiredCount), merged \(run.mergedCount).")
                .foregroundStyle(.secondary)
            Text("LLM tokens: \(run.inputTokens) input / \(run.outputTokens) output")
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
                    Picker("Lifetime", selection: $editingMemoryLifetime) {
                        ForEach(AgentMemoryLifetime.allCases) { lifetime in
                            Text(lifetime.displayName).tag(lifetime)
                        }
                    }
                    .frame(width: 180)

                    Spacer()
                    Button("Cancel") {
                        stopEditing()
                    }
                    Button("Save") {
                        memoryState.updateMemory(
                            id: memory.id,
                            content: editingMemoryContent,
                            lifetime: editingMemoryLifetime
                        )
                        stopEditing()
                    }
                    .disabled(editingMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memory.content)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            tag(memory.source.displayName)
                            tag(memory.lifetime.displayName)
                            Text(formatDate(memory.updatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if memory.accessCount > 0 {
                                Text("Used \(memory.accessCount)x")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if memory.isArchived {
                                tag("Archived")
                            }
                        }
                    }

                    Spacer()

                    Button {
                        startEditing(memory)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit memory")

                    if memory.isArchived {
                        Button {
                            memoryState.restoreMemory(id: memory.id)
                        } label: {
                            Image(systemName: "tray.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .help("Restore memory")
                    } else {
                        Button {
                            memoryState.archiveMemory(id: memory.id)
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .buttonStyle(.borderless)
                        .help("Archive memory")
                    }

                    Button(role: .destructive) {
                        memoryState.deleteMemory(id: memory.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete memory")
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
    }

    private func stopEditing() {
        editingMemoryID = nil
        editingMemoryContent = ""
        editingMemoryLifetime = .longTerm
    }

    private func exportMemorySnapshot() {
        let panel = NSSavePanel()
        panel.title = "Export Memory Snapshot"
        panel.nameFieldStringValue = "veilwriter-memory-snapshot.json"
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
            exportStatus = "Exported to \(url.lastPathComponent)."
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
}

private struct AgentMemorySnapshot: Codable {
    var exportedAt: Date
    var settings: AgentMemorySettings
    var memories: [AgentMemoryRecord]
}
