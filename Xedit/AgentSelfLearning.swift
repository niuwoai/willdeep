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

enum AgentLearningEventKind: String, Codable, Equatable {
    case memory
    case skill
    case mcpSuggestion
}

enum AgentLearningEventStatus: String, Codable, Equatable {
    case saved
    case created
    case suggested
    case skipped
    case failed
}

enum AgentLearningActionKind: String, Codable, Equatable {
    case saveMemory
    case createSkill
    case proposeSkill
    case searchMCP
    case suggestMCPInstall
}

struct AgentLearningSkillDraft: Codable, Equatable {
    var name: String
    var description: String
    var body: String
}

struct AgentLearningMCPDraft: Codable, Equatable {
    var capability: String
    var serverName: String
    var installHint: String?
    var searchQuery: String?
    var reason: String
}

struct AgentLearningAction: Codable, Equatable {
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

struct AgentLearningEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: AgentLearningEventKind
    var status: AgentLearningEventStatus
    var title: String
    var detail: String
    var action: AgentLearningAction?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AgentLearningEventKind,
        status: AgentLearningEventStatus,
        title: String,
        detail: String,
        action: AgentLearningAction? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
        self.action = action
        self.createdAt = createdAt
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
        let scope = parseScope(arguments["scope"]?.stringValue())
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
            payload: "Created user skill at \(url.path). Refresh skills or type @ to attach it in a future turn."
        )
    }

    static func auditTurn(
        for runtime: AgentRuntime,
        workspaceURL: URL?,
        skillSettings: AgentSkillSettings = AgentSkillSettingsStore.load().normalized
    ) -> AgentSelfLearningAudit? {
        guard let latestUser = runtime.messages.last(where: { $0.role == .user }) else {
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
        let calls = runtime.toolCalls.filter { relevantAssistantIDs.contains($0.messageID) }
        let memoryContents = automaticSelfLearningMemories(from: evidenceText)
        let mcpSuggestion = automaticMCPSuggestion(from: evidenceText)
        let explicitSkillDirective = containsExplicitSkillCreationSignal(evidenceText)
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
        guard !memories.isEmpty else { return [] }

        let scope: AgentMemoryScope = workspaceURL == nil ? .global : .project
        let existingIDs = Set(memoryState.memories.map(\.id))
        for memory in memories {
            memoryState.addMemory(
                content: memory,
                source: .automatic,
                lifetime: .longTerm,
                scope: scope,
                rootDirectory: workspaceURL
            )
        }
        memoryState.mergeDuplicateMemories()
        let savedMemories = memoryState.memories.filter { !existingIDs.contains($0.id) }
        var events: [AgentLearningEvent] = []
        if !savedMemories.isEmpty {
            let preview = savedMemories
                .prefix(3)
                .map { "- \(oneLine($0.content, limit: 180))" }
                .joined(separator: "\n")
            events.append(AgentLearningEvent(
                kind: .memory,
                status: .saved,
                title: "Saved \(savedMemories.count) automatic learning memor\(savedMemories.count == 1 ? "y" : "ies")",
                detail: preview,
                action: AgentLearningAction(
                    kind: .saveMemory,
                    commandName: "add_memory",
                    target: scope == .global ? "global memory" : "project memory",
                    reason: "The turn contained durable self-learning policy or integration guidance.",
                    nextStep: "Retrieve this memory before future turns that mention learning, skills, MCP, or external integrations."
                )
            ))
        }
        if let mcpSuggestion = audit.mcpSuggestion {
            events.append(AgentLearningEvent(
                kind: .mcpSuggestion,
                status: .suggested,
                title: "Suggested MCP discovery for \(mcpSuggestion.capability)",
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
                    nextStep: "Run search_mcp_servers, review candidates, then ask the user before installing or adding credentials.",
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
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) -> [AgentLearningEvent] {
        let settings = AgentSkillSettingsStore.load().normalized
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
                    title: "Skipped automatic skill creation",
                    detail: [
                        "Reusable-workflow signal was present, but this turn only had \(audit.relevantToolCallCount) relevant tool call(s). Minimum required: \(settings.minimumToolCallCount).",
                        "Source: \(skillSourceSummary(for: audit))"
                    ].joined(separator: "\n"),
                    action: AgentLearningAction(
                        kind: .proposeSkill,
                        commandName: "create_user_skill",
                        reason: "The turn mentioned reusable skills, but there was not enough executed tool evidence to safely create one.",
                        nextStep: "Wait for a completed multi-tool workflow, or explicitly ask to create a skill from this lighter evidence."
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
                    title: "Created user skill \(url.deletingLastPathComponent().lastPathComponent)",
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
                        nextStep: "Future turns can discover this skill through list_skills or attach it from the skill picker."
                    )
                )
            ]
        } catch AgentSkillFileError.alreadyExists(let slug) {
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .skipped,
                    title: "Skipped existing user skill \(slug)",
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
                        reason: "A reusable workflow was detected, but the matching skill already exists.",
                        nextStep: "Reuse or manually edit the existing skill instead of overwriting it."
                    )
                )
            ]
        } catch {
            return [
                AgentLearningEvent(
                    kind: .skill,
                    status: .failed,
                    title: "Automatic skill creation failed",
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
                        reason: "A reusable workflow was detected, but writing the user skill failed.",
                        nextStep: "Review the error, fix local skill storage access, then retry if the workflow is still useful.",
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
        let evidenceText = userText + "\n\n" + assistantText
        let explicitSkillDirective = containsExplicitSkillCreationSignal(evidenceText)
        guard containsReusableWorkflowSignal(evidenceText) || explicitSkillDirective else { return nil }

        let requiredToolCalls = explicitSkillDirective
            ? max(2, min(settings.minimumToolCallCount, 3))
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

    static func automaticMCPCapabilityGapMemory(from text: String) -> String? {
        let lower = text.lowercased()
        let mentionsExternalCapability = [
            "mcp", "connector", "plugin", "integration", "external system",
            "连接器", "插件", "外部系统", "集成", "第三方"
        ].contains { lower.contains($0) }
        let mentionsLearning = [
            "memory", "skill", "自学习", "记忆", "技能"
        ].contains { lower.contains($0) }
        let asksForProactivity = [
            "自动", "自主", "必要", "建议", "安装", "搜索", "以后", "下次",
            "proactive", "suggest", "install", "search", "when needed"
        ].contains { lower.contains($0) }
        guard (mentionsExternalCapability || mentionsLearning) && asksForProactivity else {
            return nil
        }
        return "Agent should proactively save necessary memory, create reusable skills when workflows repeat, and search or suggest MCP servers when an external integration is missing; installing MCP servers or adding credentials still requires explicit user confirmation."
    }

    static func automaticSelfLearningMemories(from text: String) -> [String] {
        let lower = text.lowercased()
        var memories: [String] = []
        if let generalPolicy = automaticMCPCapabilityGapMemory(from: text) {
            appendUnique(generalPolicy, to: &memories)
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
        if let externalGap = automaticExternalIntegrationGapMemory(from: text) {
            appendUnique(externalGap, to: &memories)
        }
        return memories
    }

    static func automaticExternalIntegrationGapMemory(from text: String) -> String? {
        let lower = text.lowercased()
        let blocked = containsAny(
            [
                "cannot access", "can't access", "unable to access", "not configured",
                "not installed", "missing", "no configured", "unavailable",
                "无法访问", "不能访问", "没有配置", "未配置", "缺少", "不可用", "需要用户手动"
            ],
            in: lower
        )
        guard blocked, let capability = detectedExternalCapability(in: lower) else { return nil }
        return "When a task needs \(capability) and the current harness lacks a configured tool, Agent should list configured MCP servers, search MCP candidates, and suggest a user-approved MCP install/configuration before asking the user to handle discovery manually."
    }

    static func automaticMCPSuggestion(from text: String) -> AgentSelfLearningMCPSuggestion? {
        let lower = text.lowercased()
        let blocked = containsAny(
            [
                "cannot access", "can't access", "unable to access", "not configured",
                "not installed", "missing", "no configured", "unavailable",
                "无法访问", "不能访问", "没有配置", "未配置", "缺少", "不可用", "需要用户手动"
            ],
            in: lower
        )
        if blocked, let capability = detectedExternalCapability(in: lower) {
            return mcpSuggestion(
                capability: capability,
                ecosystem: capability,
                reason: "The turn indicated \(capability) access is needed but no configured integration is available."
            )
        }

        let asksForMCPDiscovery = containsAny(
            ["mcp", "connector", "plugin", "连接器", "插件", "外部系统", "集成"],
            in: lower
        ) && containsAny(
            ["搜索", "建议", "安装", "必要", "缺少", "search", "suggest", "install", "missing", "when needed"],
            in: lower
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

    private static func parseScope(_ raw: String?) -> AgentMemoryScope {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "project", "workspace":
            return .project
        default:
            return .global
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
}
