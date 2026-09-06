import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentHybridWorkerRoutingTests {
    @Test("automatic implementation is advisory while explicit delegation is enforced")
    func implementationGuardRespectsTurnPolicy() throws {
        let decision = AgentRequestRouter.classify("实现新的重试策略")

        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "apply_patch",
            risk: .write,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: []
        ) == nil)

        let requiredRefusal = AgentWorkerRouteGuard.refusal(
            toolName: "apply_patch",
            risk: .write,
            decision: decision,
            delegationPolicy: .required,
            attemptedProfiles: []
        )
        #expect(try #require(requiredRefusal).contains("implementer"))

        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "apply_patch",
            risk: .write,
            decision: decision,
            delegationPolicy: .required,
            attemptedProfiles: ["implementer"]
        ) == nil)

        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "apply_patch",
            risk: .write,
            decision: decision,
            delegationPolicy: .forbidden,
            attemptedProfiles: []
        ) == nil)
    }

    @Test("operator-pinned worker remains delegate-first under automatic policy")
    func pinnedWorkerIsEnforced() {
        let decision = AgentRequestRouter.pinnedDecision(profileID: "implementer")

        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "apply_patch",
            risk: .write,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: []
        ) != nil)
    }

    @Test("production mutation requires an exact ops worker attempt")
    func operationsGuardRequiresOpsWorker() throws {
        let decision = AgentRequestRouter.classify("部署到生产环境")

        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "run_command",
            risk: .danger,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: []
        ) != nil)
        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "run_command",
            risk: .danger,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: ["ops_runner"]
        ) == nil)

        let terminalRefusal = AgentWorkerRouteGuard.refusal(
            toolName: "terminal_send_command",
            risk: .danger,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: []
        )
        let terminalMessage = try #require(terminalRefusal)
        #expect(terminalMessage.contains("target_command"))
        #expect(terminalMessage.contains("visible terminal"))
        #expect(terminalMessage.contains("shell_ready"))
        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "terminal_send_command",
            risk: .danger,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: ["ops_runner"]
        ) == nil)
        // Status/log inspection remains available to the parent; only a
        // command that can mutate state crosses the delegate-first gate.
        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "terminal_send_command",
            risk: .read,
            decision: decision,
            delegationPolicy: .automatic,
            attemptedProfiles: []
        ) == nil)
    }

    @Test("ops worker can inspect the visible terminal before exact command approval")
    @MainActor
    func approvedOpsWorkerGetsBoundedTerminalCapability() {
        let opsRunner = AgentSubagentProfileCatalog.opsRunner
        for tool in AgentSubagentProfileCatalog.terminalOperatorToolNames {
            #expect(opsRunner.effectiveToolNames().contains(tool), "ops_runner 缺 \(tool)")
        }
        #expect(opsRunner.effectiveToolNames(
            approvedCommandGranted: true
        ).contains("terminal_send_command"))
        #expect(!AgentSubagentProfileCatalog.deep.effectiveToolNames(
            approvedCommandGranted: true
        ).contains("terminal_send_command"))

        let command = "kubectl set image deployment/aipipe aipipe=registry/aipipe:1.10.0-rc1"
        let prompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: opsRunner,
            approvedCommand: command
        )
        #expect(prompt.contains(command))
        #expect(prompt.contains("terminal_send_command"))
        #expect(prompt.contains("active SSH tab"))
        #expect(!prompt.contains("You have READ-ONLY access"))

        let hint = AgentWorkerDispatchHint.hint(
            toolName: "terminal_send_command",
            arguments: ["command": .string(command)],
            exitCode: 1
        )
        #expect(hint?.contains("ops_runner") == true)
        #expect(hint?.contains("target_command") == true)
    }

    @Test("host-dispatched workers distinguish requests from actual runs")
    func hostWorkerAccountingDistinguishesRequestsAndRuns() throws {
        let userMessageID = UUID()
        let now = Date()
        let messages = [
            AgentUsageMessageSnapshot(
                id: userMessageID,
                role: .user,
                isOperatorInput: true,
                workerRouteProfileID: "implementer",
                contentCharacterCount: 10,
                createdAt: now
            ),
            AgentUsageMessageSnapshot(
                role: .assistant,
                contentCharacterCount: 20,
                createdAt: now
            ),
        ]
        let started = AgentHostWorkerRunRecord(
            userMessageID: userMessageID,
            profileID: "scout",
            source: .requestPreflight,
            status: .succeeded,
            startedAt: now,
            finishedAt: now,
            model: "someim-32b-scout",
            providerID: "some-im",
            usage: AgentSubagentRunUsage(
                profileID: "scout",
                model: "someim-32b-scout",
                providerID: "some-im",
                usageTokens: 1_000,
                promptTokens: 900,
                completionTokens: 100
            )
        )
        let denied = AgentHostWorkerRunRecord(
            userMessageID: userMessageID,
            profileID: "implementer",
            source: .failedCommandRepair,
            status: .denied,
            finishedAt: now
        )
        let snapshot = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: "glm-5",
            providerID: "some-im",
            providerDisplayName: "some.im",
            createdAt: now,
            updatedAt: now,
            messages: messages,
            hostWorkerRuns: [started, denied]
        )

        let rows = AgentUsageStats.subagentUsage(for: [snapshot])
        #expect(rows.first { $0.profileID == "scout" }?.invocationCount == 1)
        #expect(rows.first { $0.profileID == "scout" }?.runCount == 1)
        #expect(!rows.contains { $0.profileID == "generalist" })
        #expect(rows.first { $0.profileID == "implementer" }?.invocationCount == 1)
        #expect(rows.first { $0.profileID == "implementer" }?.runCount == 0)

        let kpis = AgentUsageStats.skillWorkerKPIs(for: [snapshot])
        #expect(kpis.eligibleUserTurnCount == 1)
        #expect(kpis.workerHandledUserTurnCount == 1)
        #expect(try #require(kpis.workerCoverage) == 1)

        let modelRows = AgentUsageStats.modelUsage(for: [snapshot])
        #expect(modelRows.first { $0.modelID == "someim-32b-scout" }?.totalTokens == 1_000)
    }

    /// A routine unattended log check took an hour instead of about a minute.
    /// The evidence was all gathered inside two minutes; then the delegate-first
    /// route blocked the parent's next command, the `ops_runner` worker died
    /// before its first round (its provider refused the TLS handshake), and the
    /// parent was left with no legal move: the guard steps aside only for a
    /// profile in `attemptedProfiles`, and a failed spawn never wrote to that
    /// set. It could spawn again, fail again, and eventually stop mid-turn.
    /// The turn sat dead until the operator typed "继续".
    ///
    /// The guard's own contract is what the fix leans on, so it is pinned here:
    /// once a trade has been attempted, the parent may proceed itself.
    @Test("a failed delegation attempt lets the parent run the command itself")
    func attemptedProfileLiftsTheOpsRunnerFence() throws {
        let decision = AgentRequestRouter.pinnedDecision(
            profileID: AgentSubagentProfileCatalog.opsRunnerID
        )

        let blocked = AgentWorkerRouteGuard.refusal(
            toolName: "run_command",
            risk: .write,
            decision: decision,
            delegationPolicy: .required,
            attemptedProfiles: []
        )
        #expect(try #require(blocked).contains(AgentSubagentProfileCatalog.opsRunnerID))

        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "run_command",
            risk: .write,
            decision: decision,
            delegationPolicy: .required,
            attemptedProfiles: [AgentSubagentProfileCatalog.opsRunnerID]
        ) == nil)

        // The visible terminal is the other transport the fence covers, and it
        // has to lift on the same signal — otherwise an SSH inspection stays
        // stuck exactly where this one did.
        #expect(AgentWorkerRouteGuard.refusal(
            toolName: "terminal_send_command",
            risk: .write,
            decision: decision,
            delegationPolicy: .required,
            attemptedProfiles: [AgentSubagentProfileCatalog.opsRunnerID]
        ) == nil)
    }

    /// Read-only commands were never the thing this route was protecting, and
    /// an unattended inspection is almost entirely read-only. If the fence ever
    /// starts catching them, every log check pays the delegation round trip.
    @Test("read-only commands never hit the ops_runner fence")
    func readOnlyCommandsAreNotFenced() {
        let decision = AgentRequestRouter.pinnedDecision(
            profileID: AgentSubagentProfileCatalog.opsRunnerID
        )

        for tool in ["run_command", "terminal_send_command"] {
            #expect(AgentWorkerRouteGuard.refusal(
                toolName: tool,
                risk: .read,
                decision: decision,
                delegationPolicy: .required,
                attemptedProfiles: []
            ) == nil, "\(tool) was fenced on a read")
        }
    }
}
