//
//  AgentSelfLearning.swift
//  WillDeep
//
//  Memory, skill, and MCP capability suggestions for the Agent.
//

import Foundation

struct AgentSelfLearningMCPSuggestion: Equatable {
    var capability: String
    var ecosystem: String?
    var searchQuery: String
    var reason: String
}

struct AgentSelfLearningSkillCandidate: Equatable {
    var name: String
    var description: String
    var body: String
    var reason: String
}

nonisolated struct AgentUserSkillBatchDraft: Codable, Equatable {
    var name: String
    var description: String
    var body: String
}

nonisolated enum AgentLearningEventKind: String, Codable, Equatable {
    case memory
    case skill
    case mcpSuggestion
}

nonisolated enum AgentLearningEventStatus: String, Codable, Equatable {
    case saved
    case created
    case suggested
    case skipped
    case failed
}

nonisolated enum AgentLearningActionKind: String, Codable, Equatable {
    case saveMemory
    case createSkill
    case proposeSkill
    case searchMCP
    case suggestMCPInstall
}

nonisolated struct AgentLearningSkillDraft: Codable, Equatable {
    var name: String
    var description: String
    var body: String
}

/// 1.85.0-rc16:turn-end 自动 memory capture 不再直接落盘 —— 拍成 draft
/// 挂在 [AgentLearningEvent.memoryDrafts](Xedit/AgentSelfLearning.swift) 上,
/// 由 popover 的 Approve 按钮触发真正写入。所有字段都是 Codable 基本
/// 类型,持久化平迁老 session。
nonisolated struct AgentMemoryDraft: Codable, Equatable, Hashable {
    var content: String
    var scopeRaw: String        // AgentMemoryScope.rawValue
    var lifetimeRaw: String     // AgentMemoryLifetime.rawValue
    /// 当 scope == .project 时,落盘需要 workspace 根路径 —— 这里存绝对
    /// 路径而不是 fingerprint,便于 popover 这边直接 `URL(fileURLWithPath:)`
    /// 还原。global memory 留 nil。
    var rootDirectoryPath: String?

    var scope: AgentMemoryScope {
        AgentMemoryScope(rawValue: scopeRaw) ?? .global
    }

    var lifetime: AgentMemoryLifetime {
        AgentMemoryLifetime(rawValue: lifetimeRaw) ?? .longTerm
    }

    var rootDirectoryURL: URL? {
        rootDirectoryPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
}

nonisolated struct AgentLearningMCPDraft: Codable, Equatable {
    var capability: String
    var serverName: String
    var installHint: String?
    var searchQuery: String?
    var transport: AgentMCPTransport?
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    var startupTimeout: TimeInterval?
    var reason: String
}

nonisolated struct AgentLearningAction: Codable, Equatable {
    var kind: AgentLearningActionKind
    var commandName: String?
    var target: String?
    var searchQuery: String?
    var skillDraft: AgentLearningSkillDraft?
    var mcpDraft: AgentLearningMCPDraft?
    var reason: String
    var nextStep: String?
    var requiresUserConfirmation: Bool

    init(
        kind: AgentLearningActionKind,
        commandName: String? = nil,
        target: String? = nil,
        searchQuery: String? = nil,
        skillDraft: AgentLearningSkillDraft? = nil,
        mcpDraft: AgentLearningMCPDraft? = nil,
        reason: String,
        nextStep: String? = nil,
        requiresUserConfirmation: Bool = false
    ) {
        self.kind = kind
        self.commandName = commandName
        self.target = target
        self.searchQuery = searchQuery
        self.skillDraft = skillDraft
        self.mcpDraft = mcpDraft
        self.reason = reason
        self.nextStep = nextStep
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}

/// A back-reference from a learning event to a turn-recall item that
/// influenced it. Lets the UI say not just "this suggestion came from a
/// tool sequence" but also "it relates to these recall hits this turn".
/// `id` matches an `AgentTurnRecallItem.id` in the same turn's snapshot;
/// `title`/`kind` are duplicated so the event is self-contained for
/// display and copy without cross-referencing the snapshot.
nonisolated struct AgentLearningRecallLink: Identifiable, Codable, Equatable {
    /// Qualitative association strength, derived from the numeric score.
    enum Strength: String, Codable, Equatable {
        case strong
        case related
        case weak
    }

    var id: UUID
    var kind: AgentTurnRecallKind
    var title: String
    /// 0–1 relevance of this recall hit to the learning event. Optional in
    /// storage so links persisted before scoring existed still decode.
    var score: Double?
    /// Human-readable "why linked" explanation (e.g. shared keywords or a
    /// verbatim title match). Optional for the same backward-compat reason.
    var reason: String?

    /// Banded view of `score` for compact display. `nil` score (legacy
    /// links) reads as `.related` so the UI still renders sensibly.
    var strength: Strength {
        switch score ?? 0.6 {
        case 0.8...: return .strong
        case 0.5...: return .related
        default: return .weak
        }
    }

    init(
        id: UUID,
        kind: AgentTurnRecallKind,
        title: String,
        score: Double? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.score = score
        self.reason = reason
    }
}

nonisolated struct AgentLearningEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: AgentLearningEventKind
    var status: AgentLearningEventStatus
    var title: String
    var detail: String
    var action: AgentLearningAction?
    var createdAt: Date
    /// Optional in storage so sessions persisted before this field
    /// existed still decode (a missing key becomes `nil`, not a decode
    /// failure that would drop the whole session file). Read through
    /// `recallLinks` for a non-optional view.
    var relatedRecall: [AgentLearningRecallLink]?
    /// 1.85.0-rc16:turn-end 自动 memory 不再直接落盘,把候选拍成 draft
    /// 挂这里 —— popover 的 Approve 按钮触发真正写入。同样 Optional 平
    /// 迁老 session(missing = nil = 没有待审 draft)。
    var memoryDrafts: [AgentMemoryDraft]?

    /// Non-optional accessor for the recall back-references.
    var recallLinks: [AgentLearningRecallLink] { relatedRecall ?? [] }

    /// 便于 view 层直接判断「这个事件有没有可 Approve 的 memory 写入」。
    var pendingMemoryDrafts: [AgentMemoryDraft] { memoryDrafts ?? [] }

    init(
        id: UUID = UUID(),
        kind: AgentLearningEventKind,
        status: AgentLearningEventStatus,
        title: String,
        detail: String,
        action: AgentLearningAction? = nil,
        createdAt: Date = Date(),
        relatedRecall: [AgentLearningRecallLink]? = nil,
        memoryDrafts: [AgentMemoryDraft]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
        self.action = action
        self.createdAt = createdAt
        self.relatedRecall = relatedRecall
        self.memoryDrafts = memoryDrafts
    }
}

struct AgentSelfLearningAudit: Equatable {
    var latestUserText: String
    var evidenceText: String
    var memoryContents: [String]
    var mcpSuggestion: AgentSelfLearningMCPSuggestion?
    var skillCandidate: AgentSelfLearningSkillCandidate?
    var relevantToolCallCount: Int
    var relevantToolNames: [String]
    var explicitSkillDirective: Bool
}

enum AgentSelfLearning {
    private static let maxMemoryCharacters = 1_200
    private static let maxSkillBodyCharacters = 12_000
    static let maxSkillBatchCount = 10
    private static let maxSkillBatchJSONCharacters = 128_000
    private static let maxMCPNoteCharacters = 1_200
    private static let defaultMCPSearchCount = 5
    private static let maxMCPSearchCount = 10

    @MainActor
    static func addMemory(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?,
        state: AgentMemoryState? = nil
    ) throws -> AgentToolResult {
        let state = state ?? AgentMemoryState()
        let content = try limitedRequiredString(
            "content",
            in: arguments,
            maxCharacters: maxMemoryCharacters
        )
        let scope = resolveScope(
            arguments["scope"]?.stringValue(),
            content: content,
            rootDirectory: rootDirectory
        )
        let lifetime = parseLifetime(arguments["lifetime"]?.stringValue())
        state.addMemory(
            content: content,
            source: .automatic,
            lifetime: lifetime,
            scope: scope,
            rootDirectory: rootDirectory
        )
        let stored = state.memories.first
        let scopeLabel = stored?.scope.displayName ?? scope.displayName
        return AgentToolResult(
            summary: "Saved \(scopeLabel.lowercased()) memory",
            payload: "Saved memory: \(stored?.content ?? content)"
        )
    }

    static func createUserSkill(
        arguments: [String: AgentJSONValue],
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) throws -> AgentToolResult {
        let name = try limitedRequiredString("name", in: arguments, maxCharacters: 80)
        let description = try limitedRequiredString("description", in: arguments, maxCharacters: 240)
        let body = try limitedRequiredString("body", in: arguments, maxCharacters: maxSkillBodyCharacters)
        let sanitizedDescription = AgentMemorySanitizer.sanitize(description).text
        let sanitizedBody = AgentMemorySanitizer.sanitize(body).text
        let url = try AgentSkillFileManager.createUserSkill(
            name: name,
            description: sanitizedDescription,
            body: sanitizedBody,
            root: root
        )
        return AgentToolResult(
            summary: "Created skill \(url.deletingLastPathComponent().lastPathComponent)",
            payload: "Created user skill at \(url.path). Refresh skills or type $ to attach it in a future turn."
        )
    }

    static func createUserSkills(
        arguments: [String: AgentJSONValue],
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) throws -> AgentToolResult {
        let rawJSON = try limitedRequiredString(
            "skills_json",
            in: arguments,
            maxCharacters: maxSkillBatchJSONCharacters
        )
        let drafts = try decodeSkillBatch(rawJSON)
        let normalized = try drafts.map { draft in
            let values: [String: AgentJSONValue] = [
                "name": .string(draft.name),
                "description": .string(draft.description),
                "body": .string(draft.body),
            ]
            return AgentUserSkillBatchDraft(
                name: try limitedRequiredString("name", in: values, maxCharacters: 80),
                description: AgentMemorySanitizer.sanitize(
                    try limitedRequiredString("description", in: values, maxCharacters: 240)
                ).text,
                body: AgentMemorySanitizer.sanitize(
                    try limitedRequiredString("body", in: values, maxCharacters: maxSkillBodyCharacters)
                ).text
            )
        }

        let slugs = normalized.map { AgentSkillFileManager.skillSlug(from: $0.name) }
        guard slugs.allSatisfy({ !$0.isEmpty }) else {
            throw AgentSkillFileError.invalidName
        }
        guard Set(slugs).count == slugs.count else {
            throw AgentToolError.invalidArgument("skills_json contains duplicate skill names.")
        }

        let fileManager = FileManager.default
        let directories = slugs.map { root.appendingPathComponent($0, isDirectory: true) }
        if let existingIndex = directories.firstIndex(where: { fileManager.fileExists(atPath: $0.path) }) {
            throw AgentSkillFileError.alreadyExists(slugs[existingIndex])
        }

        let stagingRoot = root
            .deletingLastPathComponent()
            .appendingPathComponent(".willdeep-skill-batch-\(UUID().uuidString)", isDirectory: true)
        var committedDirectories: [URL] = []
        var createdURLs: [URL] = []
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            for draft in normalized {
                _ = try AgentSkillFileManager.createUserSkill(
                    name: draft.name,
                    description: draft.description,
                    body: draft.body,
                    root: stagingRoot
                )
            }

            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            for (slug, directory) in zip(slugs, directories) {
                guard !fileManager.fileExists(atPath: directory.path) else {
                    throw AgentSkillFileError.alreadyExists(slug)
                }
                try fileManager.moveItem(
                    at: stagingRoot.appendingPathComponent(slug, isDirectory: true),
                    to: directory
                )
                committedDirectories.append(directory)
                createdURLs.append(directory.appendingPathComponent("SKILL.md"))
            }
        } catch {
            for directory in committedDirectories.reversed() {
                try? fileManager.removeItem(at: directory)
            }
            try? fileManager.removeItem(at: stagingRoot)
            AgentSkillDirectory.invalidateCache()
            throw error
        }
        try? fileManager.removeItem(at: stagingRoot)
        AgentSkillDirectory.invalidateCache()

        let createdLines = zip(slugs, createdURLs).map { slug, url in
            "- \(slug): \(url.path)"
        }
        return AgentToolResult(
            summary: "Created \(createdURLs.count) user skills",
            payload: ([
                "Created \(createdURLs.count) user skills in one approved batch:",
            ] + createdLines + [
                "Refresh skills or type $ to attach them in a future turn.",
            ]).joined(separator: "\n")
        )
    }

    nonisolated static func decodeSkillBatch(_ rawJSON: String) throws -> [AgentUserSkillBatchDraft] {
        guard let data = rawJSON.data(using: .utf8) else {
            throw AgentToolError.invalidArgument("skills_json is not UTF-8.")
        }
        let drafts: [AgentUserSkillBatchDraft]
        do {
            drafts = try JSONDecoder().decode([AgentUserSkillBatchDraft].self, from: data)
        } catch {
            throw AgentToolError.invalidArgument(
                "skills_json must be a JSON array of {name, description, body} objects."
            )
        }
        guard !drafts.isEmpty else {
            throw AgentToolError.invalidArgument("skills_json must contain at least one skill.")
        }
        guard drafts.count <= maxSkillBatchCount else {
            throw AgentToolError.invalidArgument(
                "skills_json can contain at most \(maxSkillBatchCount) skills."
            )
        }
        return drafts
    }

    static func auditTurn(
        for runtime: AgentRuntime,
        workspaceURL: URL?,
        skillSettings: AgentSkillSettings = AgentSkillSettingsStore.load().normalized
    ) -> AgentSelfLearningAudit? {
        // isOperatorInput: hidden host carriers are `.user` role; feeding
        // their turn-context reminder into learning would store host prompt
        // scaffolding as if the human said it.
        guard let latestUser = runtime.messages.last(where: { $0.isOperatorInput }) else {
            return nil
        }
        let recentAssistantText = runtime.messages
            .reversed()
            .filter { $0.role == .assistant && $0.createdAt >= latestUser.createdAt }
            .prefix(3)
            .map(\.modelContent)
            .reversed()
            .joined(separator: "\n\n")
        let evidenceText = [latestUser.modelContent, recentAssistantText]
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let relevantAssistantIDs = Set(
            runtime.messages
                .filter { $0.role == .assistant && $0.createdAt >= latestUser.createdAt }
                .map(\.id)
        )
        let calls = runtime.toolCalls.filter {
            relevantAssistantIDs.contains($0.messageID) && $0.status == .succeeded
        }
        // 框架规则类候选只看用户原话：assistant 措辞里"建议/以后/自动"
        // 这类词天天出现，拿混合证据喂关键词匹配会让每个回合都误产
        // 学习事件（1.195.0-rc11 实测），所以强意图闸只对用户文本生效。
        let memoryContents = automaticSelfLearningMemories(fromUserText: latestUser.modelContent)
        let mcpSuggestion = automaticMCPSuggestion(
            userText: latestUser.modelContent,
            evidenceText: evidenceText
        )
        // Only the operator can authorize automatic skill creation. Assistant
        // narration such as "this could become a skill" is evidence for a
        // review candidate, never an instruction to write one.
        let explicitSkillDirective = containsExplicitSkillCreationSignal(latestUser.modelContent)
        let skillCandidate = automaticSkillCandidate(
            userText: latestUser.modelContent,
            assistantText: recentAssistantText,
            calls: calls,
            workspaceURL: workspaceURL,
            settings: skillSettings
        )

        guard !memoryContents.isEmpty || mcpSuggestion != nil || skillCandidate != nil else {
            return nil
        }
        return AgentSelfLearningAudit(
            latestUserText: latestUser.modelContent,
            evidenceText: evidenceText,
            memoryContents: memoryContents,
            mcpSuggestion: mcpSuggestion,
            skillCandidate: skillCandidate,
            relevantToolCallCount: calls.count,
            relevantToolNames: relevantToolNames(from: calls),
            explicitSkillDirective: explicitSkillDirective
        )
    }

    static func searchMCPServers(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let capability = try limitedRequiredString(
            "capability",
            in: arguments,
            maxCharacters: 160
        )
        let ecosystem = limitedOptionalString("ecosystem", in: arguments, maxCharacters: 80)
        let count = min(max(arguments["count"]?.intValue() ?? defaultMCPSearchCount, 1), maxMCPSearchCount)
        let query = mcpSearchQuery(capability: capability, ecosystem: ecosystem)
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let configuredServers = AgentMCPServerDirectory.list(includeDisabled: true)

        var sections = [
            "Capability: \(capability)",
            "Search query: \(query)",
            configuredMCPServerSummary(configuredServers)
        ]

        if dryRun {
            sections.append(mcpSuggestionGuidance)
            return AgentToolResult(
                summary: "Prepared MCP search for \(capability)",
                payload: sections.joined(separator: "\n\n")
            )
        }

        do {
            let searchResult = try await AgentWebTools.webSearch(arguments: [
                "query": .string(query),
                "count": .number(Double(count))
            ])
            sections.append(searchResult.payload)
            sections.append(mcpSuggestionGuidance)
            return AgentToolResult(
                summary: "Searched MCP options for \(capability)",
                payload: sections.joined(separator: "\n\n")
            )
        } catch {
            sections.append("Search failed: \(error.localizedDescription)")
            sections.append("Fallback: ask the user to configure web search, or use the query above manually before calling suggest_mcp_server.")
            sections.append(mcpSuggestionGuidance)
            return AgentToolResult(
                summary: "Prepared MCP search for \(capability)",
                payload: sections.joined(separator: "\n\n")
            )
        }
    }

    @MainActor
    static func suggestMCPServer(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?,
        state: AgentMemoryState? = nil
    ) throws -> AgentToolResult {
        let state = state ?? AgentMemoryState()
        let capability = try limitedRequiredString(
            "capability",
            in: arguments,
            maxCharacters: 160
        )
        let serverName = limitedOptionalString("server_name", in: arguments, maxCharacters: 80)
        let installHint = limitedOptionalString("install_hint", in: arguments, maxCharacters: 360)
        let reason = limitedOptionalString("reason", in: arguments, maxCharacters: 360)
        let searchQuery = limitedOptionalString("search_query", in: arguments, maxCharacters: 160)

        var lines = ["MCP suggestion for capability: \(capability)"]
        if let serverName { lines.append("Suggested server: \(serverName)") }
        if let installHint { lines.append("Install/configure hint: \(installHint)") }
        if let reason { lines.append("Reason: \(reason)") }
        if let searchQuery { lines.append("Search query: \(searchQuery)") }
        lines.append("Do not assume this MCP is installed; ask the user before adding credentials or executing setup.")

        let note = lines.joined(separator: "\n")
        state.addMemory(
            content: String(note.prefix(maxMCPNoteCharacters)),
            source: .automatic,
            lifetime: .longTerm,
            scope: rootDirectory == nil ? .global : .project,
            rootDirectory: rootDirectory
        )

        return AgentToolResult(
            summary: "Suggested MCP for \(capability)",
            payload: note
        )
    }

    @discardableResult
    @MainActor
    static func captureAutomaticMCPCapabilityGap(
        for runtime: AgentRuntime,
        memoryState: AgentMemoryState,
        workspaceURL: URL?
    ) -> [AgentLearningEvent] {
        guard memoryState.settings.normalized.isMemoryEnabled,
              memoryState.settings.normalized.autoSummaryEnabled,
              let audit = auditTurn(for: runtime, workspaceURL: workspaceURL) else {
            return []
        }
        var memories = audit.memoryContents
        if let mcpSuggestion = audit.mcpSuggestion {
            appendUnique(automaticMCPSuggestionMemory(from: mcpSuggestion), to: &memories)
        }
        var events: [AgentLearningEvent] = []

        // 1.85.0-rc16:同 captureAutomaticMemories,这里也不再直接 addMemory
        // 落盘 —— 候选拍成 [AgentMemoryDraft] 等用户 Approve。原先调用
        // `memoryState.addMemory` + 「Saved N memories」事件那一支去掉。
        if !memories.isEmpty {
            let scope: AgentMemoryScope = workspaceURL == nil ? .global : .project
            let drafts = memories.map {
                AgentMemoryDraft(
                    content: $0,
                    scopeRaw: scope.rawValue,
                    lifetimeRaw: AgentMemoryLifetime.longTerm.rawValue,
                    rootDirectoryPath: scope == .project ? workspaceURL?.path : nil
                )
            }
            events.append(AgentLearningEvent(
                kind: .memory,
                status: .suggested,
                title: L10n.Transcript.learningEventTitleSuggestedMemories(String(drafts.count)),
                detail: AgentLearningActionPresentation.memorySuggestionDetail(for: drafts),
                action: AgentLearningAction(
                    kind: .saveMemory,
                    commandName: "add_memory",
                    target: scope == .global
                        ? L10n.Transcript.learningTargetGlobalMemory
                        : L10n.Transcript.learningTargetProjectMemory,
                    reason: L10n.Transcript.learningReasonSelfLearningPolicy,
                    nextStep: L10n.Transcript.learningNextStepApprovePopover,
                    requiresUserConfirmation: true
                ),
                memoryDrafts: drafts
            ))
        }
        if let mcpSuggestion = audit.mcpSuggestion {
            events.append(AgentLearningEvent(
                kind: .mcpSuggestion,
                status: .suggested,
                title: L10n.Transcript.learningEventTitleMCPDiscovery(mcpSuggestion.capability),
                detail: [
                    "Search query: \(mcpSuggestion.searchQuery)",
                    "Reason: \(mcpSuggestion.reason)",
                    "Source: \(mcpSourceSummary(for: audit, capability: mcpSuggestion.capability))",
                    "Install/configuration still needs explicit user confirmation."
                ].joined(separator: "\n"),
                action: AgentLearningAction(
                    kind: .suggestMCPInstall,
                    commandName: "suggest_mcp_server",
                    target: mcpSuggestion.capability,
                    searchQuery: mcpSuggestion.searchQuery,
                    mcpDraft: AgentLearningMCPDraft(
                        capability: mcpSuggestion.capability,
                        serverName: suggestedMCPServerName(for: mcpSuggestion),
                        installHint: "Review candidates from search_mcp_servers before adding transport details or credentials.",
                        searchQuery: mcpSuggestion.searchQuery,
                        reason: mcpSuggestion.reason
                    ),
                    reason: mcpSuggestion.reason,
                    nextStep: L10n.Transcript.learningNextStepRunSearchMCP,
                    requiresUserConfirmation: true
                )
            ))
        }
        return events
    }

    @discardableResult
    static func captureAutomaticSkillCandidate(
        for runtime: AgentRuntime,
        workspaceURL: URL?,
        skillSettings: AgentSkillSettings? = nil,
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) -> [AgentLearningEvent] {
        let settings = (skillSettings ?? AgentSkillSettingsStore.load()).normalized
        guard let audit = auditTurn(
            for: runtime,
            workspaceURL: workspaceURL,
            skillSettings: settings
        ) else { return [] }
        let hasSkillSignal = audit.skillCandidate != nil
            || audit.memoryContents.contains(where: { $0.contains("create_user_skill") })
        guard hasSkillSignal else { return [] }
        guard settings.autoExtractionEnabled else {
            let draft = audit.skillCandidate.map {
                AgentLearningSkillDraft(
                    name: $0.name,
                    description: $0.description,
                    body: $0.body
                )
            }
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .skipped,
                    title: "Skipped automatic skill extraction",
                    detail: [
                        "Automatic skill extraction is disabled in Settings.",
                        "Source: \(skillSourceSummary(for: audit))",
                        draft.map { "Draft skill: \($0.name)" }
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .proposeSkill,
                        commandName: "create_user_skill",
                        target: draft?.name,
                        skillDraft: draft,
                        reason: "The turn had reusable workflow signal, but automatic skill extraction is disabled.",
                        nextStep: "Enable automatic skill extraction in Settings before creating skills from turn evidence.",
                        requiresUserConfirmation: true
                    )
                )
            ]
        }
        guard let candidate = audit.skillCandidate else {
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .skipped,
                    title: L10n.Transcript.learningEventTitleSkippedAutoSkill,
                    detail: [
                        "Reusable-workflow signal was present, but this turn only had \(audit.relevantToolCallCount) relevant tool call(s). Minimum required: \(settings.minimumToolCallCount).",
                        "Source: \(skillSourceSummary(for: audit))"
                    ].joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .proposeSkill,
                        commandName: "create_user_skill",
                        reason: L10n.Transcript.learningReasonSkillEvidenceTooThin,
                        nextStep: L10n.Transcript.learningNextStepWaitForWorkflow
                    )
                )
            ]
        }
        guard audit.explicitSkillDirective else {
            let draft = AgentLearningSkillDraft(
                name: candidate.name,
                description: candidate.description,
                body: candidate.body
            )
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .suggested,
                    title: L10n.Transcript.learningActionProposeSkill,
                    detail: [
                        candidate.reason,
                        "Source: \(skillSourceSummary(for: audit))",
                        "Draft skill: \(candidate.name)"
                    ].joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .proposeSkill,
                        commandName: "create_user_skill",
                        target: candidate.name,
                        skillDraft: draft,
                        reason: candidate.reason,
                        nextStep: L10n.Transcript.learningExplanationDraftNeedsReview,
                        requiresUserConfirmation: true
                    )
                )
            ]
        }
        do {
            let url = try AgentSkillFileManager.createUserSkill(
                name: candidate.name,
                description: candidate.description,
                body: candidate.body,
                root: root
            )
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .created,
                    title: L10n.Transcript.learningEventTitleCreatedSkill(url.deletingLastPathComponent().lastPathComponent),
                    detail: [
                        candidate.reason,
                        "Source: \(skillSourceSummary(for: audit))",
                        "Path: \(url.path)"
                    ].joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .createSkill,
                        commandName: "create_user_skill",
                        target: url.deletingLastPathComponent().lastPathComponent,
                        skillDraft: AgentLearningSkillDraft(
                            name: candidate.name,
                            description: candidate.description,
                            body: candidate.body
                        ),
                        reason: candidate.reason,
                        nextStep: L10n.Transcript.learningNextStepFutureTurnDiscover
                    )
                )
            ]
        } catch AgentSkillFileError.alreadyExists(let slug) {
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .skipped,
                    title: L10n.Transcript.learningEventTitleSkippedExistingSkill(slug),
                    detail: [
                        "A skill with the same generated name already exists; the existing skill was left untouched.",
                        "Source: \(skillSourceSummary(for: audit))",
                        "Draft skill: \(candidate.name)"
                    ].joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .proposeSkill,
                        commandName: "create_user_skill",
                        target: slug,
                        skillDraft: AgentLearningSkillDraft(
                            name: candidate.name,
                            description: candidate.description,
                            body: candidate.body
                        ),
                        reason: L10n.Transcript.learningReasonSkillAlreadyExists,
                        nextStep: L10n.Transcript.learningNextStepReuseExisting
                    )
                )
            ]
        } catch {
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .failed,
                    title: L10n.Transcript.learningEventTitleAutoSkillFailed,
                    detail: [
                        error.localizedDescription,
                        "Source: \(skillSourceSummary(for: audit))",
                        "Draft skill: \(candidate.name)"
                    ].joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .createSkill,
                        commandName: "create_user_skill",
                        target: candidate.name,
                        skillDraft: AgentLearningSkillDraft(
                            name: candidate.name,
                            description: candidate.description,
                            body: candidate.body
                        ),
                        reason: L10n.Transcript.learningReasonSkillWriteFailed,
                        nextStep: L10n.Transcript.learningNextStepRetryAfterFix,
                        requiresUserConfirmation: true
                    )
                )
            ]
        }
    }

    private static func automaticSkillCandidate(
        userText: String,
        assistantText: String,
        calls: [AgentToolCall],
        workspaceURL: URL?,
        settings: AgentSkillSettings
    ) -> AgentSelfLearningSkillCandidate? {
        let lowerUserText = userText.lowercased()
        let explicitSkillDirective = containsExplicitSkillCreationSignal(userText)
        let hasImplicitReusableIntent = hasStrongDurableIntent(in: lowerUserText)
            && containsReusableWorkflowSignal(userText)
        guard hasImplicitReusableIntent || explicitSkillDirective else { return nil }

        let requiredToolCalls = explicitSkillDirective
            ? 4
            : settings.minimumToolCallCount
        guard calls.count >= requiredToolCalls else { return nil }

        return AgentSelfLearningSkillCandidate(
            name: skillName(from: userText),
            description: "Use when repeating this workflow: \(oneLine(userText, limit: 160))",
            body: automaticSkillBody(
                userText: userText,
                assistantText: assistantText,
                calls: calls,
                workspaceURL: workspaceURL
            ),
            reason: explicitSkillDirective
                ? "The user explicitly asked to create or save a reusable skill."
                : "The turn contains a reusable workflow signal and enough tool evidence."
        )
    }

    private static func automaticSkillBody(
        userText: String,
        assistantText: String,
        calls: [AgentToolCall],
        workspaceURL: URL?
    ) -> String {
        let toolSummary = calls
            .prefix(16)
            .map { call in
                "- \(call.toolName): \(call.result?.summary ?? call.errorMessage ?? call.status.rawValue)"
            }
            .joined(separator: "\n")
        let workflow = """
        Use this skill when a future task resembles the captured workflow.

        Captured trigger:
        \(oneLine(userText, limit: 500))

        Workspace:
        \(workspaceURL?.lastPathComponent ?? "No local workspace")

        Observed tool sequence:
        \(toolSummary)

        Reuse guidance:
        - Read the current workspace state first; do not assume files or commands are unchanged.
        - Reuse the workflow shape, not stale outputs.
        - Run practical verification before reporting completion.
        - Ask the user before adding credentials, installing global tools, or configuring external services.

        Last assistant summary:
        \(oneLine(assistantText, limit: 1_200))
        """
        return AgentMemorySanitizer.sanitize(workflow).text
    }

    private static func containsReusableWorkflowSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "以后", "下次", "每次", "复用", "工作流", "流程", "套路", "规范",
            "自学习", "skill", "skills", "reusable", "workflow", "whenever",
            "next time", "always", "remember", "以后遇到"
        ]
        return signals.contains { lower.contains($0) }
    }

    private static func containsExplicitSkillCreationSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let mentionsSkill = containsAny(["skill", "skills", "技能"], in: lower)
        let asksCreation = containsAny(
            ["create", "add", "save", "extract", "生成", "创建", "添加", "沉淀", "提炼", "自主", "自动"],
            in: lower
        )
        return mentionsSkill && asksCreation
    }

    static func mcpSearchQuery(capability: String, ecosystem: String?) -> String {
        let compactCapability = oneLine(capability, limit: 120)
        let compactEcosystem = ecosystem.map { oneLine($0, limit: 60) }
        return [
            compactCapability,
            compactEcosystem,
            "MCP server",
            "Model Context Protocol",
            "install"
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    static func automaticSelfLearningMemories(fromUserText text: String) -> [String] {
        let lower = text.lowercased()
        var memories: [String] = []
        // 1.85.0-rc16:加一道 strong-intent 闸 —— 用户得明确说「以后 /
        // 记住 / 偏好 / always / never / from now on / preference / rule」
        // 之类带「持久化意图」的词,才允许进入下面这几条 framework 规则
        // 的匹配。原先只要文本里出现「memory + 自动」这样弱关联的 2 词
        // 组合就触发,误报严重(基本每次随便聊都会蹦出一堆 candidate)。
        //
        // 1.195.0-rc12:输入收紧为用户原话(不再混入 assistant 文本),
        // 并移除不受闸门约束的「general policy」硬编码套话 —— 那句
        // "Agent should proactively save necessary memory..." 曾在普通
        // 开发会话里被 assistant 的日常用词反复触发,存下来也只是把
        // 产品自己的运行策略当经验,零信息量。
        guard hasStrongDurableIntent(in: lower) else {
            return memories
        }
        if containsAny(["memory", "记忆"], in: lower),
           containsAny(["自动", "自主", "必要", "以后", "下次", "proactive", "when needed"], in: lower) {
            appendUnique(
                "Agent should call add_memory when a turn reveals a durable user preference, project rule, recurring fact, or future-facing instruction; keep the memory compact, scoped, and free of secrets.",
                to: &memories
            )
        }
        if containsAny(["skill", "skills", "技能"], in: lower),
           containsAny(["自动", "自主", "必要", "复用", "workflow", "流程", "proactive", "when needed"], in: lower) {
            appendUnique(
                "Agent should call create_user_skill when a completed task establishes a reusable multi-step workflow; the skill must describe when to use it, the steps, verification, and safety boundaries without copying stale outputs.",
                to: &memories
            )
        }
        if containsAny(["mcp", "connector", "plugin", "integration", "外部系统", "连接器", "插件", "集成"], in: lower),
           containsAny(["搜索", "建议", "安装", "必要", "缺少", "search", "suggest", "install", "missing"], in: lower) {
            appendUnique(
                "Agent should inspect configured MCP servers before giving up on an external integration, search MCP candidates when none fit, and suggest a user-confirmed install/configuration path instead of silently omitting the capability.",
                to: &memories
            )
        }
        return memories
    }

    /// rc16:用户必须明确说出「我要长期记住这件事」的意图,才允许 framework
    /// 这层把规则种子塞进 memory candidate 列表。这里收一组中英文常见的
    /// 强意图短语 —— 都是用户在「这是我的偏好 / 以后都这么干 / 别忘了」
    /// 这类场景才用的词。
    ///
    /// 「以后」「下次」单独成立,因为中文里它们本身就承载未来约束;原先
    /// 试图只匹配「以后请 / 下次记得」这种短语,被实际语料(「以后这类
    /// 流程要自动…」「下次自动复用」)漏掉。
    static func hasStrongDurableIntent(in lower: String) -> Bool {
        containsAny(
            [
                "记住", "请记住", "以后", "下次", "偏好", "我喜欢", "默认",
                "永远", "总是", "从此", "始终",
                "always", "never", "from now on", "going forward", "remember that",
                "remember this", "my preference", "i prefer", "by default", "in the future",
            ],
            in: lower
        )
    }

    private static let integrationBlockedSignals = [
        "cannot access", "can't access", "unable to access", "not configured",
        "not installed", "no configured", "unavailable",
        "无法访问", "不能访问", "没有配置", "未配置", "不可用", "需要用户手动"
    ]

    /// 阻塞词之外，还要求同句出现"集成语境"词——"缺少一个字段""missing
    /// test coverage"这类日常表述带着 database/browser 等能力词满天飞，
    /// 没有集成语境时不允许把普通开发对话推断成"缺外部集成"。
    private static let integrationContextTerms = [
        "integration", "mcp", "connector", "tool", "access", "plugin",
        "集成", "连接器", "插件", "工具", "访问"
    ]

    /// 会话内去重：同一条建议（同 kind + 同标题 + 同内容）在一个会话里
    /// 只出现一次。此前每个回合末的自动扫描都可能重复产出同一条 MCP
    /// 建议/框架规则，popover 反复弹同样的内容是"学习太频繁"观感的主因之一。
    nonisolated static func dedupedNewEvents(
        _ events: [AgentLearningEvent],
        existing: [AgentLearningEvent]
    ) -> [AgentLearningEvent] {
        var seen = Set(existing.map(learningEventDedupeKey))
        var fresh: [AgentLearningEvent] = []
        for event in events where seen.insert(learningEventDedupeKey(event)).inserted {
            fresh.append(event)
        }
        return fresh
    }

    private nonisolated static func learningEventDedupeKey(_ event: AgentLearningEvent) -> String {
        "\(event.kind.rawValue)|\(event.title)|\(event.detail)"
    }

    static func learningSentences(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n。.!?；;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func automaticMCPSuggestion(
        userText: String,
        evidenceText: String
    ) -> AgentSelfLearningMCPSuggestion? {
        // 1.195.0-rc12:阻塞信号、能力词、集成语境词必须同句共现。此前
        // 全文任意位置的「缺少/missing」配上任意位置的「数据库/mysql」就
        // 触发建议 —— 普通排障对话（"该表缺少索引"）天天中招。
        for sentence in learningSentences(in: evidenceText) {
            let lower = sentence.lowercased()
            guard containsAny(integrationBlockedSignals, in: lower),
                  containsAny(integrationContextTerms, in: lower),
                  let capability = detectedExternalCapability(in: lower) else {
                continue
            }
            return mcpSuggestion(
                capability: capability,
                ecosystem: capability,
                reason: "The turn indicated \(capability) access is needed but no configured integration is available."
            )
        }

        // 泛化的「帮我做 MCP 发现」只认用户原话；assistant 提到
        // 插件/集成/建议不算数。
        let lowerUser = userText.lowercased()
        let asksForMCPDiscovery = containsAny(
            ["mcp", "connector", "plugin", "连接器", "插件", "外部系统", "集成"],
            in: lowerUser
        ) && containsAny(
            ["搜索", "建议", "安装", "必要", "缺少", "search", "suggest", "install", "missing", "when needed"],
            in: lowerUser
        )
        guard asksForMCPDiscovery else { return nil }
        return mcpSuggestion(
            capability: "missing external integration",
            ecosystem: nil,
            reason: "The user asked the Agent to search and suggest MCP servers when an external capability is missing."
        )
    }

    private static func mcpSuggestion(
        capability: String,
        ecosystem: String?,
        reason: String
    ) -> AgentSelfLearningMCPSuggestion {
        AgentSelfLearningMCPSuggestion(
            capability: capability,
            ecosystem: ecosystem,
            searchQuery: mcpSearchQuery(capability: capability, ecosystem: ecosystem),
            reason: reason
        )
    }

    private static func automaticMCPSuggestionMemory(
        from suggestion: AgentSelfLearningMCPSuggestion
    ) -> String {
        var lines = [
            "MCP suggestion for capability: \(suggestion.capability)",
            "Search query: \(suggestion.searchQuery)",
            "Reason: \(suggestion.reason)",
            "Next step: verify candidates with search_mcp_servers, then call suggest_mcp_server with the chosen package/server and ask the user before installing or adding credentials."
        ]
        if let ecosystem = suggestion.ecosystem {
            lines.insert("Ecosystem: \(ecosystem)", at: 1)
        }
        return String(lines.joined(separator: "\n").prefix(maxMCPNoteCharacters))
    }

    private static var mcpSuggestionGuidance: String {
        """
        Next step:
        - If a result looks relevant, call suggest_mcp_server with capability, server_name, install_hint, reason, and search_query.
        - Do not install MCP servers or add credentials without explicit user confirmation.
        - After the user configures one, verify with list_mcp_servers and list_mcp_tools.
        """
    }

    private static func configuredMCPServerSummary(_ servers: [AgentMCPServerConfig]) -> String {
        guard !servers.isEmpty else {
            return "Configured MCP servers: none detected."
        }
        let lines = servers
            .prefix(12)
            .map { "- \($0.name) [\($0.source.rawValue), \($0.transport.rawValue), \($0.isEnabled ? "enabled" : "disabled")]" }
        let suffix = servers.count > 12 ? "\n- ... \(servers.count - 12) more" : ""
        return "Configured MCP servers:\n" + lines.joined(separator: "\n") + suffix
    }

    private static func skillName(from text: String) -> String {
        let tokens = AgentMemoryKeywordExtractor
            .tokens(from: text)
            .filter { $0.count >= 3 }
        .prefix(4)
        let suffix = tokens.isEmpty ? "workflow" : tokens.joined(separator: "-")
        return "auto-\(suffix)"
    }

    private static func relevantToolNames(from calls: [AgentToolCall]) -> [String] {
        var seen = Set<String>()
        return calls.compactMap { call in
            let name = oneLine(call.toolName, limit: 60)
            guard seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private static func skillSourceSummary(for audit: AgentSelfLearningAudit) -> String {
        let trigger = audit.explicitSkillDirective
            ? "explicit user request to create/save a skill"
            : "reusable workflow signal in the turn"
        let tools = audit.relevantToolNames.prefix(4).joined(separator: ", ")
        if tools.isEmpty {
            return "\(trigger); no relevant tool executions were captured."
        }
        return "\(trigger); relevant tools: \(tools) (\(audit.relevantToolCallCount) call\(audit.relevantToolCallCount == 1 ? "" : "s"))."
    }

    private static func mcpSourceSummary(for audit: AgentSelfLearningAudit, capability: String) -> String {
        if audit.evidenceText.lowercased().contains("not configured")
            || audit.evidenceText.contains("未配置")
            || audit.evidenceText.contains("没有配置")
            || audit.evidenceText.contains("缺少") {
            return "turn evidence indicated \(capability) access was needed but no configured integration was available."
        }
        return "turn evidence asked the Agent to proactively search and suggest MCP options when an external capability is missing."
    }

    private static func detectedExternalCapability(in lower: String) -> String? {
        for candidate in externalCapabilityCandidates {
            if candidate.needles.contains(where: { lower.contains($0) }) {
                return candidate.label
            }
        }
        return nil
    }

    private static let externalCapabilityCandidates: [(needles: [String], label: String)] = [
        (["github", "git hub", "pr review", "pull request", "issue"], "GitHub"),
        (["gmail", "email", "mailbox", "邮件", "邮箱"], "Gmail or email"),
        (["postgres", "postgresql", "mysql", "database", "sql", "数据库"], "database access"),
        (["figma", "design file", "设计稿"], "Figma"),
        (["slack", "飞书", "lark", "钉钉"], "team messaging"),
        (["browser", "chrome", "网页", "浏览器"], "browser automation"),
        (["erp", "kingdee", "金蝶", "wangdiantong", "旺店通"], "ERP data")
    ]

    private static func suggestedMCPServerName(for suggestion: AgentSelfLearningMCPSuggestion) -> String {
        let tokens = AgentMemoryKeywordExtractor.tokens(from: suggestion.capability)
            .filter { $0.count >= 2 }
            .prefix(3)
        let prefix = tokens.isEmpty ? "suggested" : tokens.joined(separator: "-")
        return "\(prefix)-mcp"
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !values.contains(where: { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) else {
            return
        }
        values.append(value)
    }

    private static func containsAny(_ needles: [String], in lower: String) -> Bool {
        needles.contains { lower.contains($0.lowercased()) }
    }

    /// Explicit scope argument wins; when the model omits it, infer from the
    /// content instead of silently defaulting repo conventions to global.
    static func resolveScope(
        _ raw: String?,
        content: String,
        rootDirectory: URL?
    ) -> AgentMemoryScope {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "project", "workspace":
            return .project
        case "global", "user":
            return .global
        default:
            let canBindProject = AgentMemoryEngine.projectFingerprint(for: rootDirectory) != nil
            return canBindProject && AgentMemoryEngine.looksProjectScoped(content) ? .project : .global
        }
    }

    private static func parseLifetime(_ raw: String?) -> AgentMemoryLifetime {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "transient", "temporary", "short":
            return .transient
        default:
            return .longTerm
        }
    }

    private static func limitedRequiredString(
        _ name: String,
        in arguments: [String: AgentJSONValue],
        maxCharacters: Int
    ) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        guard value.count <= maxCharacters else {
            throw AgentToolError.invalidArgument("\(name) is too long; max \(maxCharacters) characters.")
        }
        return value
    }

    private static func limitedOptionalString(
        _ name: String,
        in arguments: [String: AgentJSONValue],
        maxCharacters: Int
    ) -> String? {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.count <= maxCharacters { return value }
        return String(value.prefix(maxCharacters))
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    // MARK: - Recall ↔ learning linkage

    /// Find which turn-recall items relate to a learning event, so the UI
    /// can show "this suggestion relates to these recall hits". Matching is
    /// deterministic (no model call): a recall item links to the event when
    /// either its title appears verbatim in the event's text (the strong
    /// case — e.g. the event proposes to formalize an attached skill by
    /// name), or the two share at least two significant keywords.
    static func relatedRecallLinks(
        for event: AgentLearningEvent,
        in snapshot: AgentTurnRecallSnapshot?
    ) -> [AgentLearningRecallLink] {
        guard let snapshot, !snapshot.items.isEmpty else { return [] }
        let eventText = recallMatchText(for: event)
        guard !eventText.isEmpty else { return [] }
        let eventTokens = significantTokens(eventText)
        var links: [AgentLearningRecallLink] = []
        for item in snapshot.items {
            let titleHit = !item.title.isEmpty
                && eventText.localizedCaseInsensitiveContains(item.title)
            let itemText = ([item.title, item.detail] + item.reasons).joined(separator: " ")
            let shared = eventTokens.intersection(significantTokens(itemText))
            guard titleHit || shared.count >= 2 else { continue }

            // A verbatim title match is the strongest signal; keyword overlap
            // scales with how many significant words are shared.
            let keywordScore = min(0.9, Double(shared.count) * 0.25)
            let base = max(titleHit ? 0.9 : 0, keywordScore)
            // Fold in the recall retrieval relevance: memory items carry a
            // 0–1 retrieval score (attached skills don't). A strongly-recalled
            // item that also matches is a stronger association than a weakly-
            // recalled one. The match signal stays dominant (0.7) so a verbatim
            // title hit never drops below "related".
            let score = item.score.map { min(1.0, base * 0.7 + $0 * 0.3) } ?? base
            links.append(AgentLearningRecallLink(
                id: item.id,
                kind: item.kind,
                title: item.title,
                score: (score * 100).rounded() / 100,
                reason: recallLinkReason(titleHit: titleHit, title: item.title, shared: shared, retrieval: item.score)
            ))
        }
        // Strongest associations first so truncated displays keep the
        // most relevant hits.
        return links.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
    }

    /// Why a recall item was NOT linked to any of the turn's learning
    /// events — currently the near-miss case: it shared exactly one
    /// significant keyword (just below the ≥2 bar). Returns nil when the
    /// item was linked to some event or had no overlap worth explaining.
    static func recallItemLinkStatus(
        _ item: AgentTurnRecallItem,
        events: [AgentLearningEvent]
    ) -> RecallItemLinkStatus {
        if events.contains(where: { $0.recallLinks.contains { $0.id == item.id } }) {
            return .linked
        }
        let itemTokens = significantTokens(([item.title, item.detail] + item.reasons).joined(separator: " "))
        var bestShared: Set<String> = []
        for event in events {
            let eventText = recallMatchText(for: event)
            guard !eventText.isEmpty else { continue }
            let shared = significantTokens(eventText).intersection(itemTokens)
            if shared.count > bestShared.count { bestShared = shared }
        }
        // ≥2 would have linked it elsewhere; a single shared keyword is the
        // informative "almost" case.
        guard bestShared.count == 1, let keyword = bestShared.first else {
            return .unrelated
        }
        return .nearMiss(L10n.Transcript.learningRecallNearMiss(keyword))
    }

    enum RecallItemLinkStatus: Equatable {
        case linked
        case nearMiss(String)
        case unrelated
    }

    /// Turn-level tally of how this turn's recall hits were used by its
    /// learning suggestions, for the report's "did recall feed learning?"
    /// line. `hasLearning` is false when the turn produced no learning
    /// events at all — in that case every hit reads as `unused`, but the
    /// reason is "nothing to link to", which the UI words differently.
    struct RecallUtilization: Equatable {
        var linked: Int
        var nearMiss: Int
        var unused: Int
        var hasLearning: Bool
        var total: Int { linked + nearMiss + unused }
    }

    static func recallUtilization(
        in snapshot: AgentTurnRecallSnapshot?,
        events: [AgentLearningEvent]
    ) -> RecallUtilization {
        var tally = RecallUtilization(linked: 0, nearMiss: 0, unused: 0, hasLearning: !events.isEmpty)
        guard let snapshot else { return tally }
        for item in snapshot.items {
            switch recallItemLinkStatus(item, events: events) {
            case .linked: tally.linked += 1
            case .nearMiss: tally.nearMiss += 1
            case .unrelated: tally.unused += 1
            }
        }
        return tally
    }

    /// Build the "why linked" explanation for a recall association,
    /// optionally noting the underlying recall retrieval relevance.
    private static func recallLinkReason(
        titleHit: Bool,
        title: String,
        shared: Set<String>,
        retrieval: Double?
    ) -> String {
        let base: String
        if titleHit {
            base = L10n.Transcript.learningRecallReasonTitle(title)
        } else {
            let keywords = shared.sorted().prefix(4).joined(separator: ", ")
            base = L10n.Transcript.learningRecallReasonKeywords(keywords)
        }
        guard let retrieval else { return base }
        let formatted = String(format: "%.2f", retrieval)
        return L10n.Transcript.learningRecallReasonWithRecall(base, formatted)
    }

    /// The user-meaningful text of a learning event used for recall
    /// matching: its title/detail plus the structured action's fields.
    private static func recallMatchText(for event: AgentLearningEvent) -> String {
        var parts = [event.title, event.detail]
        if let action = event.action {
            parts.append(action.reason)
            parts.append(contentsOf: [action.target, action.searchQuery, action.nextStep].compactMap { $0 })
            if let draft = action.skillDraft {
                parts.append(contentsOf: [draft.name, draft.description])
            }
            if let draft = action.mcpDraft {
                parts.append(contentsOf: [draft.capability, draft.serverName, draft.reason])
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased alphanumeric tokens of length ≥ 4 with common English
    /// stopwords removed. CJK runs survive as single tokens (no word
    /// boundaries), so CJK overlap requires a shared phrase — verbatim
    /// title matching covers that case separately.
    private static func significantTokens(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        for part in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(part)
            if token.count >= 4, !recallStopwords.contains(token) {
                tokens.insert(token)
            }
        }
        return tokens
    }

    private static let recallStopwords: Set<String> = [
        "this", "that", "with", "from", "into", "your", "their", "about",
        "when", "then", "than", "they", "them", "have", "will", "would",
        "should", "could", "what", "which", "where", "while", "these",
        "those", "before", "after", "turn", "tool", "tools", "agent",
        "memory", "skill", "skills"
    ]
}
