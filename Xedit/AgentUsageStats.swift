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

/// One cell of the GitHub-style heatmap: a calendar day, its model-call count
/// and Token usage, split by source.
///
/// "Request" means one model call (docs/USAGE_LEDGER_DESIGN.md §6.4), the
/// same unit the request pages and the CLI ledger use. It used to count user
/// messages, so a turn that ran past midnight showed "0 requests" with tokens
/// on the next day.
struct AgentHeatmapCell: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let requestCount: Int
    let tokenCount: Int
    var desktopRequestCount = 0
    var cliRequestCount = 0
    var desktopTokenCount = 0
    var cliTokenCount = 0
    /// Share of measured input tokens served from the provider's prompt cache,
    /// nil when no call that day reported both numbers.
    var cacheHitRate: Double? = nil
    /// User-started turns (desktop user messages). Secondary: tooltip only.
    var turnCount = 0
}

/// One calendar day's usage, shared by the monthly usage calendar and tests.
/// A nil cost means at least one assistant turn used a model without a known
/// public price; callers must not present a misleading partial total.
nonisolated struct AgentDailyUsage: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let tokenCount: Int
    let estimatedCostUSD: Double?
    let sessionCount: Int
}

nonisolated struct AgentDailyUsageDetail: Equatable {
    let date: Date
    let overview: AgentUsageOverview
    let modelUsage: [AgentModelUsageRow]
    let capabilityUsage: [AgentCapabilityUsageRow]
    let cacheHitRate: Double
    let maximumContextTokens: Int
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
    /// Which clients called this model (desktop sessions, CLI ledger).
    var sources: Set<AgentUsageSource> = [.desktop]

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

/// Historical `spawn_agent` usage grouped by the selected worker profile.
/// One invocation is one parent-model tool call, including calls that later
/// failed validation or execution; `sessionCount` shows how broadly the
/// worker was used without inflating repeated fan-out in one conversation.
nonisolated struct AgentSubagentUsageRow: Identifiable, Equatable {
    let profileID: String
    /// Requested by either the parent model or the host dispatcher.
    let invocationCount: Int
    /// Child loops that actually started. A rejected/denied proposal remains
    /// a request but is not presented as model work performed.
    let runCount: Int
    let sessionCount: Int

    var id: String { profileID }
}

/// The three Phase 0 KPIs from `docs/SMALL_MODEL_SKILL_WORKERS_DESIGN.md` §8,
/// derived entirely from persisted worker runs.
///
/// Every rate is optional and nil means "no data yet", never zero. A panel
/// that renders 0% for an empty denominator reads as "we tried and failed",
/// which is the one thing these numbers must not say by accident.
nonisolated struct AgentSkillWorkerKPIs: Equatable {
    /// Runs on a narrow trade — every trade except `deep`, which inherits the
    /// parent's model and so moves no work off the expensive tier.
    var narrowRunCount: Int = 0
    var deepRunCount: Int = 0
    /// Parent assistant turns, i.e. work the main model did inline.
    var parentTurnCount: Int = 0
    /// Runs that actually had a verifier. Runs without one are excluded from
    /// the success rate rather than counted as failures.
    var verifiedRunCount: Int = 0
    var verifiedPassCount: Int = 0
    var escalatedRunCount: Int = 0
    /// Citations spot-checked across report-only runs, and how many resolved.
    /// Trades without a verifier can never move the success rate, so this is
    /// the only number that says anything about their answers.
    var citationsChecked: Int = 0
    var citationsResolved: Int = 0
    /// Operator turns for which the deterministic router selected a worker,
    /// and how many of those turns saw at least one child loop actually start.
    var eligibleUserTurnCount: Int = 0
    var workerHandledUserTurnCount: Int = 0
    /// Automatic bounded coding attempts and their delivery quality. These
    /// are separate from verifier success: a green test can still fail an
    /// independent review and require the parent to repair it.
    var automaticCodingRunCount: Int = 0
    var straightThroughDeliveryCount: Int = 0
    var parentRepairCodingRunCount: Int = 0
    var codingPlanCacheHitCount: Int = 0

    /// Share of model invocations a narrow trade handled. Runs and parent
    /// turns are different units on purpose: the question is "how much of
    /// what the model was asked to do went somewhere cheaper", and both a
    /// child loop and an inline turn are one such ask.
    var skillCoverage: Double? {
        let total = narrowRunCount + deepRunCount + parentTurnCount
        guard total > 0 else { return nil }
        return Double(narrowRunCount) / Double(total)
    }

    var workerCoverage: Double? {
        guard eligibleUserTurnCount > 0 else { return nil }
        return Double(workerHandledUserTurnCount) / Double(eligibleUserTurnCount)
    }

    /// Share of child runs that spent the scarce 1M tier. Target ≤ 5%.
    ///
    /// Denominator is child runs only — deliberately *not* the same one
    /// `skillCoverage` uses. That metric asks "how much of the work went
    /// somewhere cheaper", so parent turns belong in it. This one asks "of
    /// the work that was delegated, how much needed the expensive tier",
    /// where a parent turn is not a candidate at all and would only dilute
    /// the number into always looking fine.
    ///
    /// Same denominator as willdeep-rs `agent-metrics deep_share`
    /// (deep children / all children), so the two clients are comparable.
    var deepShare: Double? {
        let total = narrowRunCount + deepRunCount
        guard total > 0 else { return nil }
        return Double(deepRunCount) / Double(total)
    }

    var verifiedSuccessRate: Double? {
        guard verifiedRunCount > 0 else { return nil }
        return Double(verifiedPassCount) / Double(verifiedRunCount)
    }

    var escalationRate: Double? {
        guard narrowRunCount > 0 else { return nil }
        return Double(escalatedRunCount) / Double(narrowRunCount)
    }

    var straightThroughRate: Double? {
        guard automaticCodingRunCount > 0 else { return nil }
        return Double(straightThroughDeliveryCount) / Double(automaticCodingRunCount)
    }

    var codingReworkRate: Double? {
        guard automaticCodingRunCount > 0 else { return nil }
        return Double(parentRepairCodingRunCount) / Double(automaticCodingRunCount)
    }

    /// Share of cited locations that actually exist. Nil when nothing was
    /// checked — "no citations yet" and "every citation was wrong" must not
    /// render as the same thing.
    ///
    /// It measures grounding, not correctness: a report can cite ten real
    /// files and still answer the wrong question.
    var citationAccuracy: Double? {
        guard citationsChecked > 0 else { return nil }
        return Double(citationsResolved) / Double(citationsChecked)
    }
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

/// Codable so `AgentSessionStore` can persist the snapshot into the
/// `usage-v1` sidecar. Synthesized keys are part of the sidecar contract:
/// adding a non-optional field without bumping the sidecar schema version
/// makes old sidecars fail decoding (safe: they rebuild); an optional
/// field decodes as nil from old sidecars and stays stale until the source
/// signature changes — bump `UsageCatalogEntry.currentSchemaVersion` when
/// the dashboard must see the new field immediately.
nonisolated struct AgentUsageSessionSnapshot: Identifiable, Equatable, Codable {
    let id: UUID
    var modelID: String?
    var providerID: String?
    var providerDisplayName: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [AgentUsageMessageSnapshot]
    var hostWorkerRuns: [AgentHostWorkerRunRecord]?
    /// Runs the coordinator started without a `spawn_agent` tool call.
    /// See `AgentSession.coordinatorWorkerRuns`.
    var coordinatorWorkerRuns: [AgentSubagentRunUsage]?
    var auxiliaryModelRequests: [AgentAuxiliaryModelRequestRecord]
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
        hostWorkerRuns: [AgentHostWorkerRunRecord]? = nil,
        coordinatorWorkerRuns: [AgentSubagentRunUsage]? = nil,
        auxiliaryModelRequests: [AgentAuxiliaryModelRequestRecord] = [],
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
        self.hostWorkerRuns = hostWorkerRuns
        self.coordinatorWorkerRuns = coordinatorWorkerRuns
        self.auxiliaryModelRequests = auxiliaryModelRequests
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
            hostWorkerRuns: session.hostWorkerRuns,
            coordinatorWorkerRuns: session.coordinatorWorkerRuns,
            auxiliaryModelRequests: session.auxiliaryModelRequests,
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

nonisolated struct AgentUsageMessageSnapshot: Equatable, Codable {
    var id: UUID?
    var role: AgentRole
    var isOperatorInput: Bool?
    /// Profile selected from the operator's raw request when the usage sidecar
    /// was built. The raw text is not duplicated into analytics.
    var workerRouteProfileID: String?
    var contentCharacterCount: Int
    var reasoningCharacterCount: Int
    var imageCount: Int
    var toolCallArgumentCharacterCount: Int
    var toolCallNames: [String]
    var toolCallExternalIDs: [String]
    /// Normalized profile ids for `spawn_agent` calls on this message.
    /// Missing/unknown profile arguments resolve to `deep`, matching the
    /// runtime's backwards-compatible execution rule.
    var subagentProfileIDs: [String]
    /// What the `spawn_agent` runs on this message actually cost and whether
    /// they verified. Empty while a run is still going, and for every session
    /// recorded before worker accounting existed — those keep reporting only
    /// the parent's tokens, which is honest: we never had the child's.
    var subagentRuns: [AgentSubagentRunUsage]
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
    var requestModelID: String?
    var requestProviderID: String?
    var requestProviderDisplayName: String?
    var requestStablePrefixCharacters: Int?
    var elapsedSeconds: Double?
    var firstResponseSeconds: Double?
    var requestIsLocal: Bool?
    var createdAt: Date

    init(
        id: UUID? = nil,
        role: AgentRole,
        isOperatorInput: Bool? = nil,
        workerRouteProfileID: String? = nil,
        contentCharacterCount: Int,
        reasoningCharacterCount: Int = 0,
        imageCount: Int = 0,
        toolCallArgumentCharacterCount: Int = 0,
        toolCallNames: [String] = [],
        toolCallExternalIDs: [String] = [],
        subagentProfileIDs: [String] = [],
        subagentRuns: [AgentSubagentRunUsage] = [],
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
        requestModelID: String? = nil,
        requestProviderID: String? = nil,
        requestProviderDisplayName: String? = nil,
        requestStablePrefixCharacters: Int? = nil,
        elapsedSeconds: Double? = nil,
        firstResponseSeconds: Double? = nil,
        requestIsLocal: Bool? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.isOperatorInput = isOperatorInput
        self.workerRouteProfileID = workerRouteProfileID
        self.contentCharacterCount = contentCharacterCount
        self.reasoningCharacterCount = reasoningCharacterCount
        self.imageCount = imageCount
        self.toolCallArgumentCharacterCount = toolCallArgumentCharacterCount
        self.toolCallNames = toolCallNames
        self.toolCallExternalIDs = toolCallExternalIDs
        self.subagentProfileIDs = subagentProfileIDs
        self.subagentRuns = subagentRuns
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
        self.requestModelID = requestModelID
        self.requestProviderID = requestProviderID
        self.requestProviderDisplayName = requestProviderDisplayName
        self.requestStablePrefixCharacters = requestStablePrefixCharacters
        self.elapsedSeconds = elapsedSeconds
        self.firstResponseSeconds = firstResponseSeconds
        self.requestIsLocal = requestIsLocal
        self.createdAt = createdAt
    }

    init(message: AgentMessage) {
        self.init(
            id: message.id,
            role: message.role,
            isOperatorInput: message.isOperatorInput,
            workerRouteProfileID: message.isOperatorInput
                && message.delegationPolicy != .forbidden
                ? AgentRequestRouter.classify(message.content).profileID
                : nil,
            contentCharacterCount: message.modelContent.count,
            reasoningCharacterCount: message.reasoningContent?.count ?? 0,
            imageCount: message.images.count,
            toolCallArgumentCharacterCount: message.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count },
            toolCallNames: message.toolCalls.map(\.toolName),
            toolCallExternalIDs: message.toolCalls.map(\.externalID),
            subagentProfileIDs: message.toolCalls.compactMap {
                Self.subagentProfileID(
                    toolName: $0.toolName,
                    argumentsJSON: $0.argumentsJSON
                )
            },
            subagentRuns: message.toolCalls.compactMap(\.subagentUsage),
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
            requestModelID: message.requestModelID ?? message.managedRoute?.selectedModel,
            requestProviderID: message.requestProviderID,
            requestProviderDisplayName: message.requestProviderDisplayName,
            requestStablePrefixCharacters: message.requestStablePrefixCharacters,
            elapsedSeconds: message.elapsedSeconds,
            firstResponseSeconds: message.firstResponseSeconds,
            requestIsLocal: message.requestIsLocal,
            createdAt: message.createdAt
        )
    }

    static func subagentProfileID(toolName: String, argumentsJSON: String) -> String? {
        guard toolName == "spawn_agent" else { return nil }
        let rawProfile: String?
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawProfile = object["profile"] as? String
        } else {
            rawProfile = nil
        }
        return AgentSubagentProfileCatalog.profile(id: rawProfile).id
    }
}

/// Every aggregate the stats dashboard renders, bundled so the whole
/// computation runs once per snapshot revision instead of once per SwiftUI
/// body evaluation. All fields derive purely from the snapshot array plus
/// `now` (streaks and the heatmap are anchored to the local calendar day),
/// so `AppState` caches an instance keyed by (snapshot revision, day).
nonisolated struct AgentUsageDashboardModel: Equatable {
    let overview: AgentUsageOverview
    let modelUsage: [AgentModelUsageRow]
    let capabilityUsage: [AgentCapabilityUsageRow]
    let subagentUsage: [AgentSubagentUsageRow]
    let subagentSessionCount: Int
    let skillWorkerKPIs: AgentSkillWorkerKPIs
    let heatmapCells: [[AgentHeatmapCell]]
    let peakTaskTokenCount: Int
    let managedRoutingRate: Double
    let reasoningUsageRate: Double
    let uniqueToolCount: Int
    let requestAnalytics: AgentRequestAnalyticsSnapshot

    /// What the panel shows before the first aggregation lands. Built from
    /// no sessions at all, so every tile reads zero and the heatmap keeps
    /// its full width — the grid must not resize when the real numbers
    /// arrive a frame later.
    static let empty = AgentUsageStats.dashboardModel(
        for: [],
        heatmapWeekCount: AgentStatsDashboardLayout.maximumHeatmapWeeks,
        now: Date()
    )
}

/// Pure aggregation over persisted usage snapshots. Nothing in here touches
/// UI state, so it is `nonisolated` — and it has to be: the module defaults
/// to MainActor isolation, which silently pinned this whole fold to the main
/// thread. On a year-old install that is ~28k messages across ~300 sessions
/// walked on the thread that draws, which is what the stats panel's entry
/// stutter turned out to be.
nonisolated enum AgentUsageStats {
    /// Gather every dashboard aggregate in one call so callers can memoize
    /// the result. Pure function like the individual helpers it wraps.
    static func dashboardModel(
        for sessions: [AgentUsageSessionSnapshot],
        cliRecords: [AgentCLIUsageRecord] = [],
        heatmapWeekCount: Int = 12,
        now: Date = Date()
    ) -> AgentUsageDashboardModel {
        // One pass over the messages in place. This used to build
        // `sessions.flatMap(\.messages)` — a full copy of every message of
        // every session — and then filter it again for the assistant subset.
        // At ~28k messages that is two large allocations for three counters.
        var peakTaskTokenCount = 0
        var assistantCount = 0
        var reasonedCount = 0
        var toolNames: Set<String> = []
        for session in sessions {
            var sessionTokens = 0
            for message in session.messages {
                sessionTokens += displayTokenCount(for: message)
                if message.role == .assistant, message.origin != .hostGenerated {
                    assistantCount += 1
                    if (message.reasoningTokens ?? 0) > 0 || message.reasoningCharacterCount > 0 {
                        reasonedCount += 1
                    }
                }
                toolNames.formUnion(message.toolCallNames)
            }
            peakTaskTokenCount = max(peakTaskTokenCount, sessionTokens)
        }
        var cliSessionTokens: [String: Int] = [:]
        for record in cliRecords {
            cliSessionTokens[record.sessionID ?? record.id.uuidString, default: 0] += record.countedTokens
        }
        peakTaskTokenCount = max(peakTaskTokenCount, cliSessionTokens.values.max() ?? 0)

        let managedRoutingRate: Double
        if sessions.isEmpty {
            managedRoutingRate = 0
        } else {
            let managed = sessions.count(where: \.isManagedRouting)
            managedRoutingRate = Double(managed) / Double(sessions.count)
        }

        let reasoningUsageRate = assistantCount == 0
            ? 0
            : Double(reasonedCount) / Double(assistantCount)

        return AgentUsageDashboardModel(
            overview: overview(for: sessions, cliRecords: cliRecords, now: now),
            modelUsage: modelUsage(for: sessions, cliRecords: cliRecords),
            capabilityUsage: capabilityUsage(for: sessions),
            subagentUsage: subagentUsage(for: sessions),
            subagentSessionCount: sessions.count { session in
                session.messages.contains { !$0.subagentProfileIDs.isEmpty }
                    || !(session.hostWorkerRuns ?? []).isEmpty
                    || !(session.coordinatorWorkerRuns ?? []).isEmpty
            },
            skillWorkerKPIs: skillWorkerKPIs(for: sessions),
            heatmapCells: heatmap(for: sessions, cliRecords: cliRecords, weekCount: heatmapWeekCount, now: now),
            peakTaskTokenCount: peakTaskTokenCount,
            managedRoutingRate: managedRoutingRate,
            reasoningUsageRate: reasoningUsageRate,
            uniqueToolCount: toolNames.count,
            requestAnalytics: AgentRequestAnalytics.snapshot(for: sessions, cliRecords: cliRecords, now: now)
        )
    }

    /// Token formula behind the "peak task" metric: real usage when the
    /// provider reported it, otherwise chars/4 + 256 per image with a floor
    /// of 1. Kept separate from `estimateTokens` (600 per image, no floor)
    /// so the metric strip matches its historical rendering exactly.
    private static func displayTokenCount(for message: AgentUsageMessageSnapshot) -> Int {
        if let usage = message.usageTokens, usage > 0 {
            return usage
        }
        let textCharacters = message.contentCharacterCount
            + message.reasoningCharacterCount
            + message.toolCallArgumentCharacterCount
        return max(1, textCharacters / 4 + message.imageCount * 256)
    }

    /// Build an overview snapshot for the given sessions. Pure function
    /// — same input always produces the same output, no side effects.
    static func overview(for sessions: [AgentSession], now: Date = Date()) -> AgentUsageOverview {
        overview(for: sessions.map { AgentUsageSessionSnapshot(session: $0) }, now: now)
    }

    static func overview(
        for sessions: [AgentUsageSessionSnapshot],
        cliRecords: [AgentCLIUsageRecord] = [],
        allTimeStreakSessions: [AgentUsageSessionSnapshot]? = nil,
        now: Date = Date()
    ) -> AgentUsageOverview {
        let allMessages = sessions.flatMap(\.messages)
        let messageCount = allMessages.count
        // Only conversations that actually happened. A session row exists on
        // disk from the moment a chat is opened, so a plain `sessions.count`
        // also counts every "新对话" placeholder the user never typed into —
        // on a long-lived install that inflated the dashboard's session tile
        // by more than 2×. `monthlySessionCount` in the calendar view has
        // always counted this way; this brings the all-time tile in line.
        let sessionCount = sessions.count { !$0.messages.isEmpty }
            + Set(cliRecords.map { $0.sessionID ?? $0.id.uuidString }).count
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
        for record in cliRecords {
            let tokens = record.countedTokens
            totalTokens += tokens
            hasAnyRealUsage = hasAnyRealUsage || tokens > 0
        }

        let calendar = Calendar.current
        let cliDayKeys = cliRecords.map { calendar.startOfDay(for: $0.timestamp) }
        let dayKeys: [Date] = allMessages.map { calendar.startOfDay(for: $0.createdAt) } + cliDayKeys
        let uniqueDays = Set(dayKeys)
        let activeDays = uniqueDays.count

        let streakMessages = (allTimeStreakSessions ?? sessions).flatMap(\.messages)
        let streakDays = Set(streakMessages.map { calendar.startOfDay(for: $0.createdAt) } + cliDayKeys)
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
        for record in cliRecords {
            hourCounts[calendar.component(.hour, from: record.timestamp), default: 0] += 1
        }
        let peakHour = hourCounts.max { $0.value < $1.value }?.key

        // 按每一次模型调用实际用的模型计，而不是会话默认模型 × 消息数：
        // 省心托管和中途切模型的会话以前全算在会话默认模型头上。
        var modelCounts: [String: Int] = [:]
        for event in AgentRequestAnalytics.requestEvents(for: sessions, cliRecords: cliRecords)
        where event.modelID != "unknown-model" {
            modelCounts[event.modelID, default: 0] += event.requestCount
        }
        if modelCounts.isEmpty {
            // 早期会话的消息没有逐次请求记录，退回按会话模型计。
            for session in sessions {
                guard let model = session.modelID, !model.isEmpty else { continue }
                modelCounts[model, default: 0] += session.messages.count
            }
        }
        let favoriteModel = modelCounts.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }?.key

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
    /// each (Mon..Sun) in the user's local timezone. Each day counts model
    /// calls ("requests", docs/USAGE_LEDGER_DESIGN.md §6.4) and Token usage,
    /// desktop and CLI separately. Desktop tokens are real-or-estimated per
    /// transcript message plus worker and auxiliary calls; CLI tokens are
    /// exactly what the ledger reports. Returned in column-major order
    /// (oldest column first); the caller renders left → right.
    static func heatmap(
        for sessions: [AgentSession],
        weekCount: Int = 12,
        now: Date = Date()
    ) -> [[AgentHeatmapCell]] {
        heatmap(for: sessions.map { AgentUsageSessionSnapshot(session: $0) }, weekCount: weekCount, now: now)
    }

    static func heatmap(
        for sessions: [AgentUsageSessionSnapshot],
        cliRecords: [AgentCLIUsageRecord] = [],
        weekCount: Int = 12,
        now: Date = Date()
    ) -> [[AgentHeatmapCell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let earliestStart = calendar.date(byAdding: .day, value: -(weekCount * 7 - 1), to: today) else {
            return []
        }

        struct DayTotals {
            var desktopRequests = 0
            var cliRequests = 0
            var desktopTokens = 0
            var cliTokens = 0
            var cachedInput = 0
            var measuredInput = 0
            var turns = 0
        }
        var days: [Date: DayTotals] = [:]

        for session in sessions {
            for message in session.messages {
                let day = calendar.startOfDay(for: message.createdAt)
                if day < earliestStart { continue }
                let tokenCount = message.usageTokens.flatMap { $0 > 0 ? $0 : nil }
                    ?? estimateTokens(for: message)
                days[day, default: DayTotals()].desktopTokens += tokenCount
                if message.role == .user {
                    days[day, default: DayTotals()].turns += 1
                }
            }
        }
        for event in AgentRequestAnalytics.requestEvents(for: sessions, cliRecords: cliRecords) {
            let day = calendar.startOfDay(for: event.createdAt)
            if day < earliestStart { continue }
            var totals = days[day, default: DayTotals()]
            switch event.source {
            case .desktop:
                totals.desktopRequests += event.requestCount
                totals.desktopTokens += event.additionalTokens
            case .cli:
                totals.cliRequests += event.requestCount
                totals.cliTokens += event.additionalTokens
            }
            if let prompt = event.promptTokens, prompt > 0, let cached = event.cachedPromptTokens {
                totals.measuredInput += prompt
                totals.cachedInput += min(max(0, cached), prompt)
            }
            days[day] = totals
        }

        var columns: [[AgentHeatmapCell]] = []
        for week in 0..<weekCount {
            var column: [AgentHeatmapCell] = []
            for day in 0..<7 {
                let offset = week * 7 + day
                guard let date = calendar.date(byAdding: .day, value: offset, to: earliestStart) else { continue }
                let totals = days[date] ?? DayTotals()
                column.append(AgentHeatmapCell(
                    date: date,
                    requestCount: totals.desktopRequests + totals.cliRequests,
                    tokenCount: totals.desktopTokens + totals.cliTokens,
                    desktopRequestCount: totals.desktopRequests,
                    cliRequestCount: totals.cliRequests,
                    desktopTokenCount: totals.desktopTokens,
                    cliTokenCount: totals.cliTokens,
                    cacheHitRate: totals.measuredInput > 0
                        ? Double(totals.cachedInput) / Double(totals.measuredInput)
                        : nil,
                    turnCount: totals.turns
                ))
            }
            columns.append(column)
        }
        return columns
    }


    /// Build every day in the requested local calendar month, including zero
    /// usage days so the presentation layer can render a stable month grid.
    static func dailyUsage(
        for sessions: [AgentUsageSessionSnapshot],
        cliRecords: [AgentCLIUsageRecord] = [],
        in month: Date,
        calendar sourceCalendar: Calendar = .current
    ) -> [AgentDailyUsage] {
        var calendar = sourceCalendar
        calendar.firstWeekday = 1
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else {
            return []
        }

        var tokenCountByDay: [Date: Int] = [:]
        var sessionIDsByDay: [Date: Set<String>] = [:]
        var costByDay: [Date: Double] = [:]

        for session in sessions {
            for message in session.messages where monthInterval.contains(message.createdAt) {
                let day = calendar.startOfDay(for: message.createdAt)
                let tokens = message.usageTokens.flatMap { $0 > 0 ? $0 : nil }
                    ?? estimateTokens(for: message)
                tokenCountByDay[day, default: 0] += tokens
                sessionIDsByDay[day, default: []].insert(session.id.uuidString)

                guard message.role == .assistant, message.origin != .hostGenerated else { continue }
                // Unpriced messages (no price row / delegated CLI) count as
                // free instead of vetoing the whole day's cost.
                if let cost = estimatedCostUSD(for: message, session: session) {
                    costByDay[day, default: 0] += cost
                }
            }
        }

        // 子 Worker 与辅助请求（标题、上下文压缩、图片描述、派发判断、输入
        // 联想）的 Token 不在 transcript 消息里，热力图一直把它们算进当天
        // 用量，日历却漏了——同一天点进去数字会凭空变小。2026-09-23 对齐：
        // 这里只取 `additionalTokens`，CLI 仍走下面的账本分支，避免重复计。
        for event in AgentRequestAnalytics.requestEvents(for: sessions)
        where event.additionalTokens > 0 && monthInterval.contains(event.createdAt) {
            tokenCountByDay[calendar.startOfDay(for: event.createdAt), default: 0] += event.additionalTokens
        }

        // CLI 账本：Token 取账本报的数，费用按同一张价目表算（未定价的记 0）。
        let cliByDay = Dictionary(grouping: cliRecords.filter { monthInterval.contains($0.timestamp) }) {
            calendar.startOfDay(for: $0.timestamp)
        }
        for (day, records) in cliByDay {
            tokenCountByDay[day, default: 0] += records.reduce(0) { $0 + $1.countedTokens }
            for record in records {
                sessionIDsByDay[day, default: []].insert("cli:" + (record.sessionID ?? record.id.uuidString))
            }
            costByDay[day, default: 0] += modelUsage(for: [], cliRecords: records)
                .reduce(0) { $0 + ($1.estimatedCostUSD ?? 0) }
        }

        return dayRange.compactMap { dayNumber in
            guard let date = calendar.date(
                byAdding: .day,
                value: dayNumber - 1,
                to: monthInterval.start
            ) else {
                return nil
            }
            let day = calendar.startOfDay(for: date)
            return AgentDailyUsage(
                date: day,
                tokenCount: tokenCountByDay[day] ?? 0,
                estimatedCostUSD: costByDay[day] ?? 0,
                sessionCount: sessionIDsByDay[day]?.count ?? 0
            )
        }
    }

    static func dailyDetail(
        for sessionSnapshots: [AgentUsageSessionSnapshot],
        cliRecords: [AgentCLIUsageRecord] = [],
        on day: Date,
        calendar sourceCalendar: Calendar = .current
    ) -> AgentDailyUsageDetail {
        let dailySessions = sessions(on: day, from: sessionSnapshots, calendar: sourceCalendar)
        let dayInterval = sourceCalendar.dateInterval(of: .day, for: day)
        let dailyRecords = cliRecords.filter { dayInterval?.contains($0.timestamp) == true }
        let rows = modelUsage(for: dailySessions, cliRecords: dailyRecords)
        let promptTokens = rows.reduce(0) { $0 + $1.promptTokens }
        let cachedPromptTokens = rows.reduce(0) { $0 + $1.cachedPromptTokens }
        let maximumContextTokens = dailySessions
            .flatMap(\.messages)
            .filter { $0.role == .assistant && $0.origin != .hostGenerated }
            .map { message in
                if let prompt = message.promptTokens {
                    return prompt + max(0, message.completionTokens ?? 0)
                }
                return max(0, message.usageTokens ?? 0)
            }
            .max() ?? 0
        let maximumCLIContextTokens = dailyRecords
            .map { max(0, $0.inputTokens ?? 0) + max(0, $0.outputTokens ?? 0) }
            .max() ?? 0

        return AgentDailyUsageDetail(
            date: sourceCalendar.startOfDay(for: day),
            overview: overview(for: dailySessions, cliRecords: dailyRecords, now: day),
            modelUsage: rows,
            capabilityUsage: capabilityUsage(for: dailySessions),
            cacheHitRate: promptTokens > 0
                ? Double(cachedPromptTokens) / Double(promptTokens)
                : 0,
            maximumContextTokens: max(maximumContextTokens, maximumCLIContextTokens)
        )
    }

    static func sessions(
        on day: Date,
        from sessions: [AgentUsageSessionSnapshot],
        calendar sourceCalendar: Calendar = .current
    ) -> [AgentUsageSessionSnapshot] {
        guard let interval = sourceCalendar.dateInterval(of: .day, for: day) else {
            return []
        }
        return sessions.compactMap { session in
            let messages = session.messages.filter { interval.contains($0.createdAt) }
            guard !messages.isEmpty else { return nil }
            var dailySession = session
            dailySession.messages = messages
            return dailySession
        }
    }

    /// Sunday-first dates needed to render a conventional monthly calendar.
    /// Leading and trailing dates are included until the final week is full.
    static func calendarGridDates(
        for month: Date,
        calendar sourceCalendar: Calendar = .current
    ) -> [Date] {
        var calendar = sourceCalendar
        calendar.firstWeekday = 1
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else {
            return []
        }

        let firstDay = calendar.startOfDay(for: monthInterval.start)
        let leadingDayCount = calendar.component(.weekday, from: firstDay) - 1
        let occupiedCellCount = leadingDayCount + dayRange.count
        let totalCellCount = ((occupiedCellCount + 6) / 7) * 7
        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDayCount,
            to: firstDay
        ) else {
            return []
        }

        return (0..<totalCellCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
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

    /// Desktop model rows plus the CLI ledger, merged by provider|model so a
    /// model used from both clients is one row tagged with both sources.
    static func modelUsage(
        for sessions: [AgentUsageSessionSnapshot],
        cliRecords: [AgentCLIUsageRecord]
    ) -> [AgentModelUsageRow] {
        let desktopRows = modelUsage(for: sessions)
        guard !cliRecords.isEmpty else { return desktopRows }
        var rows = Dictionary(uniqueKeysWithValues: desktopRows.map { ($0.id, $0) })
        var sessionKeys: [String: Set<String>] = [:]
        for record in cliRecords {
            let modelID = normalizedModelID(record.modelID ?? "")
            let declaredProviderID = record.providerID ?? ""
            let providerID = declaredProviderID.isEmpty ? inferProviderID(from: modelID) : declaredProviderID
            let key = "\(providerID)|\(modelID)"
            var row = rows[key] ?? AgentModelUsageRow(
                providerID: providerID,
                providerName: AgentProviderPreset.normalizedDisplayName(
                    providerID: providerID,
                    storedDisplayName: nil
                ) ?? providerID,
                modelID: modelID,
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
                isDelegatedExternal: false,
                cacheDiagnosticTurns: 0,
                stablePrefixCharactersTotal: 0,
                sources: []
            )
            if sessionKeys[key, default: []].insert(record.sessionID ?? record.id.uuidString).inserted {
                row.sessionCount += 1
            }
            row.sources.insert(.cli)
            row.messageCount += 1
            row.promptTokens += record.inputTokens ?? 0
            row.completionTokens += record.outputTokens ?? 0
            row.cachedPromptTokens += record.cachedInputTokens ?? 0
            row.totalTokens += record.countedTokens
            row.estimatedCostUSD = estimatedCostUSD(for: row)
            rows[key] = row
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

    static func modelUsage(for sessions: [AgentUsageSessionSnapshot]) -> [AgentModelUsageRow] {
        var rows: [String: AgentModelUsageRow] = [:]

        for session in sessions {
            var seenKeysInSession = Set<String>()

            for message in session.messages where message.role == .assistant && message.origin != .hostGenerated {
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

            // A worker's tokens bill to the model the worker ran on, not to
            // the parent that spawned it. Folding them into the parent's row
            // (or dropping them, which is what happened before worker
            // accounting existed) makes the cheap tier look free: the whole
            // point of the tier is that these tokens moved somewhere cheaper,
            // and that only shows up if they are counted where they landed.
            let workerUsages = session.messages.flatMap(\.subagentRuns)
                + (session.hostWorkerRuns ?? []).compactMap(\.usage)
                + (session.coordinatorWorkerRuns ?? [])
            for run in workerUsages {
                let modelID = normalizedModelID(run.model)
                let declaredProviderID = run.providerID?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let providerID = declaredProviderID.isEmpty
                    ? inferProviderID(from: modelID)
                    : declaredProviderID
                let key = "\(providerID)|\(modelID)"
                var row = rows[key] ?? AgentModelUsageRow(
                    providerID: providerID,
                    providerName: AgentProviderPreset.normalizedDisplayName(
                        providerID: providerID,
                        storedDisplayName: nil
                    ) ?? providerID,
                    modelID: modelID,
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
                    isDelegatedExternal: false,
                    cacheDiagnosticTurns: 0,
                    stablePrefixCharactersTotal: 0
                )
                if seenKeysInSession.insert(key).inserted {
                    row.sessionCount += 1
                }
                // One child loop is one row entry, however many rounds it ran:
                // `messageCount` counts requests the user's work produced, and
                // the per-round detail already lives in the transcript sidecar.
                row.messageCount += 1
                if run.promptTokens > 0 || run.completionTokens > 0 {
                    row.promptTokens += run.promptTokens
                    row.completionTokens += run.completionTokens
                    row.cachedPromptTokens += run.cachedPromptTokens
                    row.totalTokens += max(
                        run.usageTokens,
                        run.promptTokens + run.completionTokens
                    )
                } else if run.usageTokens > 0 {
                    // Total without a split: charge it as completion, matching
                    // how this file already prices unmeasured tokens. Erring
                    // high on a cost dashboard beats erring low.
                    row.completionTokens += run.usageTokens
                    row.totalTokens += run.usageTokens
                    row.estimatedTokens += run.usageTokens
                    row.hasEstimatedUsage = true
                }
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

    static func subagentUsage(for sessions: [AgentSession]) -> [AgentSubagentUsageRow] {
        subagentUsage(for: sessions.map { AgentUsageSessionSnapshot(session: $0) })
    }

    static func skillWorkerKPIs(
        for sessions: [AgentUsageSessionSnapshot]
    ) -> AgentSkillWorkerKPIs {
        var kpis = AgentSkillWorkerKPIs()
        let deepID = AgentSubagentProfileCatalog.deep.id

        for session in sessions {
            var currentEligibleUserMessageID: UUID?
            var eligibleUserMessageIDs = Set<UUID>()
            var handledUserMessageIDs = Set<UUID>()

            func recordRun(profileID: String, usage: AgentSubagentRunUsage?) {
                if profileID == deepID {
                    kpis.deepRunCount += 1
                } else {
                    kpis.narrowRunCount += 1
                    if usage?.escalatedFromModel != nil {
                        kpis.escalatedRunCount += 1
                    }
                }
                guard let usage else { return }
                if let passed = usage.verifierPassed {
                    kpis.verifiedRunCount += 1
                    if passed { kpis.verifiedPassCount += 1 }
                }
                if let checked = usage.citationsChecked, checked > 0 {
                    kpis.citationsChecked += checked
                    kpis.citationsResolved += checked - (usage.citationsUnverifiable ?? 0)
                }
            }

            for message in session.messages {
                if message.isOperatorInput == true,
                   message.workerRouteProfileID != nil,
                   let messageID = message.id {
                    eligibleUserMessageIDs.insert(messageID)
                    currentEligibleUserMessageID = messageID
                }
                if message.role == .assistant, message.origin != .delegatedExternal, message.origin != .hostGenerated {
                    kpis.parentTurnCount += 1
                    if !message.subagentRuns.isEmpty,
                       let currentEligibleUserMessageID {
                        handledUserMessageIDs.insert(currentEligibleUserMessageID)
                    }
                }
                for run in message.subagentRuns {
                    recordRun(profileID: run.profileID, usage: run)
                }
            }

            // Coordinator-started runs have no tool call and no host record,
            // so they reach the KPIs only here. They carry no verifier verdict
            // or citation audit, which `recordRun` already treats as absent
            // rather than as a failure.
            for run in session.coordinatorWorkerRuns ?? [] {
                recordRun(profileID: run.profileID, usage: run)
            }

            for hostRun in session.hostWorkerRuns ?? [] where hostRun.startedAt != nil {
                recordRun(profileID: hostRun.profileID, usage: hostRun.usage)
                if hostRun.source == .automaticCoding {
                    kpis.automaticCodingRunCount += 1
                    if hostRun.acceptedOutput == true {
                        kpis.straightThroughDeliveryCount += 1
                    }
                    if hostRun.requiredParentRepair == true {
                        kpis.parentRepairCodingRunCount += 1
                    }
                }
                if let userMessageID = hostRun.userMessageID,
                   eligibleUserMessageIDs.contains(userMessageID) {
                    handledUserMessageIDs.insert(userMessageID)
                }
            }
            kpis.codingPlanCacheHitCount += (session.hostWorkerRuns ?? []).filter {
                $0.source == .codingPlanCacheHit
            }.count
            kpis.eligibleUserTurnCount += eligibleUserMessageIDs.count
            kpis.workerHandledUserTurnCount += handledUserMessageIDs.count
        }

        return kpis
    }

    static func subagentUsage(
        for sessions: [AgentUsageSessionSnapshot]
    ) -> [AgentSubagentUsageRow] {
        var invocationCounts: [String: Int] = [:]
        var runCounts: [String: Int] = [:]
        var sessionIDs: [String: Set<UUID>] = [:]

        for session in sessions {
            for storedProfileID in session.messages.flatMap(\.subagentProfileIDs) {
                let profileID = AgentSubagentProfileCatalog.publicID(for: storedProfileID)
                invocationCounts[profileID, default: 0] += 1
                sessionIDs[profileID, default: []].insert(session.id)
            }
            for run in session.messages.flatMap(\.subagentRuns) {
                let profileID = AgentSubagentProfileCatalog.publicID(for: run.profileID)
                runCounts[profileID, default: 0] += 1
                sessionIDs[profileID, default: []].insert(session.id)
            }
            for run in session.coordinatorWorkerRuns ?? [] {
                let profileID = AgentSubagentProfileCatalog.publicID(for: run.profileID)
                invocationCounts[profileID, default: 0] += 1
                runCounts[profileID, default: 0] += 1
                sessionIDs[profileID, default: []].insert(session.id)
            }
            for hostRun in session.hostWorkerRuns ?? [] {
                guard hostRun.source != .codingPlanCacheHit else { continue }
                let profileID = AgentSubagentProfileCatalog.publicID(for: hostRun.profileID)
                invocationCounts[profileID, default: 0] += 1
                sessionIDs[profileID, default: []].insert(session.id)
                if hostRun.startedAt != nil {
                    runCounts[profileID, default: 0] += 1
                }
            }
        }

        let profileIDs = Set(invocationCounts.keys).union(runCounts.keys)
        return profileIDs.map { profileID in
            AgentSubagentUsageRow(
                profileID: profileID,
                invocationCount: invocationCounts[profileID] ?? 0,
                runCount: runCounts[profileID] ?? 0,
                sessionCount: sessionIDs[profileID]?.count ?? 0
            )
        }
        .sorted {
            if $0.invocationCount != $1.invocationCount {
                return $0.invocationCount > $1.invocationCount
            }
            return $0.profileID < $1.profileID
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
        guard message.origin != .hostGenerated else { return 0 }
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
        message: AgentUsageMessageSnapshot? = nil,
        session: AgentUsageSessionSnapshot,
        modelID: String
    ) -> (id: String, name: String) {
        if let providerID = message?.requestProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return (
                providerID,
                AgentProviderPreset.normalizedDisplayName(
                    providerID: providerID,
                    storedDisplayName: message?.requestProviderDisplayName
                ) ?? providerID
            )
        }
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
        if let requestModelID = message.requestModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestModelID.isEmpty {
            return (
                providerSnapshot(message: message, session: session, modelID: requestModelID),
                requestModelID,
                false
            )
        }
        // Managed messages persisted before per-turn route attribution keep
        // the legacy aggregate label instead of falling into unknown-model.
        if session.isManagedRouting {
            return (providerSnapshot(session: session, modelID: Self.managedRoutingModelID), Self.managedRoutingModelID, false)
        }
        let modelID = normalizedModelID(session.modelID)
        return (providerSnapshot(session: session, modelID: modelID), modelID, false)
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
        guard message.origin != .hostGenerated else { return (0, 0, 0, 0, 0, 0, 0, false) }
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
        return estimatedCostUSD(
            providerID: row.providerID,
            modelID: row.modelID,
            promptTokens: row.promptTokens,
            completionTokens: row.completionTokens,
            cachedPromptTokens: row.cachedPromptTokens,
            cacheWritePromptTokens: row.cacheWritePromptTokens
        )
    }

    private static func estimatedCostUSD(
        for message: AgentUsageMessageSnapshot,
        session: AgentUsageSessionSnapshot
    ) -> Double? {
        let identity = usageIdentity(for: message, session: session)
        guard !identity.isDelegatedExternal else { return nil }
        let usage = usageBreakdown(for: message)
        return estimatedCostUSD(
            providerID: identity.provider.id,
            modelID: identity.modelID,
            promptTokens: usage.prompt,
            completionTokens: usage.completion,
            cachedPromptTokens: usage.cachedPrompt,
            cacheWritePromptTokens: usage.cacheWritePrompt
        )
    }

    private static func estimatedCostUSD(
        providerID: String,
        modelID: String,
        promptTokens: Int,
        completionTokens: Int,
        cachedPromptTokens: Int,
        cacheWritePromptTokens: Int
    ) -> Double? {
        guard let price = AgentModelPricing.price(providerID: providerID, modelID: modelID) else {
            return nil
        }
        let cached = min(cachedPromptTokens, promptTokens)
        let uncachedPrompt = max(0, promptTokens - cached)
        let inputCost = Double(uncachedPrompt) * price.inputPerMillion / 1_000_000.0
        let cachedCost = Double(cached) * (price.cachedInputPerMillion ?? price.inputPerMillion) / 1_000_000.0
        let cacheWriteCost = Double(cacheWritePromptTokens) * (price.cacheWritePerMillion ?? price.inputPerMillion) / 1_000_000.0
        let outputCost = Double(completionTokens) * price.outputPerMillion / 1_000_000.0
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
        // someim-* models also show up under provider "custom" when routed
        // through an OpenAI-compatible relay; anchor them back to some-im.
        if model.contains("someim") {
            candidates.append("some-im")
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
        // gpt-5.6 tiers must precede the broad "gpt-5" family row, otherwise
        // the substring match silently bills them at gpt-5 rates. Cached input
        // is 10% of the standard rate (OpenAI pricing page, 2026-08).
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6-sol"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: nil, outputPerMillion: 30.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6-terra"], inputPerMillion: 2.0, cachedInputPerMillion: 0.2, cacheWritePerMillion: nil, outputPerMillion: 12.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6-luna"], inputPerMillion: 0.20, cachedInputPerMillion: 0.02, cacheWritePerMillion: nil, outputPerMillion: 1.20),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: nil, outputPerMillion: 30.0),
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

        // some.im 托管系列（someim-auto / someim-code / someim-coding-plan 等）
        // 无公开牌价，按 deepseek-v4-flash 的价目估算。
        AgentModelPrice(providerIDs: ["some-im"], modelHints: ["someim-"], inputPerMillion: 0.14, cachedInputPerMillion: 0.0028, cacheWritePerMillion: nil, outputPerMillion: 0.28),

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

        // kimi-k3 — Moonshot official API list price (USD/M, 2026-07); cache
        // hit bills at $0.30/M, flat across the full context window.
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k3"], inputPerMillion: 3.0, cachedInputPerMillion: 0.30, cacheWritePerMillion: nil, outputPerMillion: 15.0),
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
