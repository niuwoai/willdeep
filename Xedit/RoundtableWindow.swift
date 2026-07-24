//
//  RoundtableWindow.swift
//  WillDeep
//
//  专家圆桌独立窗口的三个视图:主页(发起/历史)、讨论中(气泡+态势看板)、
//  文档(终稿+导出)。照 AgentWindowRootView 的范式从 EditorAppStateRegistry
//  取 AppState,不自建、不 attach registry。
//

import SwiftUI

// MARK: - 窗口内路由

enum RoundtableRoute: Equatable {
    case home
    case discussion(runtimeID: UUID, reportID: UUID)
    case document(runtimeID: UUID, reportID: UUID)
}

// MARK: - 根视图

struct RoundtableWindowRootView: View {
    @ObservedObject private var registry = EditorAppStateRegistry.shared
    @State private var route: RoundtableRoute = .home

    var body: some View {
        Group {
            if let appState = registry.current {
                content(appState: appState)
                    .environmentObject(appState)
                    .tint(appState.editorSettings.interfaceSkin.palette.accent)
                    .preferredColorScheme(appState.editorSettings.interfaceSkin.preferredColorScheme)
            } else {
                Color.clear.onAppear { registry.ensureHeadlessFallback() }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func content(appState: AppState) -> some View {
        switch route {
        case .home:
            RoundtableHomeView(route: $route)
        case let .discussion(runtimeID, reportID):
            RoundtableDiscussionView(route: $route, runtimeID: runtimeID, reportID: reportID)
        case let .document(runtimeID, reportID):
            RoundtableDocumentView(route: $route, runtimeID: runtimeID, reportID: reportID)
        }
    }
}

// MARK: - 主页

struct RoundtableHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    @State private var topic: String = ""
    @State private var history: [AgentRoundtableReport] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                composer
                historySection
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reloadHistory)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.sequence")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                Text(L10n.Roundtable.windowTitle)
                    .font(.system(size: 20, weight: .semibold))
            }
            Text(L10n.Roundtable.homeTagline)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $topic)
                .font(.system(size: 15))
                .frame(minHeight: 64)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if topic.isEmpty {
                        Text(L10n.Roundtable.topicPlaceholder)
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            HStack {
                Label(L10n.Roundtable.recommendHint, systemImage: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: start) {
                    Label(L10n.Roundtable.startAction, systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Roundtable.historyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if history.isEmpty {
                Text(L10n.Roundtable.emptyHistory)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(history, id: \.id) { report in
                    RoundtableHistoryRow(report: report) { open(report) }
                }
            }
        }
    }

    private func start() {
        guard let runtimeID = appState.startAgentRoundtable(topic: topic) else { return }
        guard let reportID = reportID(inRuntime: runtimeID) else { return }
        route = .discussion(runtimeID: runtimeID, reportID: reportID)
    }

    private func open(_ report: AgentRoundtableReport) {
        guard let (runtimeID, reportID) = locate(reportID: report.id) else { return }
        if report.phase == .completed, report.finalDocument != nil {
            route = .document(runtimeID: runtimeID, reportID: reportID)
        } else {
            route = .discussion(runtimeID: runtimeID, reportID: reportID)
        }
    }

    private func reloadHistory() {
        history = appState.loadRoundtableHistory()
    }

    /// 找到刚建的圆桌 report id(runtime 内最新一条 roundtable workflow)。
    private func reportID(inRuntime runtimeID: UUID) -> UUID? {
        appState.agentRuntimes[runtimeID]?.messages
            .compactMap { $0.workflowReport }
            .first(where: { $0.roundtable != nil })?
            .id
    }

    /// 从历史 report id 反查它所在的 runtime + workflow report id。
    private func locate(reportID: UUID) -> (UUID, UUID)? {
        for (rid, runtime) in appState.agentRuntimes {
            for message in runtime.messages {
                if let report = message.workflowReport, report.roundtable?.id == reportID {
                    return (rid, report.id)
                }
            }
        }
        return nil
    }
}

private struct RoundtableHistoryRow: View {
    let report: AgentRoundtableReport
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.phase == .completed ? "doc.text" : "ellipsis.bubble")
                    .font(.system(size: 18))
                    .foregroundStyle(report.phase == .completed ? Color.accentColor : Color.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                statusBadge
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let names = report.experts.map(\.displayName).joined(separator: " · ")
        return names.isEmpty ? report.topic : names
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch report.phase {
        case .completed:
            badge(L10n.Roundtable.statusConverged, .green)
        case .failed, .cancelled:
            badge(L10n.Roundtable.statusFailed, .red)
        default:
            badge(L10n.Roundtable.statusRunning, .orange)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - 讨论中

struct RoundtableDiscussionView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    let runtimeID: UUID
    let reportID: UUID
    @State private var hostInput: String = ""

    private var report: AgentRoundtableReport? {
        appState.workflowReport(id: reportID, runtimeID: runtimeID)?.roundtable
    }

    var body: some View {
        HStack(spacing: 0) {
            conversation
            Divider()
            RoundtableDashboard(report: report)
                .frame(width: 240)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    route = .home
                } label: {
                    Label(L10n.Roundtable.backAction, systemImage: "chevron.left")
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(report?.messages ?? [], id: \.id) { message in
                        RoundtableBubble(message: message)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack {
            Text(report?.displayTitle ?? "")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer()
            if let round = report?.currentRound, round > 0 {
                Text(String(format: L10n.Roundtable.roundLabelFormat, round))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(L10n.Roundtable.hostPlaceholder, text: $hostInput)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                Button(L10n.Roundtable.sendAction, action: sendHost)
                    .buttonStyle(.borderedProminent)
                    .disabled(hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if report?.phase == .completed || report?.converged == true {
                Button {
                    route = .document(runtimeID: runtimeID, reportID: reportID)
                } label: {
                    Label(L10n.Roundtable.convergedHint, systemImage: "checkmark.seal")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func sendHost() {
        appState.appendRoundtableUserMessage(runtimeID: runtimeID, reportID: reportID, content: hostInput)
        hostInput = ""
    }
}

private struct RoundtableBubble: View {
    let message: RoundtableMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                Text(message.speakerName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(bubbleBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor, lineWidth: 1))
                if let osr = message.osr {
                    stancePill(osr.stance)
                }
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(avatarColor.opacity(0.18))
            Text(initial).font(.system(size: 13, weight: .medium)).foregroundStyle(avatarColor)
        }
        .frame(width: 30, height: 30)
    }

    private var initial: String {
        switch message.speaker {
        case .chair: return "W"
        case .user: return "你"
        case .expert: return message.role?.avatarInitial ?? "专"
        }
    }

    private var avatarColor: Color {
        switch message.speaker {
        case .chair: return .accentColor
        case .user: return .secondary
        case .expert: return .purple
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(message.isError == true ? Color.red.opacity(0.08) : Color(nsColor: .textBackgroundColor))
    }

    private var borderColor: Color {
        message.isError == true ? Color.red.opacity(0.3) : Color.secondary.opacity(0.15)
    }

    @ViewBuilder
    private func stancePill(_ stance: RoundtableOSR.Stance) -> some View {
        let color: Color = {
            switch stance {
            case .support: return .green
            case .oppose: return .red
            case .neutral: return .secondary
            case .undecided: return .orange
            }
        }()
        Text(stance.displayName)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - 态势看板

private struct RoundtableDashboard: View {
    let report: AgentRoundtableReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.Roundtable.dashboardTitle, systemImage: "rectangle.3.group")
                    .font(.system(size: 13, weight: .medium))
                spectrum
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 立场光谱:按最新一条 OSR 聚合每位专家的态度。
    private var spectrum: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Roundtable.stanceSpectrum)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(latestStances, id: \.name) { entry in
                HStack(spacing: 6) {
                    Circle().fill(entry.color).frame(width: 7, height: 7)
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.stance).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if latestStances.isEmpty {
                Text("—").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }

    private struct StanceEntry { let name: String; let stance: String; let color: Color }

    private var latestStances: [StanceEntry] {
        guard let messages = report?.messages else { return [] }
        var latest: [AgentRoundtableExpertRole: RoundtableOSR] = [:]
        for message in messages {
            if message.speaker == .expert, let role = message.role, let osr = message.osr {
                latest[role] = osr
            }
        }
        return latest.map { role, osr in
            let color: Color = {
                switch osr.stance {
                case .support: return .green
                case .oppose: return .red
                case .neutral: return .secondary
                case .undecided: return .orange
                }
            }()
            return StanceEntry(name: role.displayName, stance: osr.stance.displayName, color: color)
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - 文档视图

struct RoundtableDocumentView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    let runtimeID: UUID
    let reportID: UUID

    private var report: AgentRoundtableReport? {
        appState.workflowReport(id: reportID, runtimeID: runtimeID)?.roundtable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let document = report?.finalDocument, !document.isEmpty {
                    Text(LocalizedStringKey(document))
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L10n.Roundtable.statusRunning)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { route = .home } label: {
                    Label(L10n.Roundtable.backAction, systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: export) {
                    Label(L10n.Roundtable.exportAction, systemImage: "square.and.arrow.down")
                }
                .disabled((report?.finalDocument ?? "").isEmpty)
            }
        }
    }

    private func export() {
        guard let report, let document = report.finalDocument, !document.isEmpty else { return }
        RoundtableDocumentExporter.export(title: report.displayTitle, markdown: document)
    }
}
