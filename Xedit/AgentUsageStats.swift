//
//  AgentUsageStats.swift
//  WillDeep
//
//  Pure analytics over the persisted Agent sessions. Powers the
//  Claude-Code-style stats dashboard shown in place of the empty-chat
//  hero. Nothing here talks to a provider — feed it either live
//  `[AgentSession]` values or lightweight persisted usage snapshots and
//  it computes everything else.
//

import Foundation

/// Aggregate metrics for the Agent-mode stats dashboard.
struct AgentUsageOverview: Equatable {
    var sessionCount: Int
    var messageCount: Int
    /// User-authored requests. This is intentionally narrower than total
    /// messages: a tool result or workflow card is not a new task.
    var userTurnCount: Int
    /// Tool calls requested by the model. Historical data does not retain a
    /// reliable outcome for every call, so this is an invocation count — not
    /// a misleading "success" metric.
    var toolCallCount: Int
    /// Files changed by the agent, counted from each session's persisted
    /// work ledger.
    var editedFileCount: Int
    /// User-facing artifacts created during sessions, counted from the
    /// separate artifact ledger rather than guessed from Git status.
    var artifactCount: Int
    /// Explicit slash-workflow runs represented by persisted workflow cards.
    var workflowCount: Int
    /// Distinct local or remote workspaces represented in the selected range.
    var workspaceCount: Int
    /// Sum of `AgentMessage.usageTokens` where reported; for messages
    /// without a real usage number we fall back to chars/4 + per-image
    /// budget so old sessions still contribute something.
    var totalTokens: Int
    /// True when at least one message had a real usage number — the UI
    /// labels the total "≈" otherwise.
    var hasAnyRealUsage: Bool
    /// Distinct calendar days (user's current timezone) that saw at
    /// least one message.
    var activeDays: Int
    /// Length of the most recent run of consecutive active days. If
    /// today is still empty, the run ending yesterday remains current.
    var currentStreak: Int
    /// Length of the longest run of consecutive active days ever.
    var longestStreak: Int
    /// Hour-of-day (0-23) with the most messages. Nil if no messages.
    var peakHour: Int?
    /// Model ID with the most messages routed through it.
    var favoriteModel: String?
}

/// One cell of the GitHub-style heatmap: a calendar day plus the
/// real-or-estimated Token usage recorded on that day.
struct AgentHeatmapCell: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let tokenCount: Int
}

struct AgentModelUsageRow: Identifiable, Equatable {
    var id: String { "\(providerID)|\(modelID)" }
    let providerID: String
    let providerName: String
    let modelID: String
    var sessionCount: Int
    var messageCount: Int
    var promptTokens: Int
    var completionTokens: Int
    var cachedPromptTokens: Int
    var cacheWritePromptTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var estimatedTokens: Int
    var estimatedCostUSD: Double?
    var hasEstimatedUsage: Bool
    var isDelegatedExternal: Bool
    var cacheDiagnosticTurns: Int
    var stablePrefixCharactersTotal: Int

    var cacheHitRate: Double {
        guard promptTokens > 0 else { return 0 }
        return Double(cachedPromptTokens) / Double(promptTokens)
    }

    var averageStablePrefixCharacters: Int {
        guard cacheDiagnosticTurns > 0 else { return 0 }
        return stablePrefixCharactersTotal / cacheDiagnosticTurns
    }
}

/// A human-scale grouping of the raw tool names recorded in a conversation.
/// It lets the dashboard describe what the agent actually helped with without
/// pretending that merely enabled Skills or MCP servers were used.
enum AgentUsageCapability: String, CaseIterable, Hashable, Identifiable {
    case workspace
    case coding
    case terminal
    case research
    case browser
    case media
    case automation
    case integration
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: return L10n.StatsDashboard.capabilityWorkspace
        case .coding: return L10n.StatsDashboard.capabilityCoding
        case .terminal: return L10n.StatsDashboard.capabilityTerminal
        case .research: return L10n.StatsDashboard.capabilityResearch
        case .browser: return L10n.StatsDashboard.capabilityBrowser
        case .media: return L10n.StatsDashboard.capabilityMedia
        case .automation: return L10n.StatsDashboard.capabilityAutomation
        case .integration: return L10n.StatsDashboard.capabilityIntegration
        case .general: return L10n.StatsDashboard.capabilityGeneral
        }
    }

    var systemImage: String {
        switch self {
        case .workspace: return "folder"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .research: return "globe"
        case .browser: return "safari"
        case .media: return "photo.on.rectangle"
        case .automation: return "clock.arrow.circlepath"
        case .integration: return "puzzlepiece.extension"
        case .general: return "wrench.and.screwdriver"
        }
    }
}

struct AgentCapabilityUsageRow: Identifiable, Equatable {
    let capability: AgentUsageCapability
    let callCount: Int

    var id: AgentUsageCapability { capability }
}

/// A distinct artifact referenced by chats that were active in the current
/// calendar week. Artifact ledgers are session-scoped, so the label remains
/// honest: this is work surfaced from this week's active chats, not a guess
/// based on Git status or filesystem timestamps.
struct AgentWeeklyDeliverableRow: Identifiable, Equatable {
    let path: String
    let sessionCount: Int
    let mostRecentSessionUpdate: Date

    var id: String { path }

    var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// A persisted, explicit tool execution failure. Denied approvals are not
/// included: a user choosing not to run a tool is not a tool failure.
struct AgentFailedToolCallReviewRow: Identifiable, Equatable {
    let toolName: String
    let errorSummary: String
    let occurredAt: Date

    var id: String { "\(toolName)|\(occurredAt.timeIntervalSinceReferenceDate)|\(errorSummary)" }
}

nonisolated struct AgentUsageSessionSnapshot: Identifiable, Equatable {
    let id: UUID
    var modelID: String?
    var providerID: String?
    var providerDisplayName: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [AgentUsageMessageSnapshot]
    var workspaceIdentifier: String?
    var editedFileCount: Int
    var artifactCount: Int
    var artifactPaths: [String]
    /// True when this session ran under 省心托管 (some.im managed routing).
    /// Managed sessions never persist a resolved `modelID` (it's cleared in
    /// `AppStateAgentSessions` because routing is per-turn), so without this
    /// flag their usage collapses into the anonymous "unknown-model" bucket
    /// alongside genuinely-unknown legacy sessions. We carry the signal so
    /// managed traffic can be attributed to a single "省心托管" pseudo-model
    /// instead — and legacy nils stay unknown.
    var isManagedRouting: Bool

    init(
        id: UUID,
        modelID: String?,
        providerID: String?,
        providerDisplayName: String?,
        createdAt: Date,
        updatedAt: Date,
        messages: [AgentUsageMessageSnapshot],
        workspaceIdentifier: String? = nil,
        editedFileCount: Int = 0,
        artifactCount: Int = 0,
        artifactPaths: [String] = [],
        isManagedRouting: Bool = false
    ) {
        self.id = id
        self.modelID = modelID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.workspaceIdentifier = workspaceIdentifier
        self.editedFileCount = editedFileCount
        self.artifactCount = artifactCount
        self.artifactPaths = artifactPaths
        self.isManagedRouting = isManagedRouting
    }

    init(session: AgentSession) {
        self.init(
            id: session.id,
            modelID: session.modelID,
            providerID: session.providerID,
            providerDisplayName: session.providerDisplayName,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            messages: session.messages.map { AgentUsageMessageSnapshot(message: $0) },
            workspaceIdentifier: Self.workspaceIdentifier(
                for: session.sidebarWorkspaceRootPath.map { .local(path: $0) }
                    ?? session.workspaceLocation
                    ?? session.workspaceRootPath.map { .local(path: $0) }
            ),
            editedFileCount: session.agentEditedPaths.count,
            artifactCount: session.agentArtifactPaths.count,
            artifactPaths: session.agentArtifactPaths,
            isManagedRouting: session.managedRouting != nil
        )
    }

    private static func workspaceIdentifier(for location: WorkspaceLocation?) -> String? {
        guard let location else { return nil }
        switch location {
        case .local(let path):
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : "local:\(normalized)"
        case .remote(let runtimeID, let path):
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : "remote:\(runtimeID.uuidString):\(normalized)"
        }
    }
}

nonisolated struct AgentUsageMessageSnapshot: Equatable {
    var role: AgentRole
    var contentCharacterCount: Int
    var reasoningCharacterCount: Int
    var imageCount: Int
    var toolCallArgumentCharacterCount: Int
    var toolCallNames: [String]
    var toolCallExternalIDs: [String]
    var toolCallID: String?
    var toolCallStatus: AgentToolCallStatus?
    var toolErrorMessage: String?
    var usageTokens: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedPromptTokens: Int?
    var cacheWritePromptTokens: Int?
    var reasoningTokens: Int?
    var origin: AgentMessageOrigin?
    var originLabel: String?
    var requestStablePrefixCharacters: Int?
    var createdAt: Date

    init(
        role: AgentRole,
        contentCharacterCount: Int,
        reasoningCharacterCount: Int = 0,
        imageCount: Int = 0,
        toolCallArgumentCharacterCount: Int = 0,
        toolCallNames: [String] = [],
        toolCallExternalIDs: [String] = [],
        toolCallID: String? = nil,
        toolCallStatus: AgentToolCallStatus? = nil,
        toolErrorMessage: String? = nil,
        usageTokens: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        cacheWritePromptTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        origin: AgentMessageOrigin? = nil,
        originLabel: String? = nil,
        requestStablePrefixCharacters: Int? = nil,
        createdAt: Date
    ) {
        self.role = role
        self.contentCharacterCount = contentCharacterCount
        self.reasoningCharacterCount = reasoningCharacterCount
        self.imageCount = imageCount
        self.toolCallArgumentCharacterCount = toolCallArgumentCharacterCount
        self.toolCallNames = toolCallNames
        self.toolCallExternalIDs = toolCallExternalIDs
        self.toolCallID = toolCallID
        self.toolCallStatus = toolCallStatus
        self.toolErrorMessage = toolErrorMessage
        self.usageTokens = usageTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.cacheWritePromptTokens = cacheWritePromptTokens
        self.reasoningTokens = reasoningTokens
        self.origin = origin
        self.originLabel = originLabel
        self.requestStablePrefixCharacters = requestStablePrefixCharacters
        self.createdAt = createdAt
    }

    init(message: AgentMessage) {
        self.init(
            role: message.role,
            contentCharacterCount: message.modelContent.count,
            reasoningCharacterCount: message.reasoningContent?.count ?? 0,
            imageCount: message.images.count,
            toolCallArgumentCharacterCount: message.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count },
            toolCallNames: message.toolCalls.map(\.toolName),
            toolCallExternalIDs: message.toolCalls.map(\.externalID),
            toolCallID: message.toolCallID,
            toolCallStatus: message.toolCallStatus,
            toolErrorMessage: message.toolErrorMessage,
            usageTokens: message.usageTokens,
            promptTokens: message.promptTokens,
            completionTokens: message.completionTokens,
            cachedPromptTokens: message.cachedPromptTokens,
            cacheWritePromptTokens: message.cacheWritePromptTokens,
            reasoningTokens: message.reasoningTokens,
            origin: message.origin,
            originLabel: message.originLabel,
            requestStablePrefixCharacters: message.requestStablePrefixCharacters,
            createdAt: message.createdAt
        )
    }
}

enum AgentUsageStats {
    /// Build an overview snapshot for the given sessions. Pure function
    /// — same input always produces the same output, no side effects.
    static func overview(for sessions: [AgentSession], now: Date = Date()) -> AgentUsageOverview {
        overview(for: sessions.map { AgentUsageSessionSnapshot(session: $0) }, now: now)
    }

    static func overview(
        for sessions: [AgentUsageSessionSnapshot],
        allTimeStreakSessions: [AgentUsageSessionSnapshot]? = nil,
        now: Date = Date()
    ) -> AgentUsageOverview {
        let allMessages = sessions.flatMap(\.messages)
        let messageCount = allMessages.count
        let sessionCount = sessions.count
        let userTurnCount = allMessages.count { $0.role == .user }
        let toolCallCount = allMessages.reduce(0) { $0 + $1.toolCallNames.count }
        let editedFileCount = sessions.reduce(0) { $0 + $1.editedFileCount }
        let artifactCount = sessions.reduce(0) { $0 + $1.artifactCount }
        let workflowCount = allMessages.count { $0.role == .workflowReport }
        let workspaceCount = Set(sessions.compactMap(\.workspaceIdentifier)).count

        var totalTokens = 0
        var hasAnyRealUsage = false
        for message in allMessages {
            if let usage = message.usageTokens, usage > 0 {
                totalTokens += usage
                hasAnyRealUsage = true
            } else {
                totalTokens += estimateTokens(for: message)
            }
        }

        let calendar = Calendar.current
        let dayKeys: [Date] = allMessages.map { calendar.startOfDay(for: $0.createdAt) }
        let uniqueDays = Set(dayKeys)
        let activeDays = uniqueDays.count

        let streakMessages = (allTimeStreakSessions ?? sessions).flatMap(\.messages)
        let streakDays = Set(streakMessages.map { calendar.startOfDay(for: $0.createdAt) })
        let streaks = computeStreaks(
            uniqueDays: streakDays,
            now: now,
            calendar: calendar
        )

        var hourCounts: [Int: Int] = [:]
        for message in allMessages {
            let hour = calendar.component(.hour, from: message.createdAt)
            hourCounts[hour, default: 0] += 1
        }
        let peakHour = hourCounts.max { $0.value < $1.value }?.key

        var modelCounts: [String: Int] = [:]
        for session in sessions {
            guard let model = session.modelID, !model.isEmpty else { continue }
            modelCounts[model, default: 0] += session.messages.count
        }
        let favoriteModel = modelCounts.max { $0.value < $1.value }?.key

        return AgentUsageOverview(
            sessionCount: sessionCount,
            messageCount: messageCount,
            userTurnCount: userTurnCount,
            toolCallCount: toolCallCount,
            editedFileCount: editedFileCount,
            artifactCount: artifactCount,
            workflowCount: workflowCount,
            workspaceCount: workspaceCount,
            totalTokens: totalTokens,
            hasAnyRealUsage: hasAnyRealUsage,
            activeDays: activeDays,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            peakHour: peakHour,
            favoriteModel: favoriteModel
        )
    }

    /// Produce a GitHub-style heatmap: `weekCount` columns of 7 rows
    /// each (Mon..Sun), summing real-or-estimated Token usage per day in
    /// the user's local timezone. Defaults to 12 weeks. Returned in
    /// column-major order (oldest column first); the caller renders
    /// left → right.
    static func heatmap(
        for sessions: [AgentSession],
        weekCount: Int = 12,
        now: Date = Date()
    ) -> [[AgentHeatmapCell]] {
        heatmap(for: sessions.map { AgentUsageSessionSnapshot(session: $0) }, weekCount: weekCount, now: now)
    }

    static func heatmap(
        for sessions: [AgentUsageSessionSnapshot],
        weekCount: Int = 12,
        now: Date = Date()
    ) -> [[AgentHeatmapCell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let earliestStart = calendar.date(byAdding: .day, value: -(weekCount * 7 - 1), to: today) else {
            return []
        }

        let messages = sessions.flatMap(\.messages)
        var perDay: [Date: Int] = [:]
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day < earliestStart { continue }
            let tokenCount = message.usageTokens.flatMap { $0 > 0 ? $0 : nil }
                ?? estimateTokens(for: message)
            perDay[day, default: 0] += tokenCount
        }

        var columns: [[AgentHeatmapCell]] = []
        for week in 0..<weekCount {
            var column: [AgentHeatmapCell] = []
            for day in 0..<7 {
                let offset = week * 7 + day
                guard let date = calendar.date(byAdding: .day, value: offset, to: earliestStart) else { continue }
                let tokenCount = perDay[date] ?? 0
                column.append(AgentHeatmapCell(date: date, tokenCount: tokenCount))
            }
            columns.append(column)
        }
        return columns
    }

    /// Number of "War and Peace"s the user has burned through, for the
    /// fun-fact line in the dashboard footer. War and Peace ≈ 587k words ≈ 783k
    /// tokens at our chars/4 heuristic. We just call it 780k for round numbers.
    static func warAndPeaceEquivalents(tokenTotal: Int) -> Double {
        guard tokenTotal > 0 else { return 0 }
        return Double(tokenTotal) / 780_000.0
    }

    static func modelUsage(for sessions: [AgentSession]) -> [AgentModelUsageRow] {
        modelUsage(for: sessions.map { AgentUsageSessionSnapshot(session: $0) })
    }

    static func modelUsage(for sessions: [AgentUsageSessionSnapshot]) -> [AgentModelUsageRow] {
        var rows: [String: AgentModelUsageRow] = [:]

        for session in sessions {
            var seenKeysInSession = Set<String>()

            for message in session.messages where message.role == .assistant {
                let identity = usageIdentity(for: message, session: session)
                let key = "\(identity.provider.id)|\(identity.modelID)"
                var row = rows[key] ?? AgentModelUsageRow(
                    providerID: identity.provider.id,
                    providerName: identity.provider.name,
                    modelID: identity.modelID,
                    sessionCount: 0,
                    messageCount: 0,
                    promptTokens: 0,
                    completionTokens: 0,
                    cachedPromptTokens: 0,
                    cacheWritePromptTokens: 0,
                    reasoningTokens: 0,
                    totalTokens: 0,
                    estimatedTokens: 0,
                    estimatedCostUSD: nil,
                    hasEstimatedUsage: false,
                    isDelegatedExternal: identity.isDelegatedExternal,
                    cacheDiagnosticTurns: 0,
                    stablePrefixCharactersTotal: 0
                )
                if seenKeysInSession.insert(key).inserted {
                    row.sessionCount += 1
                }
                let usage = usageBreakdown(for: message)
                row.messageCount += 1
                row.promptTokens += usage.prompt
                row.completionTokens += usage.completion
                row.cachedPromptTokens += usage.cachedPrompt
                row.cacheWritePromptTokens += usage.cacheWritePrompt
                row.reasoningTokens += usage.reasoning
                row.totalTokens += usage.total
                row.estimatedTokens += usage.estimated
                row.hasEstimatedUsage = row.hasEstimatedUsage || usage.isEstimated
                if let stable = message.requestStablePrefixCharacters, stable > 0 {
                    row.cacheDiagnosticTurns += 1
                    row.stablePrefixCharactersTotal += stable
                }
                row.isDelegatedExternal = row.isDelegatedExternal || identity.isDelegatedExternal
                row.estimatedCostUSD = estimatedCostUSD(for: row)
                rows[key] = row
            }
        }

        return rows.values
            .filter { $0.messageCount > 0 || $0.totalTokens > 0 }
            .sorted {
                let lhs = $0.estimatedCostUSD ?? -1
                let rhs = $1.estimatedCostUSD ?? -1
                if lhs != rhs { return lhs > rhs }
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
                return $0.modelID < $1.modelID
            }
    }

    static func capabilityUsage(for sessions: [AgentSession]) -> [AgentCapabilityUsageRow] {
        capabilityUsage(for: sessions.map { AgentUsageSessionSnapshot(session: $0) })
    }

    static func capabilityUsage(for sessions: [AgentUsageSessionSnapshot]) -> [AgentCapabilityUsageRow] {
        var counts: [AgentUsageCapability: Int] = [:]
        for toolName in sessions.flatMap(\.messages).flatMap(\.toolCallNames) {
            counts[capability(for: toolName), default: 0] += 1
        }

        return counts.map { AgentCapabilityUsageRow(capability: $0.key, callCount: $0.value) }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                return $0.capability.rawValue < $1.capability.rawValue
            }
    }

    static func weeklyDeliverables(
        for sessions: [AgentUsageSessionSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgentWeeklyDeliverableRow] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var entries: [String: (sessionIDs: Set<UUID>, mostRecent: Date)] = [:]

        for session in sessions where week.contains(session.updatedAt) {
            for path in session.artifactPaths {
                let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                var entry = entries[normalized] ?? ([], session.updatedAt)
                entry.sessionIDs.insert(session.id)
                entry.mostRecent = max(entry.mostRecent, session.updatedAt)
                entries[normalized] = entry
            }
        }

        return entries.map {
            AgentWeeklyDeliverableRow(
                path: $0.key,
                sessionCount: $0.value.sessionIDs.count,
                mostRecentSessionUpdate: $0.value.mostRecent
            )
        }
        .sorted {
            if $0.mostRecentSessionUpdate != $1.mostRecentSessionUpdate {
                return $0.mostRecentSessionUpdate > $1.mostRecentSessionUpdate
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    static func failedToolCallReview(
        for sessions: [AgentUsageSessionSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgentFailedToolCallReviewRow] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var reviewRows: [AgentFailedToolCallReviewRow] = []

        for session in sessions {
            var namesByCallID: [String: String] = [:]
            for message in session.messages {
                for (identifier, name) in zip(message.toolCallExternalIDs, message.toolCallNames) where !identifier.isEmpty && !name.isEmpty {
                    namesByCallID[identifier] = name
                }
            }
            for message in session.messages {
                guard message.role == .tool,
                      message.toolCallStatus == .failed,
                      week.contains(message.createdAt),
                      let callID = message.toolCallID,
                      let toolName = namesByCallID[callID] else {
                    continue
                }
                reviewRows.append(
                    AgentFailedToolCallReviewRow(
                        toolName: toolName,
                        errorSummary: errorSummary(message.toolErrorMessage),
                        occurredAt: message.createdAt
                    )
                )
            }
        }

        return reviewRows.sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: - Internals

    private static func capability(for rawToolName: String) -> AgentUsageCapability {
        let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if toolName.contains("web_search") || toolName.contains("web_fetch") || toolName.contains("research") {
            return .research
        }
        if toolName.contains("browser") || toolName.contains("computer_use") || toolName.contains("computer") {
            return .browser
        }
        if toolName.contains("image") || toolName.contains("video") || toolName.contains("audio") || toolName.contains("media") {
            return .media
        }
        if toolName.contains("terminal") || toolName.contains("run_command") || toolName.contains("shell") {
            return .terminal
        }
        if toolName.contains("workflow") || toolName.contains("schedule") || toolName.contains("routine") {
            return .automation
        }
        if toolName.contains("mcp") || toolName.contains("connector") || toolName.contains("integration") {
            return .integration
        }
        if toolName.contains("read_file") || toolName.contains("list_directory") || toolName.contains("search_files") {
            return .workspace
        }
        if toolName.contains("patch") || toolName.contains("edit") || toolName.contains("write") || toolName.contains("git") || toolName.contains("grep") || toolName.contains("code") {
            return .coding
        }
        return .general
    }

    private static func errorSummary(_ message: String?) -> String {
        let normalized = (message ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return L10n.StatsDashboard.failureDetailUnavailable }
        return String(normalized.prefix(140))
    }

    private static func estimateTokens(for message: AgentUsageMessageSnapshot) -> Int {
        var total = max(0, message.contentCharacterCount / 4)
        // Reasoning content costs tokens too even when the provider
        // doesn't split it out.
        total += message.reasoningCharacterCount / 4
        // Tool-call argument bodies are part of the wire payload.
        total += message.toolCallArgumentCharacterCount / 4
        // Per-image flat budget aligning with AppState.estimatedAgentTokens.
        total += message.imageCount * 600
        return total
    }

    /// Display/grouping key for 省心托管 traffic. Doubles as the model label
    /// in the usage table; no price row matches it, so it shows 未定价 — the
    /// same as it did while masquerading as unknown-model, just named.
    static let managedRoutingModelID = "省心托管"

    private static func normalizedModelID(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown-model" : trimmed
    }

    private static func providerSnapshot(
        for session: AgentUsageSessionSnapshot,
        modelID: String
    ) -> (id: String, name: String) {
        if let providerID = session.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return (
                providerID,
                AgentProviderPreset.normalizedDisplayName(
                    providerID: providerID,
                    storedDisplayName: session.providerDisplayName
                ) ?? providerID
            )
        }

        let inferred = inferProviderID(from: modelID)
        return (inferred, AgentProviderPreset.preset(id: inferred)?.displayName ?? inferred)
    }

    private static func usageIdentity(
        for message: AgentUsageMessageSnapshot,
        session: AgentUsageSessionSnapshot
    ) -> (provider: (id: String, name: String), modelID: String, isDelegatedExternal: Bool) {
        if message.origin == .delegatedExternal {
            let label = message.originLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = label?.isEmpty == false ? label! : "External CLI"
            return (("delegated-external", "Delegated CLI"), model, true)
        }
        // 省心托管:从用户视角"省心托管"本身就是一个模型,聚成一行,而不是
        // 掉进 unknown-model。只认托管标记,老会话的空 modelID 仍归 unknown。
        if session.isManagedRouting {
            return (providerSnapshot(for: session, modelID: Self.managedRoutingModelID), Self.managedRoutingModelID, false)
        }
        let modelID = normalizedModelID(session.modelID)
        return (providerSnapshot(for: session, modelID: modelID), modelID, false)
    }

    private static func inferProviderID(from modelID: String) -> String {
        let id = modelID.lowercased()
        if id.contains("deepseek") { return AgentProviderPreset.deepSeekID }
        if id.contains("claude") || id.contains("anthropic") { return "claude" }
        if id.contains("gemini") { return "gemini" }
        if id.contains("qwen") || id.contains("qwq") { return "dashscope" }
        if id.contains("kimi") { return "kimi" }
        if id.contains("moonshot") { return "moonshot" }
        if id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            return AgentProviderPreset.openAIID
        }
        return AgentProviderPreset.customID
    }

    private static func usageBreakdown(for message: AgentUsageMessageSnapshot) -> (
        prompt: Int,
        completion: Int,
        cachedPrompt: Int,
        cacheWritePrompt: Int,
        reasoning: Int,
        total: Int,
        estimated: Int,
        isEstimated: Bool
    ) {
        let cached = max(0, message.cachedPromptTokens ?? 0)
        let cacheWrite = max(0, message.cacheWritePromptTokens ?? 0)
        let reasoning = max(0, message.reasoningTokens ?? 0)

        if let prompt = message.promptTokens,
           let completion = message.completionTokens {
            let total = message.usageTokens ?? (prompt + completion)
            return (prompt, completion, cached, cacheWrite, reasoning, max(total, prompt + completion), 0, false)
        }

        if let total = message.usageTokens, total > 0 {
            let completionEstimate = max(
                1,
                message.contentCharacterCount / 4 + message.reasoningCharacterCount / 4
            )
            let completion = min(total, completionEstimate)
            return (max(0, total - completion), completion, cached, cacheWrite, reasoning, total, total, true)
        }

        let estimated = estimateTokens(for: message)
        return (0, estimated, cached, cacheWrite, reasoning, estimated, estimated, true)
    }

    private static func estimatedCostUSD(for row: AgentModelUsageRow) -> Double? {
        guard !row.isDelegatedExternal else { return nil }
        guard let price = AgentModelPricing.price(providerID: row.providerID, modelID: row.modelID) else {
            return nil
        }
        let cached = min(row.cachedPromptTokens, row.promptTokens)
        let uncachedPrompt = max(0, row.promptTokens - cached)
        let inputCost = Double(uncachedPrompt) * price.inputPerMillion / 1_000_000.0
        let cachedCost = Double(cached) * (price.cachedInputPerMillion ?? price.inputPerMillion) / 1_000_000.0
        let cacheWriteCost = Double(row.cacheWritePromptTokens) * (price.cacheWritePerMillion ?? price.inputPerMillion) / 1_000_000.0
        let outputCost = Double(row.completionTokens) * price.outputPerMillion / 1_000_000.0
        return inputCost + cachedCost + cacheWriteCost + outputCost
    }

    private static func computeStreaks(
        uniqueDays: Set<Date>,
        now: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        guard !uniqueDays.isEmpty else { return (0, 0) }

        let sortedDays = uniqueDays.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sortedDays.count {
            let prev = sortedDays[index - 1]
            let curr = sortedDays[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: prev), next == curr {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        // If today has not started yet, keep the streak ending
        // yesterday visible instead of dropping the dashboard to 0.
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let currentAnchor: Date
        if uniqueDays.contains(today) {
            currentAnchor = today
        } else if let yesterday, uniqueDays.contains(yesterday) {
            currentAnchor = yesterday
        } else {
            return (0, longest)
        }

        var current = 0
        var cursor = currentAnchor
        while uniqueDays.contains(cursor) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        return (current, longest)
    }
}

private struct AgentModelPrice {
    let providerIDs: Set<String>
    let modelHints: [String]
    let inputPerMillion: Double
    let cachedInputPerMillion: Double?
    let cacheWritePerMillion: Double?
    let outputPerMillion: Double
}

private enum AgentModelPricing {
    static func price(providerID: String, modelID: String) -> AgentModelPrice? {
        let providerCandidates = providerCandidates(providerID: providerID, modelID: modelID)
        let model = modelID.lowercased()

        for provider in providerCandidates {
            if let match = prices.first(where: { price in
                price.providerIDs.contains(provider)
                    && price.modelHints.contains { model.contains($0) }
            }) {
                return match
            }
        }
        return nil
    }

    private static func providerCandidates(providerID: String, modelID: String) -> [String] {
        var candidates = OrderedStringSet()
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        candidates.append(provider)
        candidates.append(contentsOf: providerAliases[provider] ?? [])

        let model = modelID.lowercased()
        if model.contains("deepseek") {
            candidates.append(AgentProviderPreset.deepSeekID)
        }
        if model.contains("qwen") || model.contains("qwq") {
            candidates.append("dashscope")
        }
        if model.contains("claude") || model.contains("anthropic") {
            candidates.append("claude")
        }
        if model.contains("gemini") {
            candidates.append("gemini")
        }
        if model.contains("kimi") {
            candidates.append("kimi")
        }
        if model.contains("moonshot") {
            candidates.append("moonshot")
        }
        if model.contains("glm-") || model.contains("chatglm") {
            candidates.append("zhipu")
            candidates.append("bigmodel")
        }
        if model.hasPrefix("gpt-") || model.contains("/gpt-") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            candidates.append(AgentProviderPreset.openAIID)
            candidates.append("openai-responses")
        }
        return candidates.values.filter { !$0.isEmpty }
    }

    private static let providerAliases: [String: [String]] = [
        "openai-chat": [AgentProviderPreset.openAIID],
        "openai-compatible": [AgentProviderPreset.openAIID],
        "openai-responses": [AgentProviderPreset.openAIID],
        "custom": [AgentProviderPreset.openAIID, "dashscope", AgentProviderPreset.deepSeekID, "claude", "gemini", "kimi", "moonshot", "zhipu", "bigmodel"],
        "dashscope-intl": ["dashscope"],
        "aliyun": ["dashscope"],
        "alibaba": ["dashscope"],
        "qwen": ["dashscope"],
        "deepseek-ai": [AgentProviderPreset.deepSeekID],
        "anthropic": ["claude"],
        "google": ["gemini"],
        "moonshot-ai": ["kimi", "moonshot"],
        "z.ai": ["zhipu", "bigmodel"],
        "zai": ["zhipu", "bigmodel"],
        "zhipuai": ["zhipu", "bigmodel"],
        "chatglm": ["zhipu", "bigmodel"],
        "glm": ["zhipu", "bigmodel"]
    ]

    private static func cny(_ yuanPerMillion: Double) -> Double {
        yuanPerMillion / 7.2
    }

    // Built-in public price cache. Prices are USD per 1M tokens unless noted
    // by the provider's public API pricing page. Keep model-specific rows
    // before broader family rows so substring matching stays deterministic.
    private static let prices: [AgentModelPrice] = [
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.5-pro"], inputPerMillion: 30.0, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 180.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.5"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: nil, outputPerMillion: 30.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.4-mini"], inputPerMillion: 0.75, cachedInputPerMillion: 0.075, cacheWritePerMillion: nil, outputPerMillion: 4.5),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.4"], inputPerMillion: 2.5, cachedInputPerMillion: 0.25, cacheWritePerMillion: nil, outputPerMillion: 15.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5-mini"], inputPerMillion: 0.25, cachedInputPerMillion: 0.025, cacheWritePerMillion: nil, outputPerMillion: 2.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5-nano"], inputPerMillion: 0.05, cachedInputPerMillion: 0.005, cacheWritePerMillion: nil, outputPerMillion: 0.4),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5-codex", "gpt-5"], inputPerMillion: 1.25, cachedInputPerMillion: 0.125, cacheWritePerMillion: nil, outputPerMillion: 10.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4.1-mini"], inputPerMillion: 0.40, cachedInputPerMillion: 0.10, cacheWritePerMillion: nil, outputPerMillion: 1.60),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4.1-nano"], inputPerMillion: 0.10, cachedInputPerMillion: 0.025, cacheWritePerMillion: nil, outputPerMillion: 0.40),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4.1"], inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: nil, outputPerMillion: 8.00),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4o-mini"], inputPerMillion: 0.15, cachedInputPerMillion: 0.075, cacheWritePerMillion: nil, outputPerMillion: 0.60),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4o"], inputPerMillion: 2.50, cachedInputPerMillion: 1.25, cacheWritePerMillion: nil, outputPerMillion: 10.00),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["o4-mini"], inputPerMillion: 1.10, cachedInputPerMillion: 0.275, cacheWritePerMillion: nil, outputPerMillion: 4.40),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["o3-mini"], inputPerMillion: 1.10, cachedInputPerMillion: 0.55, cacheWritePerMillion: nil, outputPerMillion: 4.40),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["o3"], inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: nil, outputPerMillion: 8.00),

        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-fable-5", "claude-mythos-5"], inputPerMillion: 10.0, cachedInputPerMillion: 1.0, cacheWritePerMillion: 12.5, outputPerMillion: 50.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-opus-4.8", "claude-opus-4.7", "claude-opus-4.6", "claude-opus-4.5"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 25.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-opus-4.1", "claude-opus-4"], inputPerMillion: 15.0, cachedInputPerMillion: 1.5, cacheWritePerMillion: 18.75, outputPerMillion: 75.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-sonnet-4.6", "claude-sonnet-4.5", "claude-sonnet-4"], inputPerMillion: 3.0, cachedInputPerMillion: 0.3, cacheWritePerMillion: 3.75, outputPerMillion: 15.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-haiku-4.5"], inputPerMillion: 1.0, cachedInputPerMillion: 0.1, cacheWritePerMillion: 1.25, outputPerMillion: 5.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-3-5-haiku", "claude-haiku-3.5"], inputPerMillion: 0.8, cachedInputPerMillion: 0.08, cacheWritePerMillion: 1.0, outputPerMillion: 4.0),

        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-3"], inputPerMillion: 2.0, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 12.0),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.5-pro"], inputPerMillion: 1.25, cachedInputPerMillion: 0.125, cacheWritePerMillion: nil, outputPerMillion: 10.0),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.5-flash-lite"], inputPerMillion: 0.10, cachedInputPerMillion: 0.01, cacheWritePerMillion: nil, outputPerMillion: 0.40),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.5-flash"], inputPerMillion: 0.30, cachedInputPerMillion: 0.03, cacheWritePerMillion: nil, outputPerMillion: 2.50),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.0-flash-lite"], inputPerMillion: 0.10, cachedInputPerMillion: 0.025, cacheWritePerMillion: nil, outputPerMillion: 0.40),

        AgentModelPrice(providerIDs: ["deepseek"], modelHints: ["deepseek-v4-pro"], inputPerMillion: 0.435, cachedInputPerMillion: 0.003625, cacheWritePerMillion: nil, outputPerMillion: 0.87),
        AgentModelPrice(providerIDs: ["deepseek"], modelHints: ["deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"], inputPerMillion: 0.14, cachedInputPerMillion: 0.0028, cacheWritePerMillion: nil, outputPerMillion: 0.28),

        // qwen3.7-max/plus — official 阿里云百炼 (DashScope) list price 原价,
        // 元/百万 token, from the console pricing card (2026-06). cny() → USD.
        // Max is a flat rate; Plus is tiered by input length — we store the
        // ≤256K tier (the 256K–1M tier costs more). Limited-time 5折/8折
        // promos are intentionally NOT baked in (we track list price).
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3.7-max"], inputPerMillion: cny(12.0), cachedInputPerMillion: cny(2.4), cacheWritePerMillion: cny(15.0), outputPerMillion: cny(36.0)),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3.7-plus"], inputPerMillion: cny(2.0), cachedInputPerMillion: cny(0.4), cacheWritePerMillion: cny(2.5), outputPerMillion: cny(8.0)),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3-vl-plus", "qwen-vl-plus"], inputPerMillion: 0.11, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.28),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-max", "qwen3-max"], inputPerMillion: 0.28, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 1.11),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-plus", "qwen3-plus", "qwen2.5-plus"], inputPerMillion: 0.11, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.28),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-turbo"], inputPerMillion: 0.042, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.083),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-long"], inputPerMillion: 0.042, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.083),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwq"], inputPerMillion: 0.22, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.88),

        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.7-code-highspeed"], inputPerMillion: cny(13.0), cachedInputPerMillion: cny(2.6), cacheWritePerMillion: nil, outputPerMillion: cny(54.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.7-code"], inputPerMillion: cny(6.5), cachedInputPerMillion: cny(1.3), cacheWritePerMillion: nil, outputPerMillion: cny(27.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.6"], inputPerMillion: cny(6.5), cachedInputPerMillion: cny(1.1), cacheWritePerMillion: nil, outputPerMillion: cny(27.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.5"], inputPerMillion: cny(4.0), cachedInputPerMillion: cny(0.7), cacheWritePerMillion: nil, outputPerMillion: cny(21.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-128k"], inputPerMillion: cny(10.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(30.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-32k"], inputPerMillion: cny(5.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(20.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-8k"], inputPerMillion: cny(2.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(10.0)),

        // GLM-5 has two platform prices. Via 阿里云百炼 (DashScope) it is the
        // official CNY list price 原价 (元/百万 token, ≤32K tier, from the
        // console pricing card 2026-06); this dashscope-scoped row matches
        // bailian users first. Via z.ai international it is USD/M (rows below,
        // zhipu/bigmodel-scoped). glm-5.2/5.1 before glm-5 so the substring
        // match hits the specific id first.
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["glm-5"], inputPerMillion: cny(4.0), cachedInputPerMillion: cny(0.8), cacheWritePerMillion: nil, outputPerMillion: cny(18.0)),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-5.2"], inputPerMillion: 1.4, cachedInputPerMillion: 0.26, cacheWritePerMillion: nil, outputPerMillion: 4.4),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-5.1"], inputPerMillion: 1.4, cachedInputPerMillion: 0.26, cacheWritePerMillion: nil, outputPerMillion: 4.4),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-5"], inputPerMillion: 1.0, cachedInputPerMillion: 0.2, cacheWritePerMillion: nil, outputPerMillion: 3.2),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-4.5"], inputPerMillion: cny(0.8), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(2.0))
    ]
}

private struct OrderedStringSet {
    private(set) var values: [String] = []

    mutating func append(_ value: String) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }

    mutating func append(contentsOf newValues: [String]) {
        for value in newValues {
            append(value)
        }
    }
}
