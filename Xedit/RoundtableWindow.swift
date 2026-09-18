//
//  RoundtableWindow.swift
//  WillDeep
//
//  专家圆桌的三个视图:主页(发起/历史)、讨论中(气泡+态势看板)、文档(终稿
//  +导出)。同一套视图嵌入主窗口的 .roundtable 目的地，直接使用环境里的
//  AppState。所以导航栏用「页内
//  chrome」而不是 `.toolbar` —— 后者在嵌入宿主里会挂到主窗口工具栏上。
//

import SwiftUI

// MARK: - 窗口内路由

enum RoundtableRoute: Equatable {
    case home
    case preparation(runtimeID: UUID, reportID: UUID)
    case discussion(runtimeID: UUID, reportID: UUID)
    case document(runtimeID: UUID, reportID: UUID)
    /// 专家资料页:从讨论中的专家席点进来。`from*` 记住来路,返回时回到那场讨论。
    case expertProfile(role: AgentRoundtableExpertRole, fromRuntimeID: UUID, fromReportID: UUID)
}

/// 三个页面的共享路由器。嵌入宿主持有 route 状态。
struct RoundtableRouter: View {
    @Binding var route: RoundtableRoute

    var body: some View {
        switch route {
        case .home:
            RoundtableHomeView(route: $route)
        case let .preparation(runtimeID, reportID):
            RoundtablePreparationContainer(
                route: $route,
                runtimeID: runtimeID,
                reportID: reportID
            )
        case let .discussion(runtimeID, reportID):
            RoundtableDiscussionView(route: $route, runtimeID: runtimeID, reportID: reportID)
        case let .document(runtimeID, reportID):
            RoundtableDocumentView(route: $route, runtimeID: runtimeID, reportID: reportID)
        case let .expertProfile(role, fromRuntimeID, fromReportID):
            RoundtableExpertProfileView(
                route: $route,
                role: role,
                fromRuntimeID: fromRuntimeID,
                fromReportID: fromReportID
            )
        }
    }
}

// MARK: - 嵌入主窗口宿主(.roundtable 目的地)

struct RoundtableEmbeddedView: View {
    @State private var route: RoundtableRoute = .home

    var body: some View {
        RoundtableRouter(route: $route)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 主页

struct RoundtableHomeView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    @State private var topic: String = ""
    @State private var history: [AgentRoundtableReport] = []
    /// 报告 id → 承载会话 id。落盘历史不在内存 runtime 里,点开前据此物化。
    @State private var historySessionIDs: [UUID: UUID] = [:]
    @State private var isLoadingHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                composer
                examplesSection
                historySection
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await reloadHistory() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 19))
                        .foregroundStyle(.tint)
                    Text(L10n.Roundtable.windowTitle)
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(L10n.Roundtable.homeTagline)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SubmitOnReturnTextView(
                text: $topic,
                placeholder: L10n.Roundtable.topicPlaceholder,
                onSubmit: start
            )
            .frame(height: 78)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(L10n.Roundtable.recommendHint, systemImage: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(L10n.Roundtable.submitShortcutHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: start) {
                    Label(L10n.Roundtable.startAction, systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.28), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 5)
    }

    /// 示例议题:点一下把话题填进输入框(不直接发起,留给用户改)。
    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.Roundtable.examplesTitle, systemImage: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(L10n.Roundtable.exampleTopics, id: \.self) { example in
                Button {
                    topic = example
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 12))
                            .foregroundStyle(.tint)
                        Text(example)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Roundtable.historyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if history.isEmpty, isLoadingHistory {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if history.isEmpty {
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
        route = .preparation(runtimeID: runtimeID, reportID: reportID)
    }

    private func open(_ report: AgentRoundtableReport) {
        if let sessionID = historySessionIDs[report.id] {
            appState.runtime(for: sessionID)
        }
        guard let (runtimeID, reportID) = locate(reportID: report.id) else { return }
        if report.phase == .completed, report.finalDocument != nil {
            route = .document(runtimeID: runtimeID, reportID: reportID)
        } else if report.phase == .clarifying || report.phase == .selectingExperts {
            route = .preparation(runtimeID: runtimeID, reportID: reportID)
        } else {
            route = .discussion(runtimeID: runtimeID, reportID: reportID)
        }
    }

    private func reloadHistory() async {
        isLoadingHistory = true
        let items = await appState.loadRoundtableHistory()
        isLoadingHistory = false
        guard !Task.isCancelled else { return }
        history = items.map(\.report)
        historySessionIDs = Dictionary(items.map { ($0.report.id, $0.sessionID) }, uniquingKeysWith: { first, _ in first })
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

// MARK: - 会前准备

private struct RoundtablePreparationContainer: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    let runtimeID: UUID
    let reportID: UUID

    private var workflowReport: WorkflowReport? {
        appState.workflowReport(id: reportID, runtimeID: runtimeID)
    }

    private var report: AgentRoundtableReport? {
        workflowReport?.roundtable
    }

    private var isBusy: Bool {
        appState.isAgentRoundtableTaskRunning(reportID: reportID)
    }

    var body: some View {
        Group {
            if let report {
                if report.phase == .selectingExperts {
                    RoundtableExpertSelectionView(
                        report: report,
                        isBusy: isBusy,
                        errorMessage: workflowReport?.summary,
                        providerOptions: appState.agentProviderLibrary.usableEntriesForChatSelection(
                            isSomeIMAuthenticated: SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
                        ),
                        onBackToPreparation: {
                            appState.returnToRoundtablePreparation(
                                runtimeID: runtimeID,
                                reportID: reportID
                            )
                        },
                        onConfirm: { experts, providerEntryID, modelID in
                            if appState.confirmRoundtableExpertSelection(
                                runtimeID: runtimeID,
                                reportID: reportID,
                                experts: experts,
                                providerEntryID: providerEntryID,
                                modelID: modelID
                            ) {
                                route = .discussion(
                                    runtimeID: runtimeID,
                                    reportID: reportID
                                )
                            }
                        }
                    )
                } else {
                    RoundtablePreparationView(
                        report: report,
                        isBusy: isBusy,
                        errorMessage: workflowReport?.summary,
                        providerOptions: appState.agentProviderLibrary.usableEntriesForChatSelection(
                            isSomeIMAuthenticated: SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
                        ),
                        onBack: { route = .home },
                        onRefine: { content in
                            appState.refineRoundtablePreparation(
                                runtimeID: runtimeID,
                                reportID: reportID,
                                content: content
                            )
                        },
                        onChooseExperts: {
                            appState.showRoundtableExpertSelection(
                                runtimeID: runtimeID,
                                reportID: reportID
                            )
                        },
                        // 会前选定的 provider/模型实时写回 report,带到「选择专家」页作为初值。
                        onSelectProviderModel: { providerEntryID, modelID in
                            appState.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                                guard var roundtable = item.roundtable else { return }
                                roundtable.selectedProviderEntryID = providerEntryID
                                roundtable.selectedModelID = modelID
                                roundtable.updatedAt = Date()
                                item.roundtable = roundtable
                            }
                            appState.persistWorkflowRuntime(runtimeID: runtimeID)
                        }
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.regular)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: report?.phase)
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
        case .awaitingUser:
            badge(L10n.Roundtable.statusAwaiting, .orange)
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

private struct LegacyRoundtableDiscussionView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    let runtimeID: UUID
    let reportID: UUID
    @State private var hostInput: String = ""

    private var report: AgentRoundtableReport? {
        appState.workflowReport(id: reportID, runtimeID: runtimeID)?.roundtable
    }

    private var phase: AgentRoundtableReport.Phase? { report?.phase }
    private var isAwaiting: Bool { phase == .awaitingUser }
    private var isTerminal: Bool {
        phase == .completed || phase == .failed || phase == .cancelled
    }

    /// 暂停等答复时,发起反问的那条专家消息(即最后一条消息)携带的可点选项。
    private var awaitingOptions: [String] {
        guard isAwaiting else { return [] }
        return report?.messages.last(where: { ($0.pendingUserOptions?.isEmpty == false) })?
            .pendingUserOptions ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            conversation
            Divider()
            LegacyRoundtableDashboard(report: report)
                .frame(width: 240)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(report?.messages ?? [], id: \.id) { message in
                        LegacyRoundtableBubble(message: message)
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
        HStack(spacing: 10) {
            Button {
                route = .home
            } label: {
                Label(L10n.Roundtable.backAction, systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
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

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .completed:
                Button {
                    route = .document(runtimeID: runtimeID, reportID: reportID)
                } label: {
                    Label(L10n.Roundtable.viewDocumentAction, systemImage: "doc.text")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                Label(L10n.Roundtable.failedNote, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            case .cancelled:
                Label(L10n.Roundtable.cancelledNote, systemImage: "stop.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            default:
                if isAwaiting {
                    awaitingBanner
                }
                inputRow
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var awaitingBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.Roundtable.awaitingBanner, systemImage: "hand.raised")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            if !awaitingOptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(awaitingOptions.enumerated()), id: \.offset) { _, option in
                        Button {
                            send(option)
                        } label: {
                            Text(option)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(isAwaiting ? L10n.Roundtable.answerPlaceholder : L10n.Roundtable.hostPlaceholder,
                      text: $hostInput)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .onSubmit { send(hostInput) }
            Button(L10n.Roundtable.sendAction) { send(hostInput) }
                .buttonStyle(.borderedProminent)
                .disabled(hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTerminal else { return }
        appState.submitRoundtableUserReply(runtimeID: runtimeID, reportID: reportID, content: trimmed)
        hostInput = ""
    }
}

private struct LegacyRoundtableBubble: View {
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

private struct LegacyRoundtableDashboard: View {
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

    // Normalization + markdown parsing walk the whole document, and
    // `persistedDocumentURL` used to hit the filesystem — none of that
    // belongs in per-frame body evaluation. All three are refreshed once
    // per `finalDocument` change from the `.task(id:)` below (same
    // pattern as the editor preview pane) and cached here.
    @State private var normalizedDocument: String = ""
    @State private var documentBlocks: [MarkdownPreviewBlock] = []
    @State private var persistedDocumentURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            if let error = report?.finalDocumentWriteError, persistedDocumentURL == nil {
                documentWriteErrorBanner(error)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !normalizedDocument.isEmpty {
                        ForEach(Array(documentBlocks.enumerated()), id: \.offset) { _, block in
                            MarkdownPreviewBlockView(block: block)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(L10n.Roundtable.statusRunning)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: report?.finalDocument) {
            await refreshDocument()
        }
    }

    /// `.task(id:)` cancels the in-flight pass when `finalDocument` moves
    /// again, so bursts of report updates collapse into one parse of the
    /// latest text.
    private func refreshDocument() async {
        let raw = report?.finalDocument ?? ""
        let parsed = await Task.detached(priority: .userInitiated) { () -> (document: String, blocks: [MarkdownPreviewBlock]) in
            let normalized = AgentRoundtableDocumentNormalizer.normalize(raw)
            return (normalized, MarkdownPreviewParser.blocks(from: normalized))
        }.value
        guard !Task.isCancelled else { return }
        normalizedDocument = parsed.document
        documentBlocks = parsed.blocks
        refreshPersistedDocumentURL()
        persistDocumentIfNeeded()
    }

    private func refreshPersistedDocumentURL() {
        guard let path = report?.finalDocumentFilePath, !path.isEmpty else {
            persistedDocumentURL = nil
            return
        }
        let url = URL(fileURLWithPath: path)
        persistedDocumentURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            Button { route = .home } label: {
                Label(L10n.Roundtable.backAction, systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            Text(report?.displayTitle ?? "")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer()
            // 收敛出文档后仍能回看完整发言流(transcript 持久化)。
            Button {
                route = .discussion(runtimeID: runtimeID, reportID: reportID)
            } label: {
                Label(
                    String(localized: "roundtable.document.viewDiscussion", defaultValue: "查看讨论过程"),
                    systemImage: "bubble.left.and.bubble.right"
                )
                .font(.system(size: 13))
            }
            .buttonStyle(.bordered)
            if let url = persistedDocumentURL {
                Button {
                    RoundtableDocumentExporter.reveal(url)
                } label: {
                    Label(
                        L10n.Roundtable.documentSavedAction,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .help(url.path)
            }
            Button(action: export) {
                Label(L10n.Roundtable.exportAction, systemImage: "square.and.arrow.down")
                    .font(.system(size: 13))
            }
            .buttonStyle(.bordered)
            .disabled(normalizedDocument.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func documentWriteErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L10n.Roundtable.documentSaveFailed(error))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L10n.Roundtable.documentSaveRetry) {
                persistDocumentIfNeeded(force: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private func export() {
        guard let report, !normalizedDocument.isEmpty else { return }
        RoundtableDocumentExporter.export(
            title: report.displayTitle,
            markdown: normalizedDocument
        )
    }

    private func persistDocumentIfNeeded(force: Bool = false) {
        guard let report, !normalizedDocument.isEmpty else { return }
        if !force, persistedDocumentURL != nil, normalizedDocument == report.finalDocument {
            return
        }

        do {
            let url = try RoundtableDocumentExporter.persist(
                reportID: reportID,
                title: report.displayTitle,
                markdown: normalizedDocument
            )
            appState.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                guard var detail = item.roundtable else { return }
                detail.finalDocument = normalizedDocument
                detail.finalDocumentFilePath = url.path
                detail.finalDocumentWriteError = nil
                detail.updatedAt = Date()
                item.summary = normalizedDocument
                item.roundtable = detail
            }
            appState.persistWorkflowRuntime(runtimeID: runtimeID)
            // The write just succeeded — cache directly instead of paying
            // another `fileExists` round trip.
            persistedDocumentURL = url
        } catch {
            let description = error.localizedDescription
            NSLog(
                "Roundtable document backfill failed report=%@ error=%@",
                reportID.uuidString,
                description
            )
            appState.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                guard var detail = item.roundtable else { return }
                detail.finalDocument = normalizedDocument
                detail.finalDocumentFilePath = nil
                detail.finalDocumentWriteError = description
                detail.updatedAt = Date()
                item.summary = normalizedDocument
                item.roundtable = detail
            }
            appState.persistWorkflowRuntime(runtimeID: runtimeID)
            persistedDocumentURL = nil
        }
    }
}

// MARK: - 专家资料页

/// 点击讨论中的专家席某位专家进入:上半是人格简介(头像 / 姓名 / 定位 / persona),
/// 下半是这位专家「参与过的历史讨论」,点任意一条跳进那场对话。整页用该专家的
/// accent 色统一气质,导航沿用 RoundtableRoute(不用 sheet,和圆桌其它页一致)。
struct RoundtableExpertProfileView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    let role: AgentRoundtableExpertRole
    /// 记住是从哪场讨论点进来的,返回时原路回去。
    let fromRuntimeID: UUID
    let fromReportID: UUID

    @State private var discussions: [AgentRoundtableReport] = []
    /// 报告 id → 承载会话 id,落盘讨论点开前据此物化 runtime。
    @State private var discussionSessionIDs: [UUID: UUID] = [:]

    private var accent: Color { RoundtableVisuals.accent(for: role) }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileHeader
                    personaSection
                    discussionsSection
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload() }
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            Button {
                route = .discussion(runtimeID: fromRuntimeID, reportID: fromReportID)
            } label: {
                Label(L10n.Roundtable.backAction, systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            Text(role.personalName)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Text(role.roleTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var profileHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundtableExpertAvatar(role: role, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(role.personalName)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                Text(role.roleTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Text(role.shortExpertise)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.25), lineWidth: 1))
    }

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                String(localized: "roundtable.expertProfile.persona", defaultValue: "人格设定"),
                systemImage: "person.text.rectangle"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accent)
            Text(role.systemPersona)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        }
    }

    private var discussionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(discussionsTitle, systemImage: "bubble.left.and.bubble.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if discussions.isEmpty {
                emptyState
            } else {
                ForEach(discussions, id: \.id) { report in
                    discussionRow(report)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text(
                String(
                    localized: "roundtable.expertProfile.empty",
                    defaultValue: "这位专家还没参与过讨论"
                )
            )
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }

    private func discussionRow(_ report: AgentRoundtableReport) -> some View {
        Button {
            open(report)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.phase == .completed ? "doc.text" : "ellipsis.bubble")
                    .font(.system(size: 16))
                    .foregroundStyle(report.phase == .completed ? accent : Color.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Self.timestampFormatter.string(from: report.updatedAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var discussionsTitle: String {
        let base = String(
            localized: "roundtable.expertProfile.discussions",
            defaultValue: "参与过的讨论"
        )
        return discussions.isEmpty ? base : "\(base) · \(discussions.count)"
    }

    private func reload() async {
        let items = await appState.loadRoundtableHistory()
            .filter { $0.report.experts.contains(role) }
        guard !Task.isCancelled else { return }
        discussions = items.map(\.report)
        discussionSessionIDs = Dictionary(items.map { ($0.report.id, $0.sessionID) }, uniquingKeysWith: { first, _ in first })
    }

    /// 与主页 open(_:) 同款相位路由:完成态进文档,会前态进准备,其余进讨论。
    private func open(_ report: AgentRoundtableReport) {
        if let sessionID = discussionSessionIDs[report.id] {
            appState.runtime(for: sessionID)
        }
        guard let (runtimeID, reportID) = locate(reportID: report.id) else { return }
        if report.phase == .completed, report.finalDocument != nil {
            route = .document(runtimeID: runtimeID, reportID: reportID)
        } else if report.phase == .clarifying || report.phase == .selectingExperts {
            route = .preparation(runtimeID: runtimeID, reportID: reportID)
        } else {
            route = .discussion(runtimeID: runtimeID, reportID: reportID)
        }
    }

    /// 从历史 report id 反查它所在的 runtime + workflow report id(落盘会话已在 open 里先物化)。
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
