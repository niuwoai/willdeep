//
//  AgentPlanProgressApplier.swift
//  WillDeep
//
//  Shared write path for plan step progress, used by BOTH reporting
//  channels so they can never drift apart:
//
//   1. the `update_plan` tool (primary since 1.286.0) — see
//      `AgentToolRunner.updatePlan`;
//   2. the legacy ```progress fenced block (compat path) — see
//      `AgentPlanParser.progressUpdates`.
//
//  Why the tool exists at all: the fence was never a parsing problem
//  alone. Forensics over every persisted session (docs/
//  AGENT_EXECUTION_FRICTION_AUDIT_2026_08.md §1.6) found 80% of all
//  `progress` blocks arriving in the turn's closing prose-only reply —
//  a 50-minute, 34-tool-call turn moved the checklist exactly zero
//  times until it ended. The models do not write prose between tool
//  rounds; they do call tools. Reporting through a tool rides the one
//  channel they use mid-turn, and it can answer back ("2 entries
//  applied, 1 rejected") where a fence fails silently.
//

import Foundation

/// One step's new status, addressed the way the model already thinks
/// about it: the 1-based number printed in the `plan` block.
nonisolated struct AgentPlanProgressUpdate: Equatable, Sendable {
    /// 1-based step number as shown to the model.
    let stepNumber: Int
    let status: AgentPlan.StepStatus

    /// 0-based index into `AgentPlan.steps`.
    var stepIndex: Int { stepNumber - 1 }
}

/// A tool entry that could not be turned into an update, plus the reason
/// in the model's own terms. Never silently dropped: the whole point of
/// the tool channel is that a malformed report gets answered.
nonisolated struct AgentPlanProgressRejection: Equatable, Sendable, Error {
    let entry: String
    let reason: String
}

nonisolated enum AgentPlanProgressApplier {
    /// Canonical status tokens, in the order the tool description lists
    /// them. Synonyms are still accepted (`parseStatusToken`), but this is
    /// what we teach and what an error message quotes back.
    static let canonicalStatusTokens = ["pending", "in_progress", "done", "skipped", "failed"]

    /// Apply `updates` (keyed by 0-based step index) to `plan`.
    ///
    /// Lifecycle promotion lives here rather than at either call site, so
    /// the tool and the fence agree on when a plan becomes `.executing`
    /// or `.done`:
    ///  - any touched step promotes `.approved` → `.executing`;
    ///  - every step terminal promotes to `.done`.
    ///
    /// `.rejected` and `.proposed` are deliberately left alone — a plan
    /// the user has not accepted must not be advanced by a report.
    static func apply(
        _ updates: [Int: AgentPlan.StepStatus],
        to plan: AgentPlan
    ) -> AgentPlan {
        guard !updates.isEmpty else { return plan }
        var next = plan
        for (index, status) in updates where next.steps.indices.contains(index) {
            next.steps[index].status = status
        }
        if next.steps.allSatisfy({ [.done, .skipped, .failed].contains($0.status) }) {
            next.status = .done
        } else if next.status == .approved {
            next.status = .executing
        }
        return next
    }

    /// Parse the tool's `updates` array. Each entry is `<step>:<status>`;
    /// `1: done`, `1 - done`, `step 1 = done` and `1.done` all read the
    /// same, because a schema that only accepts one punctuation mark just
    /// moves the silent failure somewhere else.
    ///
    /// Strictness that IS kept: the step number must exist in the plan,
    /// and the status word must be recognizable. Both failures come back
    /// to the model as text it can act on.
    static func parse(
        entries: [String],
        stepCount: Int
    ) -> (updates: [AgentPlanProgressUpdate], rejections: [AgentPlanProgressRejection]) {
        var updates: [AgentPlanProgressUpdate] = []
        var rejections: [AgentPlanProgressRejection] = []
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            switch parseEntry(entry, stepCount: stepCount) {
            case .success(let update):
                // Later entries win, matching the fence's last-writer-wins
                // rule for a model that lists the same step twice.
                updates.removeAll { $0.stepNumber == update.stepNumber }
                updates.append(update)
            case .failure(let rejection):
                rejections.append(rejection)
            }
        }
        return (updates, rejections)
    }

    /// Keyed form for `apply`.
    static func updateMap(_ updates: [AgentPlanProgressUpdate]) -> [Int: AgentPlan.StepStatus] {
        var map: [Int: AgentPlan.StepStatus] = [:]
        for update in updates {
            map[update.stepIndex] = update.status
        }
        return map
    }

    private static func parseEntry(
        _ entry: String,
        stepCount: Int
    ) -> Result<AgentPlanProgressUpdate, AgentPlanProgressRejection> {
        var scanner = Substring(entry)
        // Optional `step` / `#` / 「步骤」 prefix — models add one about a
        // third of the time and it carries no information either way.
        let lowercasedEntry = entry.lowercased()
        if let prefix = ["step ", "step#", "step", "#", "步骤"]
            .first(where: { lowercasedEntry.hasPrefix($0) }) {
            scanner = scanner.dropFirst(prefix.count)
        }
        scanner = Substring(scanner.trimmingCharacters(in: .whitespaces))
        let digits = scanner.prefix { $0.isNumber }
        guard !digits.isEmpty, let stepNumber = Int(digits) else {
            return .failure(
                AgentPlanProgressRejection(
                    entry: entry,
                    reason: "does not start with a step number; expected `<step number>: <status>`"
                )
            )
        }
        guard stepNumber >= 1, stepNumber <= stepCount else {
            return .failure(
                AgentPlanProgressRejection(
                    entry: entry,
                    reason: stepCount == 0
                        ? "the active plan has no steps"
                        : "step \(stepNumber) is outside the active plan (it has \(stepCount) steps)"
                )
            )
        }
        let remainder = scanner
            .dropFirst(digits.count)
            .drop { $0 == ":" || $0 == "：" || $0 == "." || $0 == ")" || $0 == "-"
                || $0 == "=" || $0 == "、" || $0 == " " || $0 == "\t" }
            .trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else {
            return .failure(
                AgentPlanProgressRejection(
                    entry: entry,
                    reason: "has a step number but no status; expected one of \(canonicalStatusTokens.joined(separator: ", "))"
                )
            )
        }
        guard let status = parseStatusToken(remainder) else {
            return .failure(
                AgentPlanProgressRejection(
                    entry: entry,
                    reason: "\"\(remainder)\" is not a status; expected one of \(canonicalStatusTokens.joined(separator: ", "))"
                )
            )
        }
        return .success(AgentPlanProgressUpdate(stepNumber: stepNumber, status: status))
    }

    /// The status half of an entry. Reuses the fence's token table (English,
    /// Chinese and the ✅ family) so a model that learned one channel is not
    /// punished on the other; anything with trailing commentary
    /// (`done — tests pass`) keeps only its leading word.
    static func parseStatusToken(_ raw: String) -> AgentPlan.StepStatus? {
        let lowered = raw.lowercased()
        if let direct = AgentPlanParser.parseStepStatus(lowered) {
            return direct
        }
        let head = lowered
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "—" || $0 == "–" || $0 == "," || $0 == "，" })
            .first
            .map(String.init)
        guard let head, head != lowered else { return nil }
        return AgentPlanParser.parseStepStatus(head)
    }

    /// One-line human summary for the tool result and the transcript row:
    /// `2/7 done · executing`.
    static func progressSummary(for plan: AgentPlan) -> String {
        let terminal = plan.steps.filter { [.done, .skipped, .failed].contains($0.status) }.count
        return "\(terminal)/\(plan.steps.count) settled · \(plan.status.rawValue)"
    }
}
