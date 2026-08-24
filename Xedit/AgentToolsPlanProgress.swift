//
//  AgentToolsPlanProgress.swift
//  WillDeep
//
//  `update_plan` — the model's mid-turn channel for checklist progress.
//
//  Replaces the ```progress fenced block as the primary reporting path
//  (the fence stays readable for compatibility, see
//  LONG_HORIZON_AUTONOMY.md §4.3). The fence's fatal property was never
//  just its grammar: 80% of all blocks ever emitted arrived in a turn's
//  closing prose reply, because these models simply do not narrate
//  between tool rounds. A tool call rides the channel they DO use, and
//  unlike a fence it answers back when a report is malformed.
//

import Foundation

extension AgentToolRunner {
    /// Outcome of one `update_plan` call, carried back out of the
    /// MainActor hop so the payload can be assembled off it.
    private struct PlanProgressOutcome {
        var applied: [AgentPlanProgressUpdate] = []
        var rejections: [AgentPlanProgressRejection] = []
        var stepTexts: [String] = []
        var summary = ""
        var planWasInterrupted = false
    }

    private enum PlanProgressFailure: Error {
        case noRuntime
        case noPlan
    }

    static func updatePlan(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let entries = planProgressEntries(from: arguments)
        guard !entries.isEmpty else {
            throw AgentToolError.missingArgument("updates")
        }
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("update_plan requires a conversational runtime.")
        }
        let note = arguments["note"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome: PlanProgressOutcome
        do {
            outcome = try await MainActor.run { () throws -> PlanProgressOutcome in
                guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID),
                      let runtime = appState.agentRuntimes[runtimeID] else {
                    throw PlanProgressFailure.noRuntime
                }
                guard let plan = runtime.currentPlan, !plan.steps.isEmpty else {
                    throw PlanProgressFailure.noPlan
                }
                var result = PlanProgressOutcome()
                result.stepTexts = plan.steps.map(\.text)
                result.planWasInterrupted = plan.isInterrupted
                let parsed = AgentPlanProgressApplier.parse(
                    entries: entries,
                    stepCount: plan.steps.count
                )
                result.applied = parsed.updates
                result.rejections = parsed.rejections
                guard !parsed.updates.isEmpty else {
                    result.summary = AgentPlanProgressApplier.progressSummary(for: plan)
                    return result
                }
                var next = AgentPlanProgressApplier.apply(
                    AgentPlanProgressApplier.updateMap(parsed.updates),
                    to: plan
                )
                // A progress report against an interrupted plan is the model
                // resuming it — same rule the fenced path applies, so the
                // paused badge clears from either channel.
                next.interruptedAt = nil
                runtime.currentPlan = next
                // Steps settled here outrank whatever a later fence in this
                // same turn says about them (§4.3: tool wins). Steps the tool
                // did NOT mention stay open to the fence, so an end-of-turn
                // recap can still add what the tool never reported.
                runtime.planStepsSettledByToolThisTurn.formUnion(parsed.updates.map(\.stepIndex))
                // The continuation policy counts "did the plan advance this
                // round"; without this a tool-only report looks like no
                // progress and can trip the no-progress pause.
                runtime.planAdvancedByToolSinceLastContinuationDecision = true
                // Persist immediately rather than waiting for the turn defer.
                // A 50-minute single turn used to hold every status change in
                // memory; a crash lost the lot.
                appState.persistAgentSession(
                    runtime: runtime,
                    touchUpdatedAt: false,
                    moveToFront: false
                )
                result.summary = AgentPlanProgressApplier.progressSummary(for: next)
                return result
            }
        } catch PlanProgressFailure.noRuntime {
            throw AgentToolError.invalidArgument("No active app session found for update_plan.")
        } catch PlanProgressFailure.noPlan {
            throw AgentToolError.invalidArgument(
                "There is no active plan to update. Emit a numbered ```plan block first; only then can steps be reported."
            )
        }

        return planProgressResult(outcome: outcome, note: note)
    }

    /// Accepts the declared `stringArray`, and also a single string holding
    /// several entries — providers that flatten arrays (or a model that
    /// sends `"1: done, 2: in_progress"`) must not fail silently over
    /// punctuation.
    private static func planProgressEntries(
        from arguments: [String: AgentJSONValue]
    ) -> [String] {
        guard let raw = arguments["updates"] else { return [] }
        if let list = raw.stringArrayValue(), !list.isEmpty {
            return list
        }
        guard let flat = raw.stringValue() else { return [] }
        return flat
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func planProgressResult(
        outcome: PlanProgressOutcome,
        note: String?
    ) -> AgentToolResult {
        var lines: [String] = []
        if outcome.applied.isEmpty {
            lines.append("Recorded nothing: no entry in `updates` was usable.")
        } else {
            let recorded = outcome.applied
                .sorted { $0.stepNumber < $1.stepNumber }
                .map { update -> String in
                    let text = outcome.stepTexts.indices.contains(update.stepIndex)
                        ? outcome.stepTexts[update.stepIndex]
                        : ""
                    let label = text.isEmpty ? "" : " (\(text.prefix(60)))"
                    return "step \(update.stepNumber) → \(update.status.rawValue)\(label)"
                }
            lines.append("Recorded: \(recorded.joined(separator: ", ")).")
            lines.append("Plan: \(outcome.summary).")
            if outcome.planWasInterrupted {
                lines.append("The plan was paused; this report resumed it.")
            }
        }
        if !outcome.rejections.isEmpty {
            let detail = outcome.rejections
                .map { "\"\($0.entry)\" — \($0.reason)" }
                .joined(separator: "; ")
            lines.append("Rejected \(outcome.rejections.count) entry/entries: \(detail). Re-send those in the form `<step number>: <status>`.")
        }
        if let note, !note.isEmpty {
            lines.append("Note recorded for the user: \(note)")
        }
        let summaryDetail: String
        if outcome.applied.isEmpty {
            summaryDetail = "no usable entry"
        } else {
            summaryDetail = outcome.applied
                .sorted { $0.stepNumber < $1.stepNumber }
                .map { "\($0.stepNumber)→\($0.status.rawValue)" }
                .joined(separator: " ")
        }
        return AgentToolResult(
            summary: "update_plan: \(summaryDetail)",
            payload: lines.joined(separator: "\n")
        )
    }
}
