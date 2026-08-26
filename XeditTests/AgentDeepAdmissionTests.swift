import Foundation
import Testing
@testable import WillDeep

@Suite
nonisolated struct AgentDeepAdmissionTests {
    // MARK: Ticket parsing

    private func wellFormedTicket(
        attempted: [String] = ["scout"]
    ) -> AgentDeepAdmissionTicket {
        AgentDeepAdmissionTicket(
            reason: "the standard tier ran out of window mid-refactor",
            attemptedProfiles: attempted,
            contextEvidence: "the four call graphs total 380K tokens after digesting",
            whyNotDecompose: "every packet would need the same cross-module invariant"
        )
    }

    @Test("an escalation object parses from a JSON string, as the schema declares it")
    func ticketParsesFromJSONString() {
        let raw = """
        {"reason":"standard tier exhausted its window",
         "attempted_profiles":["scout","reader"],
         "context_evidence":"380K tokens after digesting the logs",
         "why_not_decompose":"one invariant spans every module"}
        """
        let ticket = AgentDeepAdmissionTicket.parse(.string(raw))

        #expect(ticket?.attemptedProfiles == ["scout", "reader"])
        #expect(ticket?.reason == "standard tier exhausted its window")
    }

    @Test("an escalation object parses when the model sends a real object instead")
    func ticketParsesFromObject() {
        // Models routinely ignore "as a JSON STRING" and send the object.
        // Losing a spawn to that costs a round and teaches nobody anything.
        let ticket = AgentDeepAdmissionTicket.parse(.object([
            "reason": .string("standard tier exhausted its window"),
            "attempted_profiles": .array([.string("implementer")]),
            "context_evidence": .string("380K tokens after digesting"),
            "why_not_decompose": .string("one invariant spans every module"),
        ]))

        #expect(ticket?.attemptedProfiles == ["implementer"])
    }

    @Test("a single attempted profile survives losing its brackets")
    func ticketToleratesUnwrappedProfileList() {
        let ticket = AgentDeepAdmissionTicket.parse(.object([
            "reason": .string("standard tier exhausted its window"),
            "attempted_profiles": .string("scout"),
            "context_evidence": .string("380K tokens after digesting"),
            "why_not_decompose": .string("one invariant spans every module"),
        ]))

        #expect(ticket?.attemptedProfiles == ["scout"])
    }

    @Test("an absent or empty escalation argument is no ticket at all")
    func absentTicketParsesToNil() {
        #expect(AgentDeepAdmissionTicket.parse(nil) == nil)
        #expect(AgentDeepAdmissionTicket.parse(.string("   ")) == nil)
        #expect(AgentDeepAdmissionTicket.parse(.object([:])) == nil)
    }

    // MARK: Admission

    @Test("deep without a ticket is refused")
    func deepWithoutTicketIsRefused() {
        let result = AgentDeepAdmission.authorize(
            ticket: nil,
            observation: AgentDeepAdmissionObservation()
        )

        #expect(result == .failure(.ticketMissing))
    }

    @Test("a ticket whose fields say nothing is refused, naming the field")
    func vagueFieldsAreRefused() {
        var observation = AgentDeepAdmissionObservation()
        observation.recordProfileAttempt("scout")
        var ticket = wellFormedTicket()
        ticket.reason = "needed"

        let result = AgentDeepAdmission.authorize(ticket: ticket, observation: observation)

        #expect(result == .failure(.fieldTooVague(field: "reason")))
    }

    @Test("a ticket that names no lower tier is refused")
    func emptyAttemptedProfilesIsRefused() {
        var observation = AgentDeepAdmissionObservation()
        observation.successfulInspections = 5

        let result = AgentDeepAdmission.authorize(
            ticket: wellFormedTicket(attempted: []),
            observation: observation
        )

        #expect(result == .failure(.noAttemptedProfiles))
    }

    @Test("claiming a lower tier the runtime never saw run is refused")
    func unobservedAttemptIsRefused() {
        // This is the gate that matters: the ticket is well-formed and
        // confidently worded, and the session did none of it.
        let result = AgentDeepAdmission.authorize(
            ticket: wellFormedTicket(attempted: ["implementer"]),
            observation: AgentDeepAdmissionObservation()
        )

        #expect(result == .failure(.noCorroboratingWork))
    }

    @Test("an observed lower-tier run admits the escalation")
    func observedAttemptAdmits() {
        var observation = AgentDeepAdmissionObservation()
        observation.recordProfileAttempt("Scout")

        let result = AgentDeepAdmission.authorize(
            ticket: wellFormedTicket(attempted: ["scout"]),
            observation: observation
        )

        #expect((try? result.get()) != nil)
        #expect((try? result.get())?.deepCalls == 1)
    }

    @Test("enough first-hand inspection substitutes for a worker run")
    func inspectionsSubstituteForWorkerAttempt() {
        var observation = AgentDeepAdmissionObservation()
        observation.recordToolSuccess("grep_files")

        // One look is not yet an informed opinion about what fits.
        #expect(AgentDeepAdmission.authorize(
            ticket: wellFormedTicket(attempted: ["reader"]),
            observation: observation
        ) == .failure(.noCorroboratingWork))

        observation.recordToolSuccess("read_file")
        #expect((try? AgentDeepAdmission.authorize(
            ticket: wellFormedTicket(attempted: ["reader"]),
            observation: observation
        ).get())?.deepCalls == 1)
    }

    @Test("only read-only inspection tools accumulate evidence")
    func onlyInspectionToolsCount() {
        var observation = AgentDeepAdmissionObservation()
        observation.recordToolSuccess("run_command")
        observation.recordToolSuccess("write_file")
        observation.recordToolSuccess("spawn_agent")

        #expect(observation.successfulInspections == 0)

        observation.recordToolSuccess("git_log")
        #expect(observation.successfulInspections == 1)
    }

    @Test("deep does not count as its own lower-tier attempt")
    func deepIsNotItsOwnEvidence() {
        var observation = AgentDeepAdmissionObservation()
        observation.recordProfileAttempt("deep")

        #expect(observation.attemptedProfiles.isEmpty)
    }

    @Test("the budget refuses once the session has spent its allowance")
    func budgetIsEnforced() {
        var observation = AgentDeepAdmissionObservation()
        observation.recordProfileAttempt("scout")
        let ticket = wellFormedTicket()

        for _ in 0..<2 {
            guard let updated = try? AgentDeepAdmission.authorize(
                ticket: ticket,
                observation: observation,
                budget: 2
            ).get() else {
                Issue.record("escalation should have been admitted")
                return
            }
            observation = updated
        }

        #expect(AgentDeepAdmission.authorize(
            ticket: ticket,
            observation: observation,
            budget: 2
        ) == .failure(.budgetExhausted(limit: 2)))
    }

    @Test("a zero budget disables deep and says so, without grading the ticket")
    func zeroBudgetDisablesDeep() {
        let result = AgentDeepAdmission.authorize(
            ticket: nil,
            observation: AgentDeepAdmissionObservation(),
            budget: 0
        )

        #expect(result == .failure(.budgetExhausted(limit: 0)))
        // "Deep is turned off" is more actionable than a critique of a
        // ticket that was never going to be accepted.
        #expect(AgentDeepAdmission.Refusal.budgetExhausted(limit: 0)
            .modelFacingMessage.contains("disabled"))
    }

    @Test("the configured budget is clamped to its documented range")
    func budgetIsClamped() {
        #expect(AgentDeepAdmission.clampBudget(-3) == 0)
        #expect(AgentDeepAdmission.clampBudget(99) == AgentDeepAdmission.budgetCeiling)
        #expect(AgentDeepAdmission.clampBudget(3) == 3)
    }

    @Test("every refusal tells the model what to do instead")
    func refusalsAreActionable() {
        let refusals: [AgentDeepAdmission.Refusal] = [
            .ticketMissing,
            .fieldTooVague(field: "reason"),
            .noAttemptedProfiles,
            .noCorroboratingWork,
            .budgetExhausted(limit: 3),
        ]

        for refusal in refusals {
            // A refusal the model cannot act on just becomes a retry with
            // the same arguments.
            #expect(refusal.modelFacingMessage.count > 60)
        }
    }
}
