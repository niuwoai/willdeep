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

    @Test("an ambiguous request gets no steering rather than a guess")
    func ambiguousRequestGetsNoProfile() {
        let decision = AgentRequestRouter.classify("嗯，接着上次那个继续吧")

        #expect(decision.profileID == nil)
        #expect(decision.tier == .standard)
        // Nothing to say beats saying the wrong thing confidently.
        #expect(decision.steering == nil)
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

    @Test("only the head of a long paste is classified")
    func longPasteDoesNotVoteWithItsBody() {
        // A pasted stack trace at the end of an implementation request must
        // not turn the whole turn into a log inspection.
        let request = "实现新的重试策略\n\n" + String(repeating: "x", count: 8_000) + "\nstack trace"

        #expect(AgentRequestRouter.classify(request).profileID == "implementer")
    }
}
