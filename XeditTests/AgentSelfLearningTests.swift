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
    func createUserSkillsToolCreatesOneValidatedBatch() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let skillsJSON = """
        [
          {
            "name": "release-guardian",
            "description": "Use before shipping a release.",
            "body": "Run the release checks and verify the artifact."
          },
          {
            "name": "incident-reviewer",
            "description": "Use after a production incident.",
            "body": "Collect evidence, identify causes, and verify follow-ups."
          }
        ]
        """

        let result = try AgentSelfLearning.createUserSkills(
            arguments: ["skills_json": .string(skillsJSON)],
            root: root
        )

        #expect(result.summary == "Created 2 user skills")
        #expect(result.payload.contains("release-guardian"))
        #expect(result.payload.contains("incident-reviewer"))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("release-guardian/SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("incident-reviewer/SKILL.md").path
        ))
    }

    @Test
    func createUserSkillsToolRejectsWholeBatchBeforeWriting() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let skillsJSON = """
        [
          {"name":"same skill","description":"First.","body":"First body."},
          {"name":"same-skill","description":"Second.","body":"Second body."}
        ]
        """

        #expect(throws: AgentToolError.self) {
            try AgentSelfLearning.createUserSkills(
                arguments: ["skills_json": .string(skillsJSON)],
                root: root
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("same-skill").path
        ))
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
        #expect(memoryEvent.title == L10n.Transcript.learningEventTitleSuggestedMemories(String(memoryEvent.pendingMemoryDrafts.count)))
        #expect(memoryEvent.detail.contains(L10n.Transcript.learningMemorySuggestionUse))
        #expect(memoryEvent.detail.contains(L10n.Transcript.learningMemorySuggestionAction))
        #expect(!memoryEvent.detail.contains(L10n.Transcript.learningNextStepApprovePopover))
        #expect(!memoryEvent.detail.contains(L10n.Transcript.learningReasonSelfLearningPolicy))
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
            fromUserText: "以后请实现自学习：自动地添加必要的 memory，自主地添加必要的 skill，必要时搜索和建议安装 mcp。"
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
            fromUserText: "我们顺手聊聊 memory、skill 和 mcp 这几个概念,看看怎么用。"
        )
        #expect(memories.isEmpty)
    }

    @Test
    func automaticMCPSuggestionProducesConcreteSearchQuery() throws {
        let suggestion = try #require(AgentSelfLearning.automaticMCPSuggestion(
            userText: "帮我看看这个 PR。",
            evidenceText: "I cannot access GitHub pull request review threads because no configured integration is available."
        ))

        #expect(suggestion.capability == "GitHub")
        #expect(suggestion.searchQuery.contains("GitHub"))
        #expect(suggestion.searchQuery.contains("MCP server"))
        #expect(suggestion.reason.contains("no configured integration"))
    }

    @Test
    func automaticMCPSuggestionIgnoresOrdinaryTroubleshootingChatter() {
        // rc12 回归:此前全文任意位置「缺少/missing」+ 任意位置能力词就
        // 触发建议——普通排障对话天天中招(用户实测截图:数据库运维会话
        // 蹦出"为 database access 建议 MCP 发现")。阻塞词、能力词、集成
        // 语境词现在必须同句共现。
        #expect(AgentSelfLearning.automaticMCPSuggestion(
            userText: "帮我在侧边栏终端里更新 tokenhub 实例到新版本。",
            evidenceText: "该表缺少一个索引。\n我建议先修复 MySQL 的慢查询,数据库压力会明显下降。"
        ) == nil)
        // 阻塞词和能力词分属两句 → 不触发。
        #expect(AgentSelfLearning.automaticMCPSuggestion(
            userText: "继续。",
            evidenceText: "当前环境没有配置这个工具。\nGitHub 的 PR 在另一个仓库里。"
        ) == nil)
        // assistant 提到"建议安装插件"不算用户要求 MCP 发现。
        #expect(AgentSelfLearning.automaticMCPSuggestion(
            userText: "好的。",
            evidenceText: "建议安装一个浏览器插件来做集成测试。"
        ) == nil)
    }

    @Test
    func automaticSelfLearningMemoriesIgnoreAssistantStylePhrasing() {
        // 框架规则族现在只认用户原话;这段典型的 assistant 措辞若被误当
        // 输入,闸门("以后")会开、规则会全触发——签名收紧后调用方只会
        // 传用户消息,这里守住"日常用户消息不触发"。
        let memories = AgentSelfLearning.automaticSelfLearningMemories(
            fromUserText: "我说的是在侧边栏终端中更新这个 tokenhub 的实例到 0.191.0-rc12 这个版本"
        )
        #expect(memories.isEmpty)
    }

    @Test
    func learningEventsDedupeWithinSession() {
        let event = AgentLearningEvent(
            kind: .mcpSuggestion,
            status: .suggested,
            title: "为 database access 建议 MCP 发现",
            detail: "Search query: database access MCP server"
        )
        var duplicate = event
        duplicate.id = UUID()

        let fresh = AgentSelfLearning.dedupedNewEvents([event, duplicate], existing: [])
        #expect(fresh.count == 1)

        let repeatNextTurn = AgentSelfLearning.dedupedNewEvents([duplicate], existing: [event])
        #expect(repeatNextTurn.isEmpty)

        let differentDetail = AgentLearningEvent(
            kind: .mcpSuggestion,
            status: .suggested,
            title: "为 database access 建议 MCP 发现",
            detail: "Search query: postgres MCP server"
        )
        #expect(AgentSelfLearning.dedupedNewEvents([differentDetail], existing: [event]).count == 1)
    }

    @Test
    func legacyDefaultSkillThresholdMigratesToSixTools() throws {
        let defaults = UserDefaults.standard
        let settingsKey = "com.willdeep.agentSkillSettings.v1"
        let migrationKey = "com.willdeep.agentSkillSettings.defaultThreshold.rc219"
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

        #expect(migrated.minimumToolCallCount == 6)
    }

    @Test
    func explicitCustomSkillThresholdIsPreservedDuringMigration() throws {
        let defaults = UserDefaults.standard
        let settingsKey = "com.willdeep.agentSkillSettings.v1"
        let migrationKey = "com.willdeep.agentSkillSettings.defaultThreshold.rc219"
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
        runtime.toolCalls = (0..<6).map { index in
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
        #expect(audit.relevantToolCallCount == 6)
        #expect(audit.relevantToolNames == ["grep_files", "run_command"])
        #expect(audit.explicitSkillDirective)
    }

    @Test
    func automaticMemoryCandidatesUnderstandPreferenceWording() {
        let records = AgentMemoryEngine.candidates(
            fromUser: "我希望以后遇到 TLS 证书错误时，默认先自动重试 5 次。",
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
            skillSettings: .default,
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
    func composerAttachmentPreludeCannotBecomeAutomaticSkill() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // 复刻 auto-the-user-attached-the 事故:composer 把前导头 + 附件
        // 技能的 description(自带 "Skill"/"自动"/"沉淀" 等触发词)拼进
        // content 本体,用户真正敲的只是一句和技能毫无关系的普通请求。
        // 修复前:整段拼接体被当成用户原话,explicit 信号命中,直接落盘
        // 一个名字取自前导文案前四个词的技能。
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let splicedContent = """
        \(AgentAttachedPromptProtocol.preludeHeader)

        ### Skill: swiftui-hang-diagnose
        > 诊断并修复 macOS/iOS 原生 Swift App 的主线程卡死、转圈,自动采样定位热点,沉淀成可复用技能流程。

        (skill body here)

        \(AgentAttachedPromptProtocol.userTextBoundary)
        帮我清理 q3 服务器的磁盘空间
        """
        let user = AgentMessage(role: .user, content: splicedContent, createdAt: started)
        let assistant = AgentMessage(
            role: .assistant,
            content: "确认磁盘已满,完成了占用画像与备份目录盘点。",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<8).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "tool-\(index)",
                toolName: "terminal_send_command",
                arguments: [:],
                risk: .write,
                status: .succeeded,
                result: AgentToolResult(summary: "step \(index)", payload: "")
            )
        }

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            skillSettings: .default,
            root: root
        )

        // 用户原话没有任何技能意图:不许产出任何技能事件,更不许落盘。
        #expect(events.isEmpty)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }
        #expect(skillFiles.isEmpty)
    }

    @Test
    func hostComposedTemplateGateBlocksContaminatedSkillCandidate() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // 兜底层:模板混在正文中段(不以前导头开头)时,反拼接不命中,
        // 门禁必须仍然拦住技能候选 —— 覆盖老会话落盘的 content 和未来
        // 反拼接不认识的新拼接形态。用户文本本身带显式技能意图 + 8 次
        // 工具调用,没有门禁就会直接落盘。
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let contaminated = """
        以后这类发布流程帮我自动沉淀成技能。
        \(AgentAttachedPromptProtocol.preludeHeader)
        ### Skill: legacy-attachment
        """
        let user = AgentMessage(role: .user, content: contaminated, createdAt: started)
        let assistant = AgentMessage(
            role: .assistant,
            content: "已按发布流程执行完毕。",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<8).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "tool-\(index)",
                toolName: "run_command",
                arguments: [:],
                risk: .write,
                status: .succeeded,
                result: AgentToolResult(summary: "step \(index)", payload: "")
            )
        }

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: nil,
            skillSettings: .default,
            root: root
        )

        // 允许出现 skipped/suggested 级别的提示事件,但绝不许创建技能文件。
        #expect(!events.contains { $0.status == .created })
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }
        #expect(skillFiles.isEmpty)

        // 门禁谓词本身:命中前导头或边界标记即拒绝;干净文本放行。
        #expect(AgentSelfLearning.containsHostComposedTemplate(contaminated))
        #expect(AgentSelfLearning.containsHostComposedTemplate(
            "text\n\(AgentAttachedPromptProtocol.userTextBoundary)\nmore"
        ))
        #expect(!AgentSelfLearning.containsHostComposedTemplate("帮我清理磁盘,以后沉淀成技能"))
    }

    @Test
    func explicitSkillDirectiveRequiresFourToolWorkflow() throws {
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
        runtime.toolCalls = (0..<4).map { index in
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
            skillSettings: .default,
            root: root
        )

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }

        #expect(skillFiles.count == 1)
        let body = try String(contentsOf: try #require(skillFiles.first), encoding: .utf8)
        #expect(body.contains("Observed tool sequence"))
        #expect(body.contains("explicit step 3"))
    }

    @Test
    func implicitReusableWorkflowBecomesReviewCandidateAtSixTools() throws {
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
            content: "以后每次遇到这类制品验证工作流，都复用这个流程。",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "I inspected the workspace, generated the artifact, and verified the result.",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<6).map { index in
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

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            skillSettings: .default,
            root: root
        )

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }

        #expect(AgentSkillSettings.default.minimumToolCallCount == 6)
        #expect(skillFiles.isEmpty)
        #expect(events.contains { $0.kind == .skill && $0.status == .suggested })
        #expect(events.first?.action?.requiresUserConfirmation == true)
    }

    @Test
    func assistantSkillNarrationCannotAuthorizeAutomaticCreation() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let started = Date(timeIntervalSince1970: 1_800_000_350)
        let user = AgentMessage(
            role: .user,
            content: "请修复通知太多的问题。",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "这个流程可以自动沉淀成 skill，以后复用。",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        runtime.toolCalls = (0..<8).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "narration-tool-\(index)",
                toolName: index.isMultiple(of: 2) ? "read_file" : "run_command",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "step \(index)", payload: "")
            )
        }

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            root: root
        )

        #expect(events.isEmpty)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFiles = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }
        #expect(skillFiles.isEmpty)
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
            ),
            AgentToolCall(
                messageID: assistantID,
                externalID: "tool-3",
                toolName: "search_files",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "found release files", payload: "")
            ),
            AgentToolCall(
                messageID: assistantID,
                externalID: "tool-4",
                toolName: "run_command",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "verified release", payload: "")
            )
        ]

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            skillSettings: disabled
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
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
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
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
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
    func openingLearningSuggestionsHidesOnlyReviewedItems() throws {
        let suiteName = "com.willdeep.tests.learningReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AgentLearningReviewStore._setTestDefaultsOverride(defaults)
        defer {
            AgentLearningReviewStore._setTestDefaultsOverride(nil)
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
        }

        let reviewed = AgentLearningEvent(
            kind: .memory,
            status: .suggested,
            title: "Review me once",
            detail: "Do not keep showing this suggestion."
        )
        let pending = AgentLearningEvent(
            kind: .mcpSuggestion,
            status: .suggested,
            title: "Still pending",
            detail: "This suggestion was not opened."
        )
        AgentLearningReviewStore.enqueue(events: [reviewed, pending], sessionID: nil)

        AgentLearningReviewStore.markReviewed(events: [reviewed])

        #expect(AgentLearningReviewStore.pendingEvents(from: [reviewed, pending]) == [pending])
        #expect(AgentLearningReviewStore.load().first(where: { $0.id == reviewed.id })?.decision == .reviewed)
        #expect(AgentLearningReviewStore.load().first(where: { $0.id == pending.id })?.decision == .pending)
    }

    @Test
    func learningReviewStoreExpiresOnlyUnhandledItemsAfterFifteenDays() throws {
        let suiteName = "com.willdeep.tests.learningReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AgentLearningReviewStore._setTestDefaultsOverride(defaults)
        defer {
            AgentLearningReviewStore._setTestDefaultsOverride(nil)
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
        }

        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let pendingEvent = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Pending automatic learning memory",
            detail: "Keep this only during the review window.",
            createdAt: createdAt
        )
        let reviewedEvent = AgentLearningEvent(
            kind: .skill,
            status: .suggested,
            title: "Reviewed skill candidate",
            detail: "Reviewed records are not pending expiration.",
            createdAt: createdAt
        )
        let reviewedItem = AgentLearningReviewItem(
            event: reviewedEvent,
            decision: .reviewed,
            createdAt: createdAt,
            updatedAt: createdAt,
            reviewedAt: createdAt
        )

        AgentLearningReviewStore.save(
            [AgentLearningReviewItem(event: pendingEvent), reviewedItem],
            now: createdAt
        )

        let justBeforeExpiration = createdAt.addingTimeInterval(
            AgentLearningReviewStore.pendingRetentionInterval - 1
        )
        #expect(AgentLearningReviewStore.load(now: justBeforeExpiration).count == 2)

        let expirationDate = createdAt.addingTimeInterval(
            AgentLearningReviewStore.pendingRetentionInterval
        )
        let remainingItems = AgentLearningReviewStore.load(now: expirationDate)
        #expect(remainingItems.map(\.id) == [reviewedItem.id])
        #expect(AgentLearningReviewStore.load(now: expirationDate) == remainingItems)
    }

    @Test
    func learningReviewStoreUpdatesSkillDraftContent() throws {
        let suiteName = "com.willdeep.tests.learningReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AgentLearningReviewStore._setTestDefaultsOverride(defaults)
        defer {
            AgentLearningReviewStore._setTestDefaultsOverride(nil)
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
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

    // MARK: - 1.238.1: host prompt scaffolding must not leak into learning

    /// 实录回归:用户只说 "hello",但消息挂着 per-turn 隐藏 host 指令
    /// (modelContext),其中 "never ask the user to confirm it" /
    /// "Prefer reversible repairs" 恰好命中 candidate marker 词。学习管线
    /// 若读 `modelContent`(= content + modelContext)就会把产品自己的
    /// 提示词拍成「记忆建议」——1.238.0 实测 "hello" 一句话弹出 2 条。
    private static let hostScaffoldingContext = """
    ## Turn context
    On each new user input, consider whether this title still describes the current task. \
    If it is stale or too generic, call suggest_session_title, then call rename_session. \
    The bounded local rename auto-applies without user approval, so never ask the user to confirm it.
    Once execution starts, continue as an unattended run. \
    Prefer reversible repairs and preserve unrelated changes.
    """

    @Test
    func operatorAuthoredContentExcludesHiddenHostContext() {
        let message = AgentMessage(
            role: .user,
            content: "hello",
            textAttachments: [AgentTextAttachment(content: "pasted spec text")],
            modelContext: Self.hostScaffoldingContext
        )
        let authored = message.operatorAuthoredContent
        // 用户敲的字和粘贴附件都在;host 注入一个字都不许出现。
        #expect(authored.contains("hello"))
        #expect(authored.contains("pasted spec text"))
        #expect(!authored.contains("never ask the user"))
        #expect(!authored.contains("reversible repairs"))
        // 无附件时退化为 content 本身。
        let bare = AgentMessage(role: .user, content: "hello", modelContext: Self.hostScaffoldingContext)
        #expect(bare.operatorAuthoredContent == "hello")
        // 对照:modelContent 确实携带注入文本(这是喂 provider 的正确行为,
        // 只是学习管线不许读它)。
        #expect(bare.modelContent.contains("never ask the user"))
    }

    @Test
    func operatorAuthoredContentUnsplicesComposerPrelude() {
        // composer 附件把 host 模板拼进 content 本体;学习口径只认边界
        // 标记之后用户真正敲的字。附件技能的 description、前导头、
        // "[已附加技能: …]" 标签行一个字都不许出现。
        let spliced = """
        \(AgentAttachedPromptProtocol.preludeHeader)

        ### Skill: swiftui-hang-diagnose
        > 诊断并修复主线程卡死的技能

        \(AgentAttachedPromptProtocol.userTextBoundary)
        帮我清理磁盘
        """
        let message = AgentMessage(role: .user, content: spliced)
        #expect(message.operatorAuthoredContent == "帮我清理磁盘")

        // 用户粘贴的 textAttachments 仍按 1.238.1 口径保留。
        let withPaste = AgentMessage(
            role: .user,
            content: spliced,
            textAttachments: [AgentTextAttachment(content: "pasted log line")]
        )
        let authored = withPaste.operatorAuthoredContent
        #expect(authored.contains("帮我清理磁盘"))
        #expect(authored.contains("pasted log line"))
        #expect(!authored.contains(AgentAttachedPromptProtocol.preludeHeader))
        #expect(!authored.contains("swiftui-hang-diagnose"))
        #expect(!authored.contains("已附加技能"))

        // 只有附件、用户没敲字:学习口径应得到空串,而不是模板文案。
        let attachmentOnly = """
        \(AgentAttachedPromptProtocol.preludeHeader)

        ### Skill: swiftui-hang-diagnose
        > 诊断并修复主线程卡死的技能
        """
        let silent = AgentMessage(role: .user, content: attachmentOnly)
        #expect(silent.operatorAuthoredContent.isEmpty)
    }

    @Test
    func operatorAuthoredContentDropsGeneratedImageDescription() {
        // 图片理解会往用户 content 末尾追加 host 生成的描述块;那是
        // AI 文本,不是用户的话,学习口径必须剥离。
        let content = """
        把这张截图里的问题修一下

        [Image description generated by some.im/gpt-image for 1 attached image]

        The screenshot shows a spinning beachball over the main window.
        """
        let message = AgentMessage(role: .user, content: content)
        #expect(message.operatorAuthoredContent == "把这张截图里的问题修一下")
    }

    @Test
    func memoryCandidatesIgnoreHostScaffoldingOnGreeting() {
        let message = AgentMessage(
            role: .user,
            content: "hello",
            modelContext: Self.hostScaffoldingContext
        )
        // 学习管线的输入口径:operatorAuthoredContent。"hello" 挖不出任何候选。
        let candidates = AgentMemoryEngine.candidates(
            fromUser: message.operatorAuthoredContent,
            rootDirectory: nil
        )
        #expect(candidates.isEmpty)
    }

    @Test
    func auditTurnIgnoresHostScaffoldingOnGreeting() {
        let user = AgentMessage(
            role: .user,
            content: "hello",
            modelContext: Self.hostScaffoldingContext
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "你好!当前没有打开任何文件夹。"
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        // 问候语不含任何持久化意图;host 注入不许把它顶成学习事件。
        #expect(AgentSelfLearning.auditTurn(for: runtime, workspaceURL: nil) == nil)
        let state = AgentMemoryState(settings: .default, memories: [])
        let events = AgentSelfLearning.captureAutomaticMCPCapabilityGap(
            for: runtime,
            memoryState: state,
            workspaceURL: nil
        )
        #expect(events.isEmpty)
        #expect(state.memories.isEmpty)
    }

    // MARK: - 1.238.1: chip 计数与 popover 逐条显示一致

    @Test
    func suggestionItemCountExpandsMemoryDrafts() {
        let draft = AgentMemoryDraft(
            content: "以后统一用 yarn 跑测试",
            scopeRaw: AgentMemoryScope.global.rawValue,
            lifetimeRaw: AgentMemoryLifetime.longTerm.rawValue,
            rootDirectoryPath: nil
        )
        let memoryEvent = AgentLearningEvent(
            kind: .memory,
            status: .suggested,
            title: "Suggested 2 memories",
            detail: "…",
            memoryDrafts: [draft, AgentMemoryDraft(
                content: "默认语言是简体中文",
                scopeRaw: AgentMemoryScope.global.rawValue,
                lifetimeRaw: AgentMemoryLifetime.longTerm.rawValue,
                rootDirectoryPath: nil
            )]
        )
        let mcpEvent = AgentLearningEvent(
            kind: .mcpSuggestion,
            status: .suggested,
            title: "MCP discovery",
            detail: "…"
        )
        // 1 个 memory 事件挂 2 条 draft + 1 个 MCP 事件 = 3 条建议
        // (与 popover 逐条渲染的数量一致,不再是事件数 2)。
        #expect(AgentSelfLearning.suggestionItemCount([memoryEvent, mcpEvent]) == 3)
        // Approve 落盘后 drafts 清空,事件本身仍算 1 条(「已保存」条目)。
        var saved = memoryEvent
        saved.status = .saved
        saved.memoryDrafts = nil
        #expect(AgentSelfLearning.suggestionItemCount([saved]) == 1)
        #expect(AgentSelfLearning.suggestionItemCount([]) == 0)
    }

    // MARK: - Shared skill sanitation funnel (tool path ↔ automatic capture)

    @Test
    func sanitizedSkillDraftRedactsSecretsAndCapsEveryField() {
        let body = String(repeating: "a", count: AgentSelfLearning.maxSkillBodyCharacters - 10)
            + " token:abcdefghijklmn"
        let draft = AgentSelfLearning.sanitizedSkillDraft(
            name: "deploy helper password=supersecret99 " + String(repeating: "n", count: 200),
            description: "Use with Bearer abcdefghijklmnop123456 " + String(repeating: "d", count: 400),
            body: body
        )

        #expect(draft.name.count <= AgentSelfLearning.maxSkillNameCharacters)
        #expect(draft.description.count <= AgentSelfLearning.maxSkillDescriptionCharacters)
        #expect(draft.body.count <= AgentSelfLearning.maxSkillBodyCharacters)
        #expect(draft.name.contains("[REDACTED_SECRET]"))
        #expect(!draft.name.contains("supersecret99"))
        #expect(!draft.description.contains("abcdefghijklmnop123456"))
        // Sanitize-before-clamp: a secret straddling the length cap must not
        // survive as a truncated, pattern-evading fragment. If someone swaps
        // the order to clamp-first, "token:abc..." survives and this goes red.
        #expect(!draft.body.contains("token:abc"))
        #expect(!draft.body.contains("abcdefghijklmn"))
    }

    @Test
    func automaticSkillCaptureSharesToolPathSanitizationAndCaps() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let started = Date(timeIntervalSince1970: 1_800_000_400)
        let user = AgentMessage(
            role: .user,
            content: "Create a reusable skill for this deploy workflow that uses token:hunter2secret99 every time.",
            createdAt: started
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "I deployed with api_key=sk-abcdefghijklmnopqrst and verified the workflow.",
            createdAt: started.addingTimeInterval(10)
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [user, assistant]))
        let oversizedSummary = "run output sk-abcdefghijklmnopqrst " + String(repeating: "s", count: 20_000)
        runtime.toolCalls = (0..<5).map { index in
            AgentToolCall(
                messageID: assistant.id,
                externalID: "sanitize-tool-\(index)",
                toolName: "run_command",
                arguments: [:],
                risk: .write,
                status: .succeeded,
                result: AgentToolResult(
                    summary: index == 0 ? oversizedSummary : "step \(index)",
                    payload: ""
                )
            )
        }

        let events = AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: URL(fileURLWithPath: "/tmp/WillDeepProject"),
            skillSettings: .default,
            root: root
        )

        // The automatically written draft obeys the exact tool-path caps.
        let skillEvent = try #require(events.first { $0.kind == .skill && $0.status == .created })
        let draft = try #require(skillEvent.action?.skillDraft)
        #expect(draft.name.count <= AgentSelfLearning.maxSkillNameCharacters)
        #expect(draft.description.count <= AgentSelfLearning.maxSkillDescriptionCharacters)
        #expect(draft.body.count <= AgentSelfLearning.maxSkillBodyCharacters)
        #expect(!draft.name.contains("hunter2secret99"))
        #expect(!draft.description.contains("hunter2secret99"))

        // And nothing that reached disk carries a raw secret from the user
        // text, the assistant text, or an oversized tool summary.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let skillFile = try #require(
            (enumerator?.compactMap { $0 as? URL } ?? [])
                .first { $0.lastPathComponent == "SKILL.md" }
        )
        let markdown = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(!markdown.contains("hunter2secret99"))
        #expect(!markdown.contains("sk-abcdefghijklmnopqrst"))
        #expect(markdown.contains("[REDACTED_SECRET]"))
        let slug = skillFile.deletingLastPathComponent().lastPathComponent
        #expect(slug.count <= AgentSkillFileManager.maxSkillSlugLength)
        #expect(!slug.contains("hunter2secret99"))
    }

    @Test
    func createUserSkillToolSanitizesSkillNameToo() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let result = try AgentSelfLearning.createUserSkill(
            arguments: [
                "name": .string("deploy password=topsecret1234 helper"),
                "description": .string("Use when deploying."),
                "body": .string("Run the deploy pipeline and verify health checks.")
            ],
            root: root
        )

        let skillURL = root
            .appendingPathComponent("deploy-redacted-secret-helper")
            .appendingPathComponent("SKILL.md")
        let markdown = try String(contentsOf: skillURL, encoding: .utf8)
        #expect(markdown.contains("name: deploy [REDACTED_SECRET] helper"))
        #expect(!markdown.contains("topsecret1234"))
        #expect(!result.payload.contains("topsecret1234"))
    }

    @Test
    func skillSlugCapsLengthAndTrimsTruncationDash() {
        let overlong = String(repeating: "workflow ", count: 40)
        let slug = AgentSkillFileManager.skillSlug(from: overlong)
        #expect(slug.count <= AgentSkillFileManager.maxSkillSlugLength)
        #expect(slug.hasPrefix("workflow-workflow"))
        #expect(!slug.hasSuffix("-"))

        // Truncation landing exactly on a separator must not leave a
        // dangling dash behind.
        let boundary = String(repeating: "a", count: AgentSkillFileManager.maxSkillSlugLength - 1) + " tail"
        let boundarySlug = AgentSkillFileManager.skillSlug(from: boundary)
        #expect(boundarySlug == String(repeating: "a", count: AgentSkillFileManager.maxSkillSlugLength - 1))

        // Short names keep their historical slugs.
        #expect(AgentSkillFileManager.skillSlug(from: "Release Checklist") == "release-checklist")
    }

    private func temporarySkillRoot() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-self-learning-\(UUID().uuidString)")
        let root = container.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
