//
//  AgentSelfLearningTests.swift
//  WillDeepTests
//
//  Covers Agent self-learning tools for memory, skills, and MCP suggestions.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentSelfLearningTests {
    @Test
    func addMemoryToolStoresAutomaticProjectMemory() throws {
        let root = URL(fileURLWithPath: "/tmp/WillDeepProject")
        let state = AgentMemoryState(settings: .default, memories: [])

        let result = try AgentSelfLearning.addMemory(
            arguments: [
                "content": .string("这个项目默认用 yarn 运行测试和构建。"),
                "scope": .string("project"),
                "lifetime": .string("longTerm")
            ],
            rootDirectory: root,
            state: state
        )

        let memory = try #require(state.memories.first)
        #expect(result.summary.contains("Project") || result.summary.contains("project"))
        #expect(memory.source == .automatic)
        #expect(memory.scope == .project)
        #expect(memory.projectFingerprint == AgentMemoryEngine.projectFingerprint(for: root))
        #expect(memory.content.contains("yarn"))
    }

    @Test
    func createUserSkillToolWritesSanitizedSkill() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let result = try AgentSelfLearning.createUserSkill(
            arguments: [
                "name": .string("release-checklist"),
                "description": .string("Use before shipping a release."),
                "body": .string("Run tests and never expose api_key=sk-abcdefghijklmnop.")
            ],
            root: root
        )

        let skillURL = root
            .appendingPathComponent("release-checklist")
            .appendingPathComponent("SKILL.md")
        let body = try String(contentsOf: skillURL, encoding: .utf8)

        #expect(result.summary.contains("release-checklist"))
        #expect(body.contains("name: release-checklist"))
        #expect(body.contains("[REDACTED_SECRET]"))
        #expect(!body.contains("sk-abcdefghijklmnop"))
    }

    @Test
    func suggestMCPServerToolRecordsCapabilityGapMemory() throws {
        let root = URL(fileURLWithPath: "/tmp/WillDeepProject")
        let state = AgentMemoryState(settings: .default, memories: [])

        let result = try AgentSelfLearning.suggestMCPServer(
            arguments: [
                "capability": .string("GitHub PR review thread inspection"),
                "server_name": .string("github-mcp-server"),
                "install_hint": .string("Search official GitHub MCP setup before installing."),
                "reason": .string("Needed to inspect unresolved review comments without asking the user to paste them.")
            ],
            rootDirectory: root,
            state: state
        )

        let memory = try #require(state.memories.first)
        #expect(result.payload.contains("github-mcp-server"))
        #expect(memory.scope == .project)
        #expect(memory.content.contains("GitHub PR review thread inspection"))
        #expect(memory.content.contains("Do not assume this MCP is installed"))
    }

    @Test
    func searchMCPServersDryRunReturnsQueryAndGuidance() async throws {
        let result = try await AgentSelfLearning.searchMCPServers(arguments: [
            "capability": .string("GitHub PR review thread inspection"),
            "ecosystem": .string("GitHub"),
            "dry_run": .bool(true)
        ])

        #expect(result.summary.contains("MCP search"))
        #expect(result.payload.contains("Search query:"))
        #expect(result.payload.contains("Model Context Protocol"))
        #expect(result.payload.contains("suggest_mcp_server"))
        #expect(result.payload.contains("list_mcp_servers"))
    }

    @Test
    func automaticMCPCapabilityGapEmitsPendingDraftEvents() throws {
        // rc16:turn-end 不再把 memory 直接落盘。改成断言「事件携带 pending
        // memoryDrafts + status == .suggested,memory store 不被动过」。
        let root = URL(fileURLWithPath: "/tmp/WillDeepProject")
        let state = AgentMemoryState(settings: .default, memories: [])
        let user = AgentMessage(
            role: .user,
            content: "以后遇到缺少外部系统集成时，要自动搜索并建议安装 MCP；必要时也要自动添加 memory 和 skill。"
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "明白，我会把这个作为 harness 自学习策略处理。"
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))

        let events = AgentSelfLearning.captureAutomaticMCPCapabilityGap(
            for: runtime,
            memoryState: state,
            workspaceURL: root
        )

        // 关键回归:memory store 保持空的,什么都没有偷偷写进去。
        #expect(state.memories.isEmpty)
        // 事件里应该有一条 `.memory / .suggested`,带着 draft。
        let memoryEvent = try #require(events.first { $0.kind == .memory })
        #expect(memoryEvent.status == .suggested)
        #expect(memoryEvent.action?.requiresUserConfirmation == true)
        let drafts = memoryEvent.pendingMemoryDrafts
        #expect(!drafts.isEmpty)
        #expect(drafts.allSatisfy { $0.scope == .project })
        #expect(drafts.contains { $0.content.contains("add_memory") })
        #expect(drafts.contains { $0.content.contains("create_user_skill") })
        #expect(drafts.contains { $0.content.contains("Search query:") })
        // MCP suggestion 事件本来就是 .suggested,保留不变。
        #expect(events.contains { $0.kind == .mcpSuggestion && $0.detail.contains("Search query:") })
        let mcpEvent = try #require(events.first { $0.kind == .mcpSuggestion })
        #expect(mcpEvent.action?.kind == .suggestMCPInstall)
        #expect(mcpEvent.action?.commandName == "suggest_mcp_server")
        #expect(mcpEvent.action?.mcpDraft?.serverName.contains("mcp") == true)
        #expect(mcpEvent.action?.mcpDraft?.searchQuery == mcpEvent.action?.searchQuery)
        #expect(mcpEvent.action?.requiresUserConfirmation == true)
        #expect(mcpEvent.detail.contains("Source:"))
    }

    @Test
    func automaticSelfLearningMemoriesSplitMemorySkillAndMCPPolicy() {
        // rc16:matcher 现在需要先过「strong durable intent」闸 —— 测试
        // 文本前面补一句「以后请」,代表用户明确表达持久化偏好,符合
        // 真实触发条件。原文本作为弱信号在新阈值下应该被过滤掉,这才
        // 是想要的行为。
        let memories = AgentSelfLearning.automaticSelfLearningMemories(
            from: "以后请实现自学习：自动地添加必要的 memory，自主地添加必要的 skill，必要时搜索和建议安装 mcp。"
        )

        #expect(memories.contains { $0.contains("add_memory") })
        #expect(memories.contains { $0.contains("create_user_skill") })
        #expect(memories.contains { $0.contains("MCP") && $0.contains("search") })
    }

    @Test
    func automaticSelfLearningMemoriesSkippedWithoutStrongIntent() {
        // rc16:没有 strong intent 词时,framework 那 3 条规则种子被门
        // 拦下来,不应该出现。externalGap memory 是另外一道闸,这条
        // 测试文本不包含「cannot access」之类,所以整体返回空。
        let memories = AgentSelfLearning.automaticSelfLearningMemories(
            from: "我们顺手聊聊 memory、skill 和 mcp 这几个概念,看看怎么用。"
        )
        #expect(memories.isEmpty)
    }

    @Test
    func automaticExternalIntegrationGapCreatesMCPDiscoveryMemory() throws {
        let memory = try #require(AgentSelfLearning.automaticExternalIntegrationGapMemory(
            from: "I cannot access GitHub pull request review threads because no configured integration is available."
        ))

        #expect(memory.contains("GitHub"))
        #expect(memory.contains("list configured MCP servers"))
        #expect(memory.contains("suggest a user-approved MCP"))
    }

    @Test
    func automaticMCPSuggestionProducesConcreteSearchQuery() throws {
        let suggestion = try #require(AgentSelfLearning.automaticMCPSuggestion(
            from: "I cannot access GitHub pull request review threads because no configured integration is available."
        ))

        #expect(suggestion.capability == "GitHub")
        #expect(suggestion.searchQuery.contains("GitHub"))
        #expect(suggestion.searchQuery.contains("MCP server"))
        #expect(suggestion.reason.contains("no configured integration"))
    }

    @Test
    func legacyDefaultSkillThresholdMigratesToThreeTools() throws {
        let defaults = UserDefaults.standard
        let settingsKey = "com.willdeep.agentSkillSettings.v1"
        let migrationKey = "com.willdeep.agentSkillSettings.defaultThreshold.rc85"
        let previousSettings = defaults.data(forKey: settingsKey)
        let previousMigration = defaults.object(forKey: migrationKey)
        defer {
            if let previousSettings {
                defaults.set(previousSettings, forKey: settingsKey)
            } else {
                defaults.removeObject(forKey: settingsKey)
            }
            if let previousMigration {
                defaults.set(previousMigration, forKey: migrationKey)
            } else {
                defaults.removeObject(forKey: migrationKey)
            }
        }

        let oldDefault = AgentSkillSettings(
            autoExtractionEnabled: true,
            minimumToolCallCount: 5,
            disabledSkillIdentifiers: []
        )
        let data = try JSONEncoder().encode(oldDefault)
        defaults.set(data, forKey: settingsKey)
        defaults.removeObject(forKey: migrationKey)

        let migrated = AgentSkillSettingsStore.load()

        #expect(migrated.minimumToolCallCount == 3)
    }

    @Test
    func explicitCustomSkillThresholdIsPreservedDuringMigration() throws {
        let defaults = UserDefaults.standard
        let settingsKey = "com.willdeep.agentSkillSettings.v1"
        let migrationKey = "com.willdeep.agentSkillSettings.defaultThreshold.rc85"
        let previousSettings = defaults.data(forKey: settingsKey)
        let previousMigration = defaults.object(forKey: migrationKey)
        defer {
            if let previousSettings {
                defaults.set(previousSettings, forKey: settingsKey)
            } else {
                defaults.removeObject(forKey: settingsKey)
            }
            if let previousMigration {
                defaults.set(previousMigration, forKey: migrationKey)
            } else {
                defaults.removeObject(forKey: migrationKey)
            }
        }

        let customSetting = AgentSkillSettings(
            autoExtractionEnabled: true,
            minimumToolCallCount: 8,
            disabledSkillIdentifiers: []
        )
        let data = try JSONEncoder().encode(customSetting)
        defaults.set(data, forKey: settingsKey)
        defaults.removeObject(forKey: migrationKey)

        let migrated = AgentSkillSettingsStore.load()

        #expect(migrated.minimumToolCallCount == 8)
    }

    @Test
    func auditTurnSurfacesMemorySkillAndMCPCandidates() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_200)
        let user = AgentMessage(
            role: .user,
            content: "以后这类 GitHub PR 检查流程要自动沉淀 skill；如果没有 GitHub 集成，就搜索并建议 MCP。",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "我完成了读取、检查和验证。当前没有配置 GitHub integration。",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<3).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "audit-tool-\(index)",
                toolName: index == 0 ? "grep_files" : "run_command",
                arguments: [:],
                risk: index == 0 ? .read : .write,
                status: .succeeded,
                result: AgentToolResult(summary: "audit step \(index)", payload: "")
            )
        }

        let audit = try #require(AgentSelfLearning.auditTurn(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            skillSettings: .default
        ))

        #expect(audit.memoryContents.contains { $0.contains("create_user_skill") })
        #expect(audit.mcpSuggestion?.capability == "GitHub")
        #expect(audit.mcpSuggestion?.searchQuery.contains("Model Context Protocol") == true)
        #expect(audit.skillCandidate?.body.contains("Observed tool sequence") == true)
        #expect(audit.relevantToolCallCount == 3)
        #expect(audit.relevantToolNames == ["grep_files", "run_command"])
        #expect(audit.explicitSkillDirective)
    }

    @Test
    func automaticMemoryCandidatesUnderstandPreferenceWording() {
        let records = AgentMemoryEngine.candidates(
            fromUser: "我希望以后遇到 TLS 证书错误时，默认先自动重试 5 次。",
            assistantText: "明白，我会把这个偏好沉淀为后续执行策略。",
            rootDirectory: nil
        )

        #expect(records.contains { $0.content.contains("默认先自动重试 5 次") })
    }

    @Test
    func automaticSkillCandidateWritesReusableWorkflowSkill() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let user = AgentMessage(
            role: .user,
            content: "Next time this release workflow appears, create a reusable skill for it.",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "I inspected files, updated version docs, ran tests, and verified the release workflow.",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<5).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "tool-\(index)",
                toolName: index.isMultiple(of: 2) ? "read_file" : "run_command",
                arguments: [:],
                risk: index.isMultiple(of: 2) ? .read : .write,
                status: .succeeded,
                result: AgentToolResult(summary: "step \(index)", payload: "")
            )
        }

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            root: root
        )

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }

        #expect(skillFiles.count == 1)
        let body = try String(contentsOf: try #require(skillFiles.first), encoding: .utf8)
        #expect(body.contains("Observed tool sequence"))
        #expect(body.contains("run_command"))
        #expect(events.contains { $0.kind == .skill && $0.status == .created })
        let skillEvent = try #require(events.first { $0.kind == .skill })
        #expect(skillEvent.action?.kind == .createSkill)
        #expect(skillEvent.action?.commandName == "create_user_skill")
        #expect(skillEvent.action?.target?.hasPrefix("auto-") == true)
        #expect(skillEvent.detail.contains("Source:"))
        #expect(skillEvent.detail.contains("read_file"))
    }

    @Test
    func explicitSkillDirectiveAllowsThreeToolWorkflow() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let started = Date(timeIntervalSince1970: 1_800_000_100)
        let user = AgentMessage(
            role: .user,
            content: "请把这个三步检查流程沉淀成 skill，以后自动复用。",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "我完成了检查、修复和验证，这个流程可以复用。",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<3).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "explicit-tool-\(index)",
                toolName: index == 0 ? "search_files" : "run_command",
                arguments: [:],
                risk: index == 0 ? .read : .write,
                status: .succeeded,
                result: AgentToolResult(summary: "explicit step \(index)", payload: "")
            )
        }

        AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            root: root
        )

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }

        #expect(skillFiles.count == 1)
        let body = try String(contentsOf: try #require(skillFiles.first), encoding: .utf8)
        #expect(body.contains("Observed tool sequence"))
        #expect(body.contains("explicit step 2"))
    }

    @Test
    func defaultReusableWorkflowThresholdIsThreeTools() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let settingsKey = "com.willdeep.agentSkillSettings.v1"
        let previousSettings = UserDefaults.standard.data(forKey: settingsKey)
        defer {
            if let previousSettings {
                UserDefaults.standard.set(previousSettings, forKey: settingsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: settingsKey)
            }
        }
        AgentSkillSettingsStore.save(.default)

        let started = Date(timeIntervalSince1970: 1_800_000_300)
        let user = AgentMessage(
            role: .user,
            content: "Next time this artifact verification workflow appears, reuse this workflow.",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "I inspected the workspace, generated the artifact, and verified the result.",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<3).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "default-tool-\(index)",
                toolName: index == 0 ? "read_file" : "run_command",
                arguments: [:],
                risk: index == 0 ? .read : .write,
                status: .succeeded,
                result: AgentToolResult(summary: "default step \(index)", payload: "")
            )
        }

        AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            root: root
        )

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }

        #expect(AgentSkillSettings.default.minimumToolCallCount == 3)
        #expect(skillFiles.count == 1)
        let body = try String(contentsOf: try #require(skillFiles.first), encoding: .utf8)
        #expect(body.contains("default step 2"))
    }

    @Test
    func automaticSkillCandidateSkippedEventExplainsLowEvidence() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let started = Date(timeIntervalSince1970: 1_800_000_400)
        let user = AgentMessage(
            role: .user,
            content: "请把这个检查流程沉淀成 skill，以后自动复用。",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "我只完成了一个读取动作，还没有足够的多步证据。",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = [
            AgentToolCall(
                messageID: assistant.id,
                externalID: "low-evidence-tool",
                toolName: "read_file",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "read one file", payload: "")
            )
        ]

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            root: root
        )

        #expect(events.contains { $0.kind == .skill && $0.status == .skipped })
        #expect(events.contains { $0.detail.contains("Minimum required") })
        let skippedEvent = try #require(events.first { $0.kind == .skill })
        #expect(skippedEvent.action?.kind == .proposeSkill)
        #expect(skippedEvent.action?.commandName == "create_user_skill")
    }

    @Test
    func disabledAutomaticSkillExtractionPreservesSkillDraft() throws {
        let defaults = UserDefaults.standard
        let settingsKey = "com.willdeep.agentSkillSettings.v1"
        let previous = defaults.data(forKey: settingsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: settingsKey)
            } else {
                defaults.removeObject(forKey: settingsKey)
            }
        }

        let disabled = AgentSkillSettings(
            autoExtractionEnabled: false,
            minimumToolCallCount: 2,
            disabledSkillIdentifiers: []
        )
        defaults.set(try JSONEncoder().encode(disabled), forKey: settingsKey)

        let user = AgentMessage(role: .user, content: "以后把这个发布流程沉淀成一个 skill。")
        let assistant = AgentMessage(role: .assistant, content: "我先跑测试，再检查产物，再准备发布说明。")
        let session = AgentSession(messages: [user, assistant])
        let runtime = AgentRuntime(session: session)
        let assistantID = try #require(runtime.messages.last { $0.role == .assistant }?.id)
        runtime.toolCalls = [
            AgentToolCall(
                messageID: assistantID,
                externalID: "tool-1",
                toolName: "run_command",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "ran tests", payload: "")
            ),
            AgentToolCall(
                messageID: assistantID,
                externalID: "tool-2",
                toolName: "read_file",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "checked artifacts", payload: "")
            )
        ]

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject")
        )

        let event = try #require(events.first)
        #expect(event.status == .skipped)
        #expect(event.action?.skillDraft?.name.contains("auto-") == true)
        #expect(event.action?.skillDraft?.body.contains("Observed tool sequence") == true)
    }

    @Test
    func sessionPersistsLearningEvents() throws {
        let event = AgentLearningEvent(
            kind: .mcpSuggestion,
            status: .suggested,
            title: "Suggested MCP discovery for GitHub",
            detail: "Search query: GitHub MCP server",
            action: AgentLearningAction(
                kind: .suggestMCPInstall,
                commandName: "suggest_mcp_server",
                target: "GitHub",
                searchQuery: "GitHub MCP server",
                mcpDraft: AgentLearningMCPDraft(
                    capability: "GitHub",
                    serverName: "github-mcp",
                    installHint: "https://example.com/mcp/github",
                    searchQuery: "GitHub MCP server",
                    reason: "Need GitHub review thread access."
                ),
                reason: "Need GitHub review thread access.",
                nextStep: "Ask before installing.",
                requiresUserConfirmation: true
            )
        )
        let session = AgentSession(
            title: "Learning",
            messages: [],
            learningEvents: [event]
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

        #expect(decoded.learningEvents == [event])
    }

    @Test
    func learningEventDecodesLegacyRecordsWithoutAction() throws {
        let legacyJSON = """
        {
          "id": "6C02593A-48BC-44F4-A05A-45E54E14D387",
          "kind": "memory",
          "status": "saved",
          "title": "Saved 1 automatic learning memory",
          "detail": "- User prefers yarn.",
          "createdAt": 1800000500
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))

        let event = try JSONDecoder().decode(AgentLearningEvent.self, from: data)

        #expect(event.kind == .memory)
        #expect(event.action == nil)
    }

    @Test
    func learningReviewStoreEnqueuesAndDeduplicatesEvents() throws {
        let suiteName = "com.willdeep.tests.learningReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AgentLearningReviewStore._setTestDefaultsOverride(defaults)
        defer {
            AgentLearningReviewStore._setTestDefaultsOverride(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let createdAt = Date(timeIntervalSince1970: 1_800_000_500)
        let sessionID = try #require(UUID(uuidString: "8A3F2082-D799-4E25-A17B-14B46D365B93"))
        let event = AgentLearningEvent(
            id: try #require(UUID(uuidString: "6C02593A-48BC-44F4-A05A-45E54E14D387")),
            kind: .mcpSuggestion,
            status: .suggested,
            title: "Suggested MCP discovery for GitHub",
            detail: "Search query: GitHub MCP server",
            createdAt: createdAt
        )
        let repeatedEvent = AgentLearningEvent(
            kind: .mcpSuggestion,
            status: .suggested,
            title: event.title,
            detail: event.detail,
            createdAt: createdAt.addingTimeInterval(10)
        )

        AgentLearningReviewStore.enqueue(events: [event], sessionID: sessionID)
        AgentLearningReviewStore.enqueue(events: [event, repeatedEvent], sessionID: sessionID)

        let items = AgentLearningReviewStore.load()
        #expect(items.count == 1)
        #expect(items.first?.event == event)
        #expect(items.first?.decision == .pending)
        #expect(items.first?.sessionID == sessionID)
    }

    @Test
    func learningReviewStoreMarksAndClearsReviewedItems() throws {
        let suiteName = "com.willdeep.tests.learningReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AgentLearningReviewStore._setTestDefaultsOverride(defaults)
        defer {
            AgentLearningReviewStore._setTestDefaultsOverride(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved 1 automatic learning memory",
            detail: "- User prefers yarn."
        )

        AgentLearningReviewStore.enqueue(events: [event], sessionID: nil)
        AgentLearningReviewStore.mark(id: event.id, decision: .reviewed)

        let reviewedItem = try #require(AgentLearningReviewStore.load().first)
        #expect(reviewedItem.decision == .reviewed)
        #expect(reviewedItem.reviewedAt != nil)

        AgentLearningReviewStore.clearReviewed()
        #expect(AgentLearningReviewStore.load().isEmpty)
    }

    @Test
    func learningReviewStoreUpdatesSkillDraftContent() throws {
        let suiteName = "com.willdeep.tests.learningReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AgentLearningReviewStore._setTestDefaultsOverride(defaults)
        defer {
            AgentLearningReviewStore._setTestDefaultsOverride(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let event = AgentLearningEvent(
            kind: .skill,
            status: .suggested,
            title: "Skill candidate",
            detail: "Reusable workflow candidate.\nDraft skill: release-checklist",
            action: AgentLearningAction(
                kind: .proposeSkill,
                commandName: "create_user_skill",
                target: "release-checklist",
                skillDraft: AgentLearningSkillDraft(
                    name: "release-checklist",
                    description: "Use before shipping a release.",
                    body: "Run tests and verify artifacts."
                ),
                reason: "The workflow repeated across multiple tool calls."
            )
        )

        AgentLearningReviewStore.enqueue(events: [event], sessionID: nil)
        AgentLearningReviewStore.updateSkillDraft(
            id: event.id,
            draft: AgentLearningSkillDraft(
                name: "release-ready-checklist",
                description: "Use before cutting a release.",
                body: "Run tests, verify artifacts, and confirm changelog updates."
            )
        )

        let item = try #require(AgentLearningReviewStore.load().first)
        #expect(item.event.action?.target == "release-ready-checklist")
        #expect(item.event.action?.skillDraft?.name == "release-ready-checklist")
        #expect(item.event.action?.skillDraft?.description == "Use before cutting a release.")
        #expect(item.event.action?.skillDraft?.body.contains("confirm changelog updates") == true)
        #expect(item.event.detail.contains("Draft skill: release-ready-checklist"))
    }

    // MARK: - Recall ↔ learning linkage

    @Test
    func relatedRecallLinksMatchOnSharedKeywords() {
        let memoryItem = AgentTurnRecallItem(
            kind: .memory,
            title: "Deployment rollback must back up the running build first",
            detail: "Project memory"
        )
        let snapshot = AgentTurnRecallSnapshot(
            createdAt: Date(),
            query: "deployment",
            items: [memoryItem]
        )
        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved automatic learning memory",
            detail: "Captured deployment rollback policy for future releases."
        )

        let links = AgentSelfLearning.relatedRecallLinks(for: event, in: snapshot)
        #expect(links.count == 1)
        let link = links.first
        #expect(link?.id == memoryItem.id)
        #expect(link?.kind == .memory)
        // 2 shared keywords → 0.5 → "related" band, reason names them.
        #expect(link?.score == 0.5)
        #expect(link?.strength == .related)
        #expect(link?.reason?.contains("deployment") == true)
    }

    @Test
    func relatedRecallLinksMatchOnVerbatimSkillTitle() {
        let skillItem = AgentTurnRecallItem(
            kind: .skill,
            title: "deep-research",
            detail: "Fan-out web research harness.",
            reasons: ["Attached via @skill for this turn."]
        )
        let snapshot = AgentTurnRecallSnapshot(
            createdAt: Date(),
            query: "research",
            items: [skillItem]
        )
        // Few shared keywords, but the attached skill's identifier appears
        // verbatim — the strong-match path should still link it.
        let event = AgentLearningEvent(
            kind: .skill,
            status: .suggested,
            title: "Proposed formalizing the deep-research workflow as a skill",
            detail: ""
        )

        let links = AgentSelfLearning.relatedRecallLinks(for: event, in: snapshot)
        #expect(links.map(\.id) == [skillItem.id])
        // Verbatim title match is the strongest signal.
        #expect(links.first?.score == 0.9)
        #expect(links.first?.strength == .strong)
        #expect(links.first?.reason == L10n.Transcript.learningRecallReasonTitle(skillItem.title))
    }

    @Test
    func relatedRecallLinksSortStrongestFirst() {
        let skillItem = AgentTurnRecallItem(kind: .skill, title: "deep-research", detail: "Web research harness.")
        let memoryItem = AgentTurnRecallItem(kind: .memory, title: "Deployment rollback safety net", detail: "Project memory")
        let snapshot = AgentTurnRecallSnapshot(
            createdAt: Date(),
            query: "research",
            items: [memoryItem, skillItem]
        )
        // Verbatim "deep-research" (strong) + deployment/rollback keyword
        // overlap with the memory item (related).
        let event = AgentLearningEvent(
            kind: .skill,
            status: .suggested,
            title: "Proposed deep-research skill after deployment rollback work",
            detail: ""
        )

        let links = AgentSelfLearning.relatedRecallLinks(for: event, in: snapshot)
        #expect(links.count == 2)
        #expect(links.first?.id == skillItem.id)
        #expect(links.first?.strength == .strong)
        #expect(links.last?.id == memoryItem.id)
        #expect((links.first?.score ?? 0) > (links.last?.score ?? 0))
    }

    @Test
    func relatedRecallLinksFoldInRetrievalScore() {
        // Same 2-keyword overlap (match base 0.5) but the memory carries a
        // high retrieval score → blended 0.5*0.7 + 0.9*0.3 = 0.62.
        let memoryItem = AgentTurnRecallItem(
            kind: .memory,
            title: "Deployment rollback must back up the running build",
            detail: "Project memory",
            score: 0.9
        )
        let snapshot = AgentTurnRecallSnapshot(createdAt: Date(), query: "deployment", items: [memoryItem])
        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved automatic learning memory",
            detail: "Captured deployment rollback policy for future releases."
        )

        let link = AgentSelfLearning.relatedRecallLinks(for: event, in: snapshot).first
        #expect(link?.score == 0.62)
        #expect(link?.strength == .related)
        #expect(link?.reason?.contains("0.90") == true)
    }

    @Test
    func recallItemLinkStatusReportsLinkedNearMissAndUnrelated() {
        let item = AgentTurnRecallItem(kind: .memory, title: "Deployment guide", detail: "Project memory")

        // Linked: an event whose relatedRecall already references the item.
        let linkedEvent = AgentLearningEvent(
            kind: .memory, status: .saved, title: "Saved memory", detail: "",
            relatedRecall: [AgentLearningRecallLink(id: item.id, kind: .memory, title: item.title)]
        )
        #expect(AgentSelfLearning.recallItemLinkStatus(item, events: [linkedEvent]) == .linked)

        // Near miss: shares exactly one keyword ("deployment"), below ≥2.
        let nearEvent = AgentLearningEvent(
            kind: .memory, status: .saved, title: "Saved memory",
            detail: "Captured deployment policy notes."
        )
        if case .nearMiss(let reason) = AgentSelfLearning.recallItemLinkStatus(item, events: [nearEvent]) {
            #expect(reason.contains("deployment"))
        } else {
            Issue.record("expected a near-miss status")
        }

        // Unrelated: no shared keywords.
        let unrelatedEvent = AgentLearningEvent(
            kind: .memory, status: .saved, title: "Saved memory",
            detail: "Rename selected variables inside the editor."
        )
        #expect(AgentSelfLearning.recallItemLinkStatus(item, events: [unrelatedEvent]) == .unrelated)
    }

    @Test
    func recallUtilizationTalliesLinkedNearMissAndUnused() {
        let linkedItem = AgentTurnRecallItem(kind: .memory, title: "Deployment guide", detail: "Project memory")
        let nearItem = AgentTurnRecallItem(kind: .memory, title: "Rollback checklist", detail: "Project memory")
        let unusedItem = AgentTurnRecallItem(kind: .skill, title: "github-pr", detail: "Review helper.")
        let snapshot = AgentTurnRecallSnapshot(
            createdAt: Date(),
            query: "deployment",
            items: [linkedItem, nearItem, unusedItem]
        )
        let events = [
            AgentLearningEvent(
                kind: .memory, status: .saved, title: "Saved memory",
                detail: "Captured rollback policy notes.",
                relatedRecall: [AgentLearningRecallLink(id: linkedItem.id, kind: .memory, title: linkedItem.title)]
            )
        ]

        let u = AgentSelfLearning.recallUtilization(in: snapshot, events: events)
        #expect(u.hasLearning)
        #expect(u.linked == 1)   // linkedItem via relatedRecall
        #expect(u.nearMiss == 1) // nearItem shares only "rollback"
        #expect(u.unused == 1)   // github-pr shares nothing
        #expect(u.total == 3)
    }

    @Test
    func recallUtilizationFlagsNoLearningTurn() {
        let snapshot = AgentTurnRecallSnapshot(
            createdAt: Date(),
            query: "deployment",
            items: [AgentTurnRecallItem(kind: .memory, title: "Deployment guide", detail: "Project memory")]
        )
        let u = AgentSelfLearning.recallUtilization(in: snapshot, events: [])
        #expect(u.hasLearning == false)
        #expect(u.unused == 1)
        #expect(u.linked == 0)
    }

    @Test
    func relatedRecallLinksEmptyWhenNoOverlap() {
        let snapshot = AgentTurnRecallSnapshot(
            createdAt: Date(),
            query: "github",
            items: [
                AgentTurnRecallItem(kind: .memory, title: "Prefer GitHub pull request reviews", detail: "Global memory")
            ]
        )
        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved automatic learning memory",
            detail: "Rename selected variables inside the editor buffer."
        )

        #expect(AgentSelfLearning.relatedRecallLinks(for: event, in: snapshot).isEmpty)
    }

    @Test
    func relatedRecallLinksEmptyForNilSnapshot() {
        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved automatic learning memory",
            detail: "Captured deployment rollback policy."
        )
        #expect(AgentSelfLearning.relatedRecallLinks(for: event, in: nil).isEmpty)
    }

    @Test
    func relatedRecallSummaryAppearsInCopyText() {
        let recallItem = AgentTurnRecallItem(
            kind: .memory,
            title: "Deployment rollback must back up the running build",
            detail: "Project memory"
        )
        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved automatic learning memory",
            detail: "Captured deployment rollback policy.",
            relatedRecall: [
                AgentLearningRecallLink(id: recallItem.id, kind: .memory, title: recallItem.title)
            ]
        )

        let summary = AgentLearningActionPresentation.relatedRecallSummary(for: event)
        #expect(summary?.contains("Deployment rollback") == true)
        #expect(AgentLearningActionPresentation.copyText(for: event).contains(L10n.Transcript.learningRelatedRecall("").trimmingCharacters(in: .whitespaces)))
    }

    private func temporarySkillRoot() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-self-learning-\(UUID().uuidString)")
        let root = container.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
