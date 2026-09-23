//
//  AgentRoutineEditorView.swift
//  WillDeep
//
//  Sheet for creating / editing a scheduled task: name, prompt, workspace
//  binding, model override, approval mode, schedule, enabled flag. The
//  underlying type remains AgentRoutine so existing persisted JSON stays
//  compatible.
//

import SwiftUI

struct AgentRoutineEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// The routine being edited. When `isNew` is true this is a fresh
    /// instance the sheet was seeded with; otherwise it's a copy of an
    /// existing one.
    @State private var draft: AgentRoutine
    private let isNew: Bool

    // Schedule editor is broken into local @State so SwiftUI controls
    // bind cleanly; we re-assemble the enum on save.
    @State private var scheduleKind: ScheduleKind
    @State private var intervalMinutes: Int
    @State private var timeHour: Int
    @State private var timeMinute: Int
    @State private var weekday: Int

    enum ScheduleKind: String, CaseIterable, Identifiable {
        case interval, daily, weekdays, weekly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .interval: return L10n.Automation.scheduleInterval
            case .daily:    return L10n.Automation.scheduleDaily
            case .weekdays: return L10n.Automation.scheduleWeekdays
            case .weekly:   return L10n.Automation.scheduleWeekly
            }
        }
    }

    init(routine: AgentRoutine, isNew: Bool) {
        self._draft = State(initialValue: routine)
        self.isNew = isNew

        switch routine.schedule {
        case .interval(let m):
            self._scheduleKind = State(initialValue: .interval)
            self._intervalMinutes = State(initialValue: m)
            self._timeHour = State(initialValue: 9)
            self._timeMinute = State(initialValue: 0)
            self._weekday = State(initialValue: 2)
        case .dailyAt(let h, let m):
            self._scheduleKind = State(initialValue: .daily)
            self._intervalMinutes = State(initialValue: 30)
            self._timeHour = State(initialValue: h)
            self._timeMinute = State(initialValue: m)
            self._weekday = State(initialValue: 2)
        case .weekdaysAt(let h, let m):
            self._scheduleKind = State(initialValue: .weekdays)
            self._intervalMinutes = State(initialValue: 30)
            self._timeHour = State(initialValue: h)
            self._timeMinute = State(initialValue: m)
            self._weekday = State(initialValue: 2)
        case .weeklyAt(let w, let h, let m):
            self._scheduleKind = State(initialValue: .weekly)
            self._intervalMinutes = State(initialValue: 30)
            self._timeHour = State(initialValue: h)
            self._timeMinute = State(initialValue: m)
            self._weekday = State(initialValue: w)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    promptField
                    workspaceField
                    modelField
                    approvalModeField
                    scheduleField
                    enabledField
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 540, idealHeight: 600)
    }

    private var header: some View {
        HStack {
            Text(isNew ? L10n.Automation.createTitle : L10n.Automation.editTitle)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L10n.Automation.labelName)
            TextField(L10n.Automation.placeholderName, text: $draft.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L10n.Automation.labelPrompt)
            TextEditor(text: $draft.prompt)
                .font(.system(size: 12))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
        }
    }

    private var workspaceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L10n.Automation.labelWorkspace)
            Menu {
                Button {
                    draft.workspaceRootPath = nil
                } label: {
                    HStack {
                        Text(L10n.Automation.noWorkspace)
                        if draft.workspaceRootPath == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                ForEach(knownWorkspaces(), id: \.self) { url in
                    Button {
                        draft.workspaceRootPath = url.standardizedFileURL.path
                    } label: {
                        HStack {
                            Text(url.lastPathComponent)
                            if draft.workspaceRootPath == url.standardizedFileURL.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(workspaceLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L10n.Automation.labelModel)
            Menu {
                Button {
                    draft.modelID = nil
                } label: {
                    HStack {
                        Text(L10n.Automation.followCurrentRoute)
                        if draft.modelID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                let models = candidateModels()
                if !models.isEmpty {
                    Divider()
                    ForEach(models, id: \.self) { model in
                        Button {
                            draft.modelID = model
                        } label: {
                            HStack {
                                Text(model)
                                if draft.modelID == model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.secondary)
                    Text(draft.modelID?.isEmpty == false ? draft.modelID! : L10n.Automation.followCurrentRouteShort)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var approvalModeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L10n.Automation.labelApprovalMode)
            Menu {
                ForEach(AgentApprovalMode.allCases) { mode in
                    Button {
                        draft.approvalMode = mode
                    } label: {
                        HStack {
                            Text(mode.displayName)
                            if draft.approvalMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: draft.approvalMode.symbol)
                        .foregroundStyle(approvalModeAccent ?? .secondary)
                    Text(draft.approvalMode.displayName)
                        .foregroundStyle(approvalModeAccent ?? .primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Text(draft.approvalMode.summary)
                .font(.system(size: 11))
                .foregroundStyle(approvalModeAccent ?? .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 完全访问沿用 composer 的橙色风险语义，其余档位保持中性色。
    private var approvalModeAccent: Color? {
        draft.approvalMode == .fullAccess ? AgentComposerChrome.fullAccessAccent : nil
    }

    private var scheduleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L10n.Automation.labelSchedule)
            Picker(L10n.Automation.labelScheduleType, selection: $scheduleKind) {
                ForEach(ScheduleKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Detail row varies by schedule kind.
            HStack(spacing: 8) {
                switch scheduleKind {
                case .interval:
                    Text(L10n.Automation.labelEvery)
                    Stepper(value: $intervalMinutes, in: 1...720, step: 5) {
                        Text(L10n.Automation.intervalMinutes("\(intervalMinutes)"))
                            .monospacedDigit()
                    }
                    .fixedSize()
                case .daily:
                    Text(L10n.Automation.scheduleDaily)
                    timePicker
                case .weekdays:
                    Text(L10n.Automation.scheduleWeekdaysDetail)
                    timePicker
                case .weekly:
                    Picker(L10n.Automation.scheduleWeekly, selection: $weekday) {
                        Text(L10n.Automation.weekdayMonday).tag(2)
                        Text(L10n.Automation.weekdayTuesday).tag(3)
                        Text(L10n.Automation.weekdayWednesday).tag(4)
                        Text(L10n.Automation.weekdayThursday).tag(5)
                        Text(L10n.Automation.weekdayFriday).tag(6)
                        Text(L10n.Automation.weekdaySaturday).tag(7)
                        Text(L10n.Automation.weekdaySunday).tag(1)
                    }
                    .labelsHidden()
                    .fixedSize()
                    timePicker
                }
                Spacer()
            }
            .padding(.top, 4)

            Text(currentScheduleSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var timePicker: some View {
        HStack(spacing: 4) {
            Stepper(value: $timeHour, in: 0...23) {
                Text(String(format: "%02d", timeHour))
                    .monospacedDigit()
                    .frame(minWidth: 28)
            }
            .fixedSize()
            Text(":")
            Stepper(value: $timeMinute, in: 0...59, step: 5) {
                Text(String(format: "%02d", timeMinute))
                    .monospacedDigit()
                    .frame(minWidth: 28)
            }
            .fixedSize()
        }
    }

    private var enabledField: some View {
        Toggle(isOn: $draft.isEnabled) {
            Text(L10n.Automation.enabled)
        }
        .toggleStyle(.switch)
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button(L10n.Automation.runNow) {
                    save(closing: false)
                    appState.runAgentRoutineNow(id: draft.id)
                    dismiss()
                }
                .help(L10n.Automation.helpRunOnce)
                .disabled(!isSaveEnabled)
            }
            Spacer()
            Button(L10n.Automation.cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.Automation.save) {
                save(closing: true)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isSaveEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Save

    private var isSaveEnabled: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !prompt.isEmpty
    }

    private func save(closing: Bool) {
        draft.schedule = assembledSchedule()
        // Strip empty model override down to nil so loadouts stay tidy.
        if let modelID = draft.modelID, modelID.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.modelID = nil
        }
        appState.saveAgentRoutine(draft)
        if closing { dismiss() }
    }

    private func assembledSchedule() -> AgentRoutineSchedule {
        switch scheduleKind {
        case .interval: return .interval(minutes: max(1, intervalMinutes))
        case .daily:    return .dailyAt(hour: timeHour, minute: timeMinute)
        case .weekdays: return .weekdaysAt(hour: timeHour, minute: timeMinute)
        case .weekly:   return .weeklyAt(weekday: weekday, hour: timeHour, minute: timeMinute)
        }
    }

    private var currentScheduleSummary: String {
        "\(L10n.Automation.scheduleNextPrefix) \(assembledSchedule().summary)"
    }

    // MARK: Pickers — candidates

    private var workspaceLabel: String {
        guard let path = draft.workspaceRootPath, !path.isEmpty else {
            return L10n.Automation.noWorkspace
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Union of (a) workspaces appearing on existing sessions, (b)
    /// recent folders, (c) the currently open root. Dedup by canonical
    /// path; sorted by lastPathComponent.
    private func knownWorkspaces() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        let sessionRoots: [URL] = appState.agentSessions.compactMap {
            guard let path = $0.workspaceRootPath, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        var pool: [URL] = sessionRoots + appState.recentFolders.map(\.standardizedFileURL)
        if let root = appState.rootDirectory?.standardizedFileURL {
            pool.append(root)
        }
        for url in pool {
            let key = url.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Models the user has already fetched + the configured Flash/Pro
    /// ids from the active provider entry. Dedup and sort.
    private func candidateModels() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in appState.agentKnownModelIDs where !model.isEmpty {
            if seen.insert(model).inserted { result.append(model) }
        }
        for entry in appState.agentProviderLibrary.entries {
            var pool = [entry.flashPrimary, entry.proPrimary]
            pool.append(contentsOf: entry.flashAlternates)
            pool.append(contentsOf: entry.proAlternates)
            for model in pool where !model.isEmpty {
                if seen.insert(model).inserted { result.append(model) }
            }
        }
        return result.sorted()
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
