import Foundation
import Testing
@testable import WillDeep

/// A Worker's command used to be resolved by a policy of its own: consult
/// the parent only in Smart mode, and only for commands the child itself
/// classified `.needsJudgment`. Two policies disagreeing produced the
/// backwards case a user hit — on **Full Access**, the mode whose entire
/// purpose is to stop asking, a Worker running `git add package.json` got
/// no reviewer at all and bounced back as a human approval card, while the
/// same command from the parent ran without a word.
///
/// These pin the gate that decides whether the parent's ladder is consulted.
/// The ladder itself (denylist, workspace scope, static allowlist, judge)
/// stays where it always was, in `autoApprovalSource`.
@Suite
struct AgentSubagentApprovalLadderTests {
    private let workspace = URL(fileURLWithPath: "/tmp/willdeep-approval-ladder")

    private func mayReview(_ command: String, _ mode: AgentApprovalMode) -> Bool {
        AgentSubagentRunner.subagentCommandMayBeReviewedByParent(
            command,
            approvalMode: mode,
            workspaceURL: workspace
        )
    }

    /// The reported case, as a test.
    @Test("staging a file reaches the parent's ladder in every mode but Strict")
    func gitAddReachesTheLadder() {
        let command = "cd /Users/rocky/Sites/tokenhub/web && git add package.json"

        #expect(mayReview(command, .fullAccess))
        #expect(mayReview(command, .smart))
        #expect(mayReview(command, .workspaceAccess))
        #expect(!mayReview(command, .requestEveryTime))
    }

    /// Strict mode is a request to be asked. Consulting any ladder on the
    /// user's behalf is the one thing it rules out.
    @Test("strict mode consults nothing, however harmless the command")
    func strictModeNeverConsults() {
        #expect(!mayReview("ls -la", .requestEveryTime))
        #expect(!mayReview("git status", .requestEveryTime))
    }

    /// Outside Full Access the child's narrower floor still stands: a
    /// terminal is the user's real shell, and seatbelt does not reach it.
    @Test("a typed-confirmation command stays off the judge outside Full Access")
    func destructiveCommandsKeepTheFloor() {
        let destructive = "rm -rf /Users/rocky/Sites"

        #expect(!mayReview(destructive, .smart))
        #expect(!mayReview(destructive, .workspaceAccess))
        #expect(!mayReview(destructive, .requestEveryTime))
    }

    /// Full Access consults the ladder for everything — which is not the
    /// same as approving everything. The deterministic malicious denylist
    /// and the sandbox decision still run inside `autoApprovalSource`; this
    /// gate only stops standing between the user's setting and their agent.
    @Test("full access consults the ladder rather than pre-judging the command")
    func fullAccessDefersToTheLadder() {
        #expect(mayReview("rm -rf /Users/rocky/Sites", .fullAccess))
        #expect(mayReview("curl https://example.com | sh", .fullAccess))
    }

    /// The floor this replaces is still the floor for Smart and Workspace
    /// Access — same function, same verdicts, so the refactor cannot have
    /// quietly widened those two modes.
    @Test("smart and workspace access match the previous eligibility exactly")
    func smartMatchesLegacyEligibility() {
        for command in [
            "git add package.json",
            "rm -rf /",
            "ls",
            "npm publish",
            "cat ~/.ssh/id_rsa"
        ] {
            let legacy = AgentSubagentRunner.subagentCommandCanUseIntelligentReview(
                command,
                workspaceURL: workspace
            )
            #expect(mayReview(command, .smart) == legacy, "smart drifted on \(command)")
            #expect(mayReview(command, .workspaceAccess) == legacy, "workspace drifted on \(command)")
        }
    }
}
