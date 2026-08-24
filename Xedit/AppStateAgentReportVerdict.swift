//
//  AppStateAgentReportVerdict.swift
//  WillDeep
//
//  Runs `judge` over a finished report-only worker. The decision of whether
//  to run at all, and what to ask, lives in AgentSubagentReportVerdict; this
//  is the side-effecting half — it resolves the judge's own model binding
//  (which only AppState can do) and swallows every failure.
//

import Foundation

extension AppState {
    /// The `<report-check>` note to append to a worker's report, or "" when
    /// this run should not be judged or the judge did not produce a usable
    /// verdict.
    ///
    /// Never throws and never propagates cancellation: the worker's answer is
    /// the deliverable, and losing it because an advisory check failed would
    /// be a strictly worse outcome than not checking.
    func reportVerdictNote(
        profile: AgentSubagentProfile,
        task: String,
        outcome: AgentSubagentRunner.Outcome,
        parentConfiguration: AgentConfiguration
    ) async -> String {
        guard AgentSubagentReportVerdict.shouldJudge(
            profileID: profile.id,
            verifierPassed: outcome.verifierPassed,
            report: outcome.report,
            isEnabled: AgentSubagentReportVerdict.isEnabled()
        ) else { return "" }

        let judge = AgentSubagentProfileStore.resolvedProfile(
            id: AgentSubagentProfileCatalog.judgeID
        )
        let configuration = resolvedSubagentConfiguration(
            for: judge,
            parentConfiguration: parentConfiguration
        )

        do {
            let verdictOutcome = try await AgentSubagentRunner.run(
                prompt: AgentSubagentReportVerdict.prompt(
                    task: task,
                    report: outcome.report
                ),
                configuration: configuration,
                // No tools and no workspace: the judge rules on the text in
                // front of it, so handing it a tree would only invite it to
                // pretend it looked.
                workspaceURL: nil,
                outputSchema: AgentSubagentReportVerdict.outputSchema,
                profile: judge,
                writeAccess: nil,
                verifierCommand: nil
            )
            guard let result = AgentSubagentReportVerdict.decode(verdictOutcome.report) else {
                return ""
            }
            return "\n\n" + result.note
        } catch {
            return ""
        }
    }
}
