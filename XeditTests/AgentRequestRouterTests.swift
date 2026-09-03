import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentRequestRouterTests {
    // MARK: Read-only classification

    @Test("locating something in Chinese routes to scout and is preflight-safe")
    func chineseLocationRoutesToScout() {
        let decision = AgentRequestRouter.classify("用户权限检查在哪个文件")

        #expect(decision.profileID == "scout")
        #expect(decision.tier == .worker)
        #expect(decision.autoDispatchEligible)
    }

    @Test("asking to locate AND fix is not read-only work")
    func locateAndFixIsNotReadOnly() {
        // The distinction that matters: the same sentence with a verb of
        // change in it must never be pre-run as a read-only preflight.
        let decision = AgentRequestRouter.classify("定位并修复用户权限检查")

        #expect(decision.profileID == "implementer")
        #expect(decision.tier == .standard)
        #expect(!decision.autoDispatchEligible)
    }

    @Test("explaining a test failure stays read-only, fixing one does not")
    func testFailureSplitsOnIntent() {
        let explain = AgentRequestRouter.classify("解释一下这个测试失败的原因")
        #expect(explain.profileID == "log_inspector")
        #expect(explain.autoDispatchEligible)

        let fix = AgentRequestRouter.classify("测试失败了，修复这个断言")
        #expect(fix.profileID == "test_fixer")
        // A repair has a verifier, so it is worker-tier — but it writes, and
        // nothing that writes is ever run as a preflight.
        #expect(fix.tier == .worker)
        #expect(!fix.autoDispatchEligible)
    }

    @Test("build failures route to the build fixer when the ask is to repair")
    func buildFailureRoutesToBuildFixer() {
        #expect(AgentRequestRouter.classify("编译失败，帮我修复").profileID == "build_fixer")
        #expect(AgentRequestRouter.classify("这个编译失败是什么意思").profileID == "log_inspector")
    }

    @Test("regression archaeology routes to git_detective")
    func regressionRoutesToGitDetective() {
        let decision = AgentRequestRouter.classify("哪个提交引入这个问题的")

        #expect(decision.profileID == "git_detective")
        #expect(decision.autoDispatchEligible)
    }

    @Test("a repository audit routes to reader")
    func auditRoutesToReader() {
        let decision = AgentRequestRouter.classify("扫一下这个仓库，解释当前架构")

        #expect(decision.tier == .worker)
        #expect(decision.profileID == "reader")
    }

    @Test("English requests classify the same way")
    func englishClassifiesToo() {
        #expect(AgentRequestRouter.classify("where is the auth middleware").profileID == "scout")
        #expect(AgentRequestRouter.classify("summarize this module").profileID == "reader")
        #expect(AgentRequestRouter.classify("implement the retry backoff").profileID == "implementer")
    }

    @Test("an ambiguous request falls back to the general-purpose utility worker")
    func ambiguousRequestFallsBackToGeneralist() {
        let decision = AgentRequestRouter.classify("嗯，接着上次那个继续吧")

        #expect(decision.profileID == AgentSubagentProfileCatalog.generalistID)
        #expect(decision.tier == .worker)
        #expect(decision.requiresDelegatedExecution)
        #expect(decision.steering?.contains("profile=\"generalist\"") == true)
    }

    // MARK: Steering

    @Test("steering names the trade and the read/write split")
    func steeringMentionsTheTrade() throws {
        let steering = try #require(
            AgentRequestRouter.steering(for: "这个函数定义在哪个文件", delegationPolicy: .automatic)
        )

        #expect(steering.contains("profile=\"scout\""))
        #expect(steering.contains("read_files"))
        #expect(steering.contains("write_files"))
    }

    @Test("automatic routing is advisory but explicit delegation is mandatory")
    func steeringStrengthFollowsDelegationPolicy() throws {
        let decision = AgentRequestRouter.classify("实现新的重试策略")
        let automatic = try #require(decision.steering(for: .automatic))
        let required = try #require(decision.steering(for: .required))

        #expect(automatic.contains("routing hint"))
        #expect(automatic.contains("proceed directly"))
        #expect(!automatic.contains("may refuse direct execution"))
        #expect(required.contains("delegate it before direct execution"))
        #expect(required.contains("may refuse direct execution"))
    }

    @Test("ops and pinned routes stay mandatory without a slash command")
    func privilegedAndPinnedRoutesStayMandatory() throws {
        let ops = AgentRequestRouter.classify("部署到生产环境")
        let pinned = AgentRequestRouter.pinnedDecision(profileID: "editor")

        #expect(ops.enforcesDelegatedExecution(for: .automatic))
        #expect(pinned.enforcesDelegatedExecution(for: .automatic))
        #expect(try #require(ops.steering).contains("delegate it before direct execution"))
        #expect(try #require(pinned.steering).contains("delegate it before direct execution"))
    }

    @Test("/no-subagent suppresses steering entirely")
    func forbiddenPolicySuppressesSteering() {
        // `spawn_agent` is gone from the tool table that turn; pointing the
        // model at it would only cost a rejected round.
        #expect(AgentRequestRouter.steering(
            for: "这个函数定义在哪个文件",
            delegationPolicy: .forbidden
        ) == nil)

        #expect(AgentRequestRouter.steering(
            for: "这个函数定义在哪个文件",
            delegationPolicy: .required
        ) != nil)
    }

    @Test("running the gates is executed by the tester preflight")
    func testRunRoutesToTesterPreflight() {
        let decision = AgentRequestRouter.classify("跑一下测试看看现在什么情况")

        #expect(decision.profileID == "tester")
        #expect(decision.autoDispatchEligible)
        #expect(decision.preflightProfileID == "tester")

        // A failure that already happened is a different trade.
        #expect(AgentRequestRouter.classify("测试失败了，修复这个断言").profileID == "test_fixer")
    }

    @Test("reviewing a change routes to reviewer, reading code to reader")
    func reviewOfAChangeRoutesToReviewer() {
        let review = AgentRequestRouter.classify("审查这个改动有没有超出范围")

        #expect(review.profileID == "reviewer")
        #expect(review.autoDispatchEligible)

        // "审查" alone must not steal every reading request from `reader`.
        #expect(AgentRequestRouter.classify("解释一下这个模块").profileID == "reader")
    }

    @Test("a change naming one file routes to editor, several to implementer")
    func singleNamedFileRoutesToEditor() {
        // `editor` had no branch at all before this: every mutating request
        // became `implementer`, so the single-file trade was never suggested.
        let single = AgentRequestRouter.classify("把 Xedit/AppState.swift 里的超时改成 30 秒")

        #expect(single.profileID == "editor")
        #expect(single.tier == .worker)
        // Writing work is never pre-run — a preflight that edits is not a
        // preflight.
        #expect(!single.autoDispatchEligible)
        #expect(single.preflightProfileID == "scout")
        #expect(single.requiresDelegatedExecution)

        let several = AgentRequestRouter.classify(
            "修改 Xedit/AppState.swift 和 Xedit/AgentRuntime.swift 的超时"
        )
        #expect(several.profileID == "implementer")

        // No file named at all stays with the wider trade.
        #expect(AgentRequestRouter.classify("实现重试退避").profileID == "implementer")
    }

    @Test("ordinary Chinese coding verbs enter the delegated implementation lane")
    func broaderCodingRequestsRouteToImplementer() {
        for request in [
            "帮我开发一个重试按钮",
            "这个模块需要优化一下",
            "接入新的缓存策略",
            "给这个解析器补测试",
        ] {
            let decision = AgentRequestRouter.classify(request)
            #expect(decision.profileID == "implementer", "request: \(request)")
            #expect(decision.preflightProfileID == "scout", "request: \(request)")
            #expect(decision.requiresDelegatedExecution, "request: \(request)")
        }
    }

    @Test("host skill metadata cannot reroute a plugin-development question to operations")
    func attachedSkillMetadataDoesNotVote() {
        let composed = """
        \(AgentAttachedPromptProtocol.preludeHeader)

        ### Skill routing candidates — metadata only

        - `go-react-embed-deploy` — 生产部署、发布和 systemd 运维

        \(AgentAttachedPromptProtocol.userTextBoundary)

        怎么开发 WillDeep 插件
        """

        let decision = AgentRequestRouter.classify(composed)
        #expect(decision.profileID == "implementer")
        #expect(decision.preflightProfileID == "scout")
    }

    @Test("operations get a read-only ops preflight and delegate-first execution")
    func operationsRouteToOpsRunner() {
        let decision = AgentRequestRouter.classify("部署到生产环境并确认服务状态")

        #expect(decision.profileID == "ops_runner")
        #expect(decision.preflightProfileID == "ops_runner")
        #expect(decision.requiresDelegatedExecution)
    }

    @Test("only source files count as a named edit target")
    func namedFileScanIgnoresNonSourcePaths() {
        // A build log is full of `.o` / `.json` / `.lock` paths; treating one
        // as an edit target is how a vague request becomes a wrong write set.
        #expect(AgentRequestRouter.namedSourceFiles("修改 build/output.o 和 package.lock").isEmpty)
        #expect(AgentRequestRouter.namedSourceFiles("改 a.swift 和 b.swift 再改 a.swift").count == 2)
    }

    @Test("only the head of a long paste is classified")
    func longPasteDoesNotVoteWithItsBody() {
        // A pasted stack trace at the end of an implementation request must
        // not turn the whole turn into a log inspection.
        let request = "实现新的重试策略\n\n" + String(repeating: "x", count: 8_000) + "\nstack trace"

        #expect(AgentRequestRouter.classify(request).profileID == "implementer")
    }
}
