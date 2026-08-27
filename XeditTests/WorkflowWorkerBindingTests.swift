//
//  WorkflowWorkerBindingTests.swift
//  WillDeepTests
//
//  不变量：**绑给某个工种的 workflow 步骤，其提示词里点名的工具必须在
//  那个工种的白名单里。**
//
//  为什么需要这条：BugHunt 的 picker 步骤曾经绑给 scout，而提示词却让它
//  去调 `git_status` 和 `run_command "git log"`——scout 两样都没有。工种
//  老实按提示词调用，被拒，只能退回猜，而调用方毫不知情：workflow 照常
//  返回一份"看起来像那么回事"的文件清单。这类错配不会报错，只会安静地
//  降低质量，靠 review 是抓不住的。
//
//  这个 suite 检查的是**源码里的绑定与提示词是否自洽**，不跑真实模型。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct WorkflowWorkerBindingTests {

    /// 工种绑定处的 workflow 源文件，以及绑给它的工种。
    /// 新增绑定时在这里登记——漏登记只会少测，不会误报。
    ///
    /// `conditional` = 该文件用「素材内联成功 → 窄工种，否则回落 deep」的
    /// 条件绑定。这种文件里允许出现窄工种没有的工具名——那些指引只出现在
    /// 回落分支的提示词里，跟着 deep 档走；但源码必须真的存在那个条件门
    /// （`inlinedDiff != nil`），否则等于把带工具指引的提示词直接塞给了
    /// 没有工具的工种。
    private static let bindings: [(file: String, profile: AgentSubagentProfile, conditional: Bool)] = [
        ("CodeReviewWorkflow.swift", AgentSubagentProfileCatalog.reviewer, true),
        ("PRReviewWorkflow.swift", AgentSubagentProfileCatalog.reviewer, true),
        ("BugHuntWorkflow.swift", AgentSubagentProfileCatalog.reviewer, false),
        ("ReleaseNotesWorkflow.swift", AgentSubagentProfileCatalog.gitDetective, false),
        ("CompetitorAnalysisWorkflow.swift", AgentSubagentProfileCatalog.reader, false),
    ]

    /// 提示词里点名工具的常见写法：反引号包裹的工具名。
    private static let knownToolNames: Set<String> = [
        "read_file", "list_directory", "grep_files", "search_files",
        "git_status", "run_command", "web_search", "apply_patch"
    ]

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Xedit", isDirectory: true)
    }

    @Test("绑定工种的 workflow 不得在提示词里点名它没有的工具")
    func boundWorkflowsOnlyNameToolsTheirTradeHas() throws {
        for binding in Self.bindings {
            let url = Self.sourceRoot.appendingPathComponent(binding.file)
            let source = try String(contentsOf: url, encoding: .utf8)

            // 提示词里以 `tool_name` 形式点名的工具。
            let named = Self.knownToolNames.filter { tool in
                source.contains("`\(tool)`") || source.contains("`\(tool) ")
            }
            let missing = named.subtracting(binding.profile.toolNames)

            if binding.conditional {
                // 条件绑定：窄工种缺的工具名可以出现（在回落分支的提示词里），
                // 但条件门必须真的在——没有门，带工具指引的提示词就会流进
                // 没有工具的工种。这正是本 suite 第一次运行就抓到的事故。
                if !missing.isEmpty {
                    #expect(
                        source.contains("inlinedDiff != nil"),
                        "\(binding.file) 的提示词点名了 \(binding.profile.id) 没有的工具（\(missing.sorted().joined(separator: ", "))），却没有「内联成功才下放窄工种」的条件门"
                    )
                }
            } else {
                #expect(
                    missing.isEmpty,
                    "\(binding.file) 绑给了 \(binding.profile.id)，但提示词点名了该工种没有的工具：\(missing.sorted().joined(separator: ", "))"
                )
            }
        }
    }

    @Test("被绑定的工种都还在目录里且工具集非空")
    func boundTradesExist() {
        for binding in Self.bindings {
            #expect(!binding.profile.id.isEmpty)
            #expect(
                !binding.profile.toolNames.isEmpty,
                "\(binding.profile.id) 没有任何工具，不该被拿来跑 workflow 步骤"
            )
        }
    }

    @Test("reviewer 覆盖只读审查所需的全部工具")
    func reviewerCoversReadOnlyReview() {
        let reviewer = AgentSubagentProfileCatalog.reviewer.toolNames
        for tool in ["read_file", "list_directory", "grep_files", "search_files"] {
            #expect(reviewer.contains(tool), "reviewer 缺少 \(tool)")
        }
        // 审查工种不得拿到写权限或 shell——拿到就不再是"独立只读审查"。
        #expect(!reviewer.contains("apply_patch"))
        #expect(!reviewer.contains("run_command"))
    }

    @Test("带 shell 的窄工种只有 git_detective 与 ops_runner")
    func shellCarryingNarrowTrades() {
        // ReleaseNotes 的素材收集绑 git_detective，正因为要跑 `git log`。
        #expect(AgentSubagentProfileCatalog.gitDetective.toolNames.contains("run_command"))
        // ops_runner 是 1.263.0-rc1 补上的"只读 + shell"通用工种——正是
        // 此前 `gh issue list` 类抓取步骤无处可绑的缺口。
        #expect(AgentSubagentProfileCatalog.opsRunner.toolNames.contains("run_command"))
        #expect(!AgentSubagentProfileCatalog.scout.toolNames.contains("run_command"))
        #expect(!AgentSubagentProfileCatalog.reader.toolNames.contains("run_command"))
    }

    @Test("terminal_operator 的工具面收在只读观察 + 单发命令")
    func terminalOperatorToolSurface() {
        let effective = AgentSubagentProfileCatalog.terminalOperator
            .effectiveToolNames(writeAccessGranted: false)
        // 终端五件套里的读三样 + send_command 必须真的生效（专属放行是
        // effectiveToolNames 的 union，漏了会被全局白名单静默滤掉）。
        for tool in ["terminal_list_tabs", "terminal_select_tab", "terminal_snapshot", "terminal_send_command"] {
            #expect(effective.contains(tool), "terminal_operator 缺 \(tool)")
        }
        // send_control（打断用户前台任务）与捷径写工具刻意不给。
        #expect(!effective.contains("terminal_send_control"))
        #expect(!effective.contains("terminal_create_shortcut"))
        #expect(!effective.contains("terminal_edit_shortcut"))
        // 专属放行不外溢：其他工种即便自己声明终端工具也拿不到。
        var rogue = AgentSubagentProfileCatalog.scout
        rogue.toolNames.insert("terminal_send_command")
        #expect(!rogue.effectiveToolNames().contains("terminal_send_command"))
    }

    @Test("运维子代理只把非敏感的模糊修改命令送智能审核")
    @MainActor
    func terminalOperatorIntelligentReviewBoundary() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-terminal-review")
        #expect(AgentSubagentRunner.subagentCommandCanUseIntelligentReview(
            "timedatectl set-timezone UTC",
            workspaceURL: root
        ))
        #expect(AgentSubagentRunner.subagentCommandCanUseIntelligentReview(
            "hostnamectl set-hostname staging-box",
            workspaceURL: root
        ))

        // 已知只读命令无需浪费裁判调用；危险与凭据命令则没有模型放行权。
        #expect(!AgentSubagentRunner.subagentCommandCanUseIntelligentReview(
            "timedatectl status",
            workspaceURL: root
        ))
        #expect(!AgentSubagentRunner.subagentCommandCanUseIntelligentReview(
            "rm -rf /",
            workspaceURL: root
        ))
        #expect(!AgentSubagentRunner.subagentCommandCanUseIntelligentReview(
            "cat ~/.ssh/id_rsa",
            workspaceURL: root
        ))

        let smartPrompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: root,
            profile: AgentSubagentProfileCatalog.opsRunner,
            intelligentCommandReviewAvailable: true
        )
        #expect(smartPrompt.contains("intelligent safety review"))
        #expect(smartPrompt.contains("ops_runner.target_command"))
        #expect(!smartPrompt.contains("Write operations are denied"))

        let strictPrompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: root,
            profile: AgentSubagentProfileCatalog.opsRunner
        )
        #expect(strictPrompt.contains("Write operations are denied"))
    }

    @Test("所有自带命令工具的工种共享同一智能审核通道")
    @MainActor
    func everyCommandCarryingTradeUsesSharedReviewContract() {
        let commandTradeIDs = Set(AgentSubagentProfileCatalog.builtIn.compactMap { profile in
            let tools = profile.effectiveToolNames(
                writeAccessGranted: profile.requiresWriteAccess
            )
            return tools.contains("run_command") || tools.contains("terminal_send_command")
                ? profile.id
                : nil
        })
        #expect(commandTradeIDs == Set([
            "deep", "implementer", "small_implementer", "tester",
            "test_fixer", "build_fixer", "git_detective", "ops_runner",
            "terminal_operator",
        ]))

        for profile in AgentSubagentProfileCatalog.builtIn where commandTradeIDs.contains(profile.id) {
            let prompt = AgentSubagentRunner.systemPrompt(
                workspaceURL: URL(fileURLWithPath: "/tmp/willdeep-shared-command-review"),
                profile: profile,
                intelligentCommandReviewAvailable: true
            )
            #expect(prompt.contains("intelligent safety review"), "\(profile.id) 未接共享审核提示词")
            #expect(!prompt.contains("Write operations are denied"), "\(profile.id) 仍带一刀切拒绝提示")
        }
    }

    @Test("reader 是唯一能联网的窄工种")
    func readerIsTheOnlyNarrowTradeWithWebSearch() {
        #expect(AgentSubagentProfileCatalog.reader.toolNames.contains("web_search"))
        #expect(!AgentSubagentProfileCatalog.scout.toolNames.contains("web_search"))
        #expect(!AgentSubagentProfileCatalog.reviewer.toolNames.contains("web_search"))
    }

    // MARK: - 单命令授权（target_command）

    @Test("带 target_command 的 spawn 是 write 档，必过审批卡")
    func targetCommandSpawnIsWriteTier() {
        // 用户在审批卡上批准的就是那条命令本身——read 档免批则整条授权
        // 通道形同虚设。
        #expect(AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: [
                "profile": .string("ops_runner"),
                "target_command": .string("ruby scripts/release.rb run veilwriter"),
            ],
            rootDirectory: nil
        ) == .write)
        // 不带 target_command 的 ops_runner spawn 保持 read 免批。
        #expect(AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: ["profile": .string("ops_runner")],
            rootDirectory: nil
        ) == .read)
        // 空白字符串不算授权。
        #expect(AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: [
                "profile": .string("ops_runner"),
                "target_command": .string("   "),
            ],
            rootDirectory: nil
        ) == .read)
    }

    @Test("单命令授权是修剪后的精确匹配，不是前缀匹配")
    func approvedCommandMatchIsExact() {
        let approved = "ruby scripts/release.rb run veilwriter"
        #expect(AgentSubagentRunner.approvedCommandMatches(approved, approved: approved))
        #expect(AgentSubagentRunner.approvedCommandMatches("  \(approved)\n", approved: approved))
        // 多一个 flag 都不行——批准的是一条命令，不是一类命令。
        #expect(!AgentSubagentRunner.approvedCommandMatches("\(approved) --force", approved: approved))
        #expect(!AgentSubagentRunner.approvedCommandMatches("ruby scripts/release.rb", approved: approved))
    }

    @Test("发布类失败命令的派工提示指向 ops_runner 的单命令授权")
    func releaseFailureHintPointsAtOpsRunner() {
        #expect(AgentWorkerDispatchHint.classify(command: "ruby scripts/release.rb run veilwriter") == .opsRunner)
        #expect(AgentWorkerDispatchHint.classify(command: "make deploy") == .opsRunner)
        #expect(AgentWorkerDispatchHint.classify(command: "kubectl apply -f prod.yaml") == .opsRunner)
        // 发布优先于构建，但纯构建仍归 build_fixer、测试仍归 test_fixer。
        #expect(AgentWorkerDispatchHint.classify(command: "make -j8") == .buildFixer)
        #expect(AgentWorkerDispatchHint.classify(command: "swift test") == .testFixer)
        let hint = AgentWorkerDispatchHint.hint(
            toolName: "run_command",
            arguments: ["command": .string("ruby scripts/release.rb run veilwriter")],
            exitCode: 1
        )
        #expect(hint?.contains("target_command") == true)
        #expect(hint?.contains("ops_runner") == true)
        // 回滚与不可逆决策必须留在主会话——这句边界不许从提示里消失。
        #expect(hint?.contains("irreversible") == true)
    }
}
