//
//  AgentConsultationViews.swift
//  WillDeep
//
//  Setup sheet and transcript card for multi-expert consultations.
//

import AppKit
import SwiftUI

struct AgentConsultationSetupSheet: View {
    let onCancel: () -> Void
    let onStart: (String, AgentConsultationConfiguration) -> Void

    @State private var taskText: String
    @State private var experts: [AgentConsultationExpertConfiguration]
    @State private var modelSuggestions: [AgentConsultationExpertKind: [String]]
    @State private var mode: AgentConsultationMode = .structured
    @State private var groupRounds = 3
    private let installedKinds: Set<AgentConsultationExpertKind>
    private let executablePaths: [AgentConsultationExpertKind: String]

    init(
        task: String,
        onCancel: @escaping () -> Void,
        onStart: @escaping (String, AgentConsultationConfiguration) -> Void
    ) {
        self.onCancel = onCancel
        self.onStart = onStart
        let discoveries = LocalAgentCLI.discoverAll()
        let installedDiscoveries = discoveries.filter(\.isInstalled)
        let installedIDs = Set(installedDiscoveries.map { $0.cli.id })
        let installedKinds = Set(AgentConsultationExpertKind.allCases.filter {
            installedIDs.contains($0.cliCatalogID)
        })
        self.installedKinds = installedKinds
        self.executablePaths = Dictionary(
            uniqueKeysWithValues: AgentConsultationExpertKind.allCases.compactMap { kind in
                guard let path = installedDiscoveries.first(where: { $0.cli.id == kind.cliCatalogID })?.path else {
                    return nil
                }
                return (kind, path)
            }
        )
        _taskText = State(initialValue: task)
        _experts = State(initialValue: AgentConsultationExpertKind.allCases.map {
            AgentConsultationExpertConfiguration(
                kind: $0,
                isEnabled: installedKinds.contains($0)
            )
        })
        _modelSuggestions = State(initialValue: Dictionary(
            uniqueKeysWithValues: AgentConsultationExpertKind.allCases.map {
                ($0, $0.suggestedModelIDs)
            }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Consultation.setupTitle)
                        .font(.title3.weight(.semibold))
                    Text(L10n.Consultation.readOnlyBadge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.Consultation.setupOverview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Consultation.taskLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $taskText)
                    .font(.system(size: 13))
                    .frame(minHeight: 64, maxHeight: 96)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Consultation.modeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(L10n.Consultation.modeLabel, selection: $mode) {
                    ForEach(AgentConsultationMode.allCases) { option in
                        Text(L10n.Consultation.modeName(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(L10n.Consultation.modeDescription(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if mode == .groupChat {
                    Stepper(
                        L10n.Consultation.groupRoundsValue(groupRounds),
                        value: $groupRounds,
                        in: 2...5
                    )
                    .font(.system(size: 12, weight: .medium))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Consultation.expertsLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach($experts) { $expert in
                    expertRow($expert)
                }
            }

            if enabledInstalledCount < 2 {
                Label(L10n.Consultation.twoExpertsRequired, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(L10n.Consultation.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(mode == .groupChat ? L10n.Consultation.startGroupChat : L10n.Consultation.start) {
                    onStart(
                        taskText,
                        AgentConsultationConfiguration(
                            experts: experts,
                            mode: mode,
                            groupRounds: groupRounds
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(enabledInstalledCount < 2 || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 610)
        .task {
            await refreshModelSuggestions()
        }
    }

    private var enabledInstalledCount: Int {
        experts.filter { $0.isEnabled && installedKinds.contains($0.kind) }.count
    }

    @ViewBuilder
    private func expertRow(_ expert: Binding<AgentConsultationExpertConfiguration>) -> some View {
        let kind = expert.wrappedValue.kind
        let installed = installedKinds.contains(kind)
        HStack(spacing: 10) {
            Toggle("", isOn: expert.isEnabled)
                .labelsHidden()
                .disabled(!installed)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(installed ? L10n.Consultation.installed : L10n.Consultation.notInstalled)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(installed ? Color.green : Color.secondary)
                }
                Text(L10n.Consultation.role(kind))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                TextField(L10n.Consultation.modelPlaceholder, text: expert.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .disabled(!installed || !expert.wrappedValue.isEnabled)
                modelPickerMenu(for: expert, installed: installed)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func modelPickerMenu(
        for expert: Binding<AgentConsultationExpertConfiguration>,
        installed: Bool
    ) -> some View {
        Menu {
            Button {
                expert.wrappedValue.model = ""
            } label: {
                Label(L10n.Consultation.useCLIDefaultModel, systemImage: "arrow.uturn.backward")
            }
            Divider()
            ForEach(modelIDs(for: expert.wrappedValue.kind), id: \.self) { modelID in
                Button {
                    expert.wrappedValue.model = modelID
                } label: {
                    if expert.wrappedValue.normalizedModel == modelID {
                        Label(modelID, systemImage: "checkmark")
                    } else {
                        Text(modelID)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 26, height: 26)
        .disabled(!installed || !expert.wrappedValue.isEnabled)
        .help(L10n.Consultation.modelPickerHelp(expert.wrappedValue.kind.displayName))
    }

    private func modelIDs(for kind: AgentConsultationExpertKind) -> [String] {
        modelSuggestions[kind] ?? kind.suggestedModelIDs
    }

    private func refreshModelSuggestions() async {
        let paths = executablePaths
        let refreshed = await Task.detached {
            Dictionary(
                uniqueKeysWithValues: AgentConsultationExpertKind.allCases.map { kind in
                    (
                        kind,
                        AgentConsultationModelCatalog.suggestions(
                            for: kind,
                            executablePath: paths[kind]
                        )
                    )
                }
            )
        }.value
        modelSuggestions = refreshed
    }
}

struct AgentConsultationCardView: View {
    @EnvironmentObject private var appState: AppState
    let report: WorkflowReport

    @State private var expanded = true
    @State private var didCopy = false

    private var consultation: AgentConsultationReport? { report.consultation }

    var body: some View {
        if let consultation {
            VStack(alignment: .leading, spacing: 10) {
                header(consultation)
                phaseRow(consultation)
                if expanded {
                    Divider().opacity(0.5)
                    details(consultation)
                }
                footer(consultation)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(statusColor.opacity(0.4), lineWidth: 1)
            )
            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
        }
    }

    private func header(_ consultation: AgentConsultationReport) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(consultation.effectiveMode == .groupChat
                     ? L10n.Consultation.groupChatTitle
                     : L10n.Consultation.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(consultation.task)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if report.status == .planning || report.status == .running {
                Button(L10n.Consultation.stop) {
                    appState.stopAgentConsultation(reportID: report.id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
        }
    }

    private func phaseRow(_ consultation: AgentConsultationReport) -> some View {
        HStack(spacing: 8) {
            if report.status == .planning || report.status == .running {
                ProgressView().controlSize(.small)
            }
            Text(L10n.Consultation.phase(consultation.phase))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(progressText(consultation))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func details(_ consultation: AgentConsultationReport) -> some View {
        Group {
            if consultation.effectiveMode == .groupChat {
                groupChatDetails(consultation)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    consultationSection(
                        title: L10n.Consultation.initialDraft,
                        text: consultation.initialDraft
                    )
                    expertSection(
                        title: L10n.Consultation.firstRound,
                        consultation: consultation,
                        keyPath: \.firstRoundReview
                    )
                    consultationSection(
                        title: L10n.Consultation.preliminary,
                        text: consultation.preliminarySynthesis
                    )
                    expertSection(
                        title: L10n.Consultation.peerRound,
                        consultation: consultation,
                        keyPath: \.peerReview
                    )
                    consultationSection(
                        title: L10n.Consultation.finalConclusion,
                        text: consultation.finalSynthesis
                    )
                }
            }
        }
    }

    private func groupChatDetails(_ consultation: AgentConsultationReport) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(consultation.effectiveGroupMessages) { message in
                groupMessage(message, totalRounds: consultation.effectiveGroupRounds)
            }
        }
    }

    private func groupMessage(
        _ message: AgentConsultationReport.GroupMessage,
        totalRounds: Int
    ) -> some View {
        let isChair = message.speaker == .chair
        let isError = message.isError == true
        let name = message.expertKind?.displayName ?? L10n.Consultation.chairName
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: isError
                      ? "exclamationmark.triangle"
                      : (isChair ? "person.crop.circle.badge.checkmark" : "person.crop.circle"))
                Text(name).fontWeight(.semibold)
                Text(groupMessagePhase(message.round, totalRounds: totalRounds))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(isError ? Color.red : Color.primary)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isError ? Color.red : (isChair ? Color.accentColor : Color.secondary))
                .opacity(isError ? 0.08 : (isChair ? 0.10 : 0.07)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func groupMessagePhase(_ round: Int, totalRounds: Int) -> String {
        if round == 0 { return L10n.Consultation.groupOpeningLabel }
        if round > totalRounds { return L10n.Consultation.finalConclusion }
        return L10n.Consultation.roundLabel(round)
    }

    private func progressText(_ consultation: AgentConsultationReport) -> String {
        if consultation.effectiveMode == .groupChat {
            if consultation.effectiveCurrentRound == 0 {
                return L10n.Consultation.groupOpeningLabel
            }
            return L10n.Consultation.roundProgress(
                consultation.effectiveCurrentRound,
                consultation.effectiveGroupRounds
            )
        }
        return L10n.Consultation.progress(
            consultation.completedExpertCount,
            consultation.experts.count
        )
    }

    @ViewBuilder
    private func consultationSection(title: String, text: String) -> some View {
        if !text.isEmpty {
            DisclosureGroup(title) {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    @ViewBuilder
    private func expertSection(
        title: String,
        consultation: AgentConsultationReport,
        keyPath: KeyPath<AgentConsultationReport.Expert, String>
    ) -> some View {
        let visible = consultation.experts.filter { !$0[keyPath: keyPath].isEmpty || $0.errorMessage != nil }
        if !visible.isEmpty {
            DisclosureGroup(title) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { expert in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(expert.kind.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                if let model = expert.model {
                                    Text(model)
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            let content = expert[keyPath: keyPath]
                            if !content.isEmpty {
                                Text(content)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                            } else if let error = expert.errorMessage {
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private func footer(_ consultation: AgentConsultationReport) -> some View {
        HStack {
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
            Spacer()
            if !consultation.finalSynthesis.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(consultation.finalSynthesis, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(L10n.Consultation.copyFinal)
            }
        }
    }

    private var statusColor: Color {
        switch report.status {
        case .planning, .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var statusText: String {
        switch report.status {
        case .planning, .running: return L10n.Consultation.reviewing
        case .done: return L10n.Consultation.completed
        case .failed: return L10n.Consultation.failedStatus
        case .cancelled: return L10n.Consultation.cancelledStatus
        }
    }
}
