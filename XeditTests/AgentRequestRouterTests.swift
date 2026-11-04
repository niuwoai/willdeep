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
            AgentRequestRouter.steering(
                for: "这个函数定义在哪个文件",
                delegationPolicy: .automatic,
                sharedConfig: AgentSharedRuntimeConfig()
            )
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
            delegationPolicy: .forbidden,
            sharedConfig: AgentSharedRuntimeConfig()
        ) == nil)

        #expect(AgentRequestRouter.steering(
            for: "这个函数定义在哪个文件",
            delegationPolicy: .required,
            sharedConfig: AgentSharedRuntimeConfig()
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

    @Test("naming a Kubernetes deployment is not asking for a rollout")
    func deploymentNounDoesNotRouteToOperations() {
        // "deploy" used to match as a bare substring, so "deployment" dragged
        // an ordinary manifest edit into ops_runner — which enforces delegated
        // execution regardless of policy, blocking the edit outright.
        let decision = AgentRequestRouter.classify("那你把 deployment 里的注解改一下")

        #expect(decision.profileID != "ops_runner")
        // The field that actually gates the edit: ops_runner enforces delegation
        // regardless of policy, so a false hit blocked direct writes outright.
        // An ordinary implementation route leaves that to the turn policy.
        #expect(!decision.enforcesDelegatedExecution(for: .automatic))
    }

    @Test("operations vocabulary still routes to ops once the boundary is enforced")
    func operationsSurviveWordBoundaryMatching() {
        // The boundary must not cost the real operations phrasings: a trailing
        // CJK character is a clean boundary, and an exact word still matches.
        #expect(AgentRequestRouter.classify("deploy 到生产环境").profileID == "ops_runner")
        #expect(AgentRequestRouter.classify("deploy一下这个服务").profileID == "ops_runner")
        #expect(AgentRequestRouter.classify("跑一下 systemctl status").profileID == "ops_runner")
        // Mutating verbs stay compatible with a genuine operations request.
        #expect(AgentRequestRouter.classify("修复线上环境的服务").profileID == "ops_runner")
    }

    @Test("only source files count as a named edit target")
    func namedFileScanIgnoresNonSourcePaths() {
        // A build log is full of `.o` / `.json` / `.lock` paths; treating one
        // as an edit target is how a vague request becomes a wrong write set.
        #expect(AgentRequestRouter.namedSourceFiles("修改 build/output.o 和 package.lock").isEmpty)
        #expect(AgentRequestRouter.namedSourceFiles("改 a.swift 和 b.swift 再改 a.swift").count == 2)
    }

    @Test("a deployment script named as an edit target is an edit, not a rollout")
    func deploymentNounPhraseAndNamedScriptStayEdits() {
        // CJK has no word boundary; "部署脚本" is a noun phrase and must not
        // trip the operations table.
        let phrase = AgentRequestRouter.classify("把部署脚本里的超时改成 60s")
        #expect(phrase.profileID != "ops_runner")
        #expect(!phrase.enforcesDelegatedExecution(for: .automatic))
        // Naming the file makes it an edit even though "deploy" stands alone.
        let named = AgentRequestRouter.classify("修一下 deploy.sh 里的超时")
        #expect(named.profileID == "editor")
        #expect(!named.enforcesDelegatedExecution(for: .automatic))
        // The genuine rollout still routes to operations.
        #expect(AgentRequestRouter.classify("按部署流程把新版本部署到生产环境").profileID == "ops_runner")
    }

    @Test("点名要改 yaml 清单是编辑，不因引述里的生产词汇走运维")
    func namedManifestEditIsNotAnOperation() {
        // The 2026-09-22 request that spent 4m33s in an ops preflight.
        let request = "生产集群没动。若要走生产，注意 preflight 报告指出的坑：deploy/k8s/overlays/production/03b-deploy-svc.yaml 里镜像标签还停在 0.238.0-rc8，直接 apply overlay 会把生产降级，必须先同步该文件的 tag 与 change-cause 再发。你改一下yaml文件吧"
        let decision = AgentRequestRouter.classify(request)
        #expect(decision.profileID != "ops_runner", "routed to \(decision.profileID)")
        #expect(decision.preflightProfileID != "ops_runner")

        // A file-type word with no path is still an edit.
        #expect(AgentRequestRouter.classify("把生产环境的 yaml 文件里的副本数改成 3").profileID != "ops_runner")
        // Path followed directly by CJK text still names the file.
        #expect(AgentRequestRouter.namedEditableFiles("改一下 k8s/app.yaml里的镜像").contains("k8s/app.yaml"))
        // Editable-file detection is wider than the build-fixer's source list.
        #expect(AgentRequestRouter.namedSourceFiles("改一下 values.yaml").isEmpty)
        #expect(!AgentRequestRouter.namedEditableFiles("改一下 values.yaml").isEmpty)

        // A genuine rollout without a file to edit still goes to operations.
        #expect(AgentRequestRouter.classify("按部署流程把新版本部署到生产环境").profileID == "ops_runner")
        // A version string is not a file name.
        #expect(AgentRequestRouter.namedEditableFiles("把 0.247.0-rc2 发到生产").isEmpty)
    }

    @Test("fix only counts as a mutating verb when it stands alone")
    func fixNeedsAWordBoundary() {
        // "prefix" is not a repair request; it used to skip every read-only
        // branch because "fix" matched as a bare substring.
        #expect(AgentRequestRouter.classify("解释一下这个 prefix 的含义").profileID == "reader")
        #expect(AgentRequestRouter.classify("explain what this test fixture does").profileID == "reader")
        // The inflections the marker exists for still count.
        #expect(AgentRequestRouter.classify("fixing the failing test").profileID == "test_fixer")
        #expect(AgentRequestRouter.classify("fix the compile error").profileID == "build_fixer")
    }

    @Test("reaching a remote host is an operations hint without forced delegation")
    func remoteAccessRoutesToOperationsAsAHint() {
        let decision = AgentRequestRouter.classify("ssh 上去重跑一下 pipeline")
        #expect(decision.profileID == "ops_runner")
        #expect(!decision.autoDispatchEligible)
        #expect(!decision.enforcesDelegatedExecution(for: .automatic))
        // A word boundary keeps "sshd" and "scp" inside a path out of it.
        #expect(AgentRequestRouter.classify("解释一下 sshd_config 的含义").profileID == "reader")
        // Naming a file to edit wins over the remote-access hint.
        #expect(AgentRequestRouter.classify("改一下 ssh_helper.rb 里的超时").profileID == "editor")
    }

    @Test("inspecting a live system routes to ops without the forced-delegation lock")
    func readOnlyOperationsAreNotLocked() {
        // Only ops_runner holds the credentials, so the trade stays; but a
        // status check is not a rollout, and must not block direct execution.
        let status = AgentRequestRouter.classify("看一下生产环境的服务状态")
        #expect(status.profileID == "ops_runner")
        #expect(status.autoDispatchEligible)
        #expect(!status.enforcesDelegatedExecution(for: .automatic))
        // Without `requiresDelegatedExecution` even a required policy has
        // nothing to enforce here — that policy governs writes, not looks.
        #expect(!status.enforcesDelegatedExecution(for: .required))
        // A change to the live system keeps the lock regardless of policy.
        let rollout = AgentRequestRouter.classify("重启服务然后看服务状态")
        #expect(rollout.profileID == "ops_runner")
        #expect(rollout.enforcesDelegatedExecution(for: .automatic))
    }

    @Test("a mutating request that mentions the terminal is not terminal inspection")
    func mutatingRequestSkipsTheTerminalOperator() {
        // terminal_operator has no write tools, so it can never own an edit.
        let decision = AgentRequestRouter.classify("改一下终端里那个脚本的报错")
        #expect(decision.profileID != "terminal_operator")
        // Pure inspection still goes there.
        #expect(AgentRequestRouter.classify("看看终端里现在跑到哪了").profileID == "terminal_operator")
    }

    @Test("only the head of a long paste is classified")
    func longPasteDoesNotVoteWithItsBody() {
        // A pasted stack trace at the end of an implementation request must
        // not turn the whole turn into a log inspection.
        let request = "实现新的重试策略\n\n" + String(repeating: "x", count: 8_000) + "\nstack trace"

        #expect(AgentRequestRouter.classify(request).profileID == "implementer")
    }
}
