//
//  AgentSubagentReportVerdict.swift
//  WillDeep
//
//  The semantic half of checking a report-only worker.
//
//  `AgentSubagentCitationAudit` already checks what a program can check — the
//  paths, lines and hashes a report names either exist or they do not. Its own
//  header states the limit it cannot cross: "a worker can cite ten real files
//  and still miss the question entirely."
//
//  That is the gap this closes, and it is the first real job `judge` has ever
//  had. The trade was defined, listed in `spawn_agent`'s catalog, and then
//  called by nothing — a bounded-verdict tool with no decision wired to it.
//  Here it reads the task, the report and the citation result, and says
//  whether the report answers what was asked and rests on what it showed.
//
//  Deliberately narrow:
//
//  - Only report-only runs. A run with a verifier is judged by an exit code,
//    which is a better judge than any model.
//  - Never judges `judge`. Its own runs are report-only, so without this the
//    check would call itself forever.
//  - Advisory. The verdict rides along with the report; nothing is suppressed
//    or retried on its say-so. A wrong verdict costs one line of context, not
//    a lost answer.
//

import Foundation

nonisolated enum AgentSubagentReportVerdict {
    enum Verdict: String, Sendable {
        /// Answers the task, and its claims rest on what it cited.
        case supported
        /// Answers the task, but load-bearing claims rest on nothing shown.
        case unsupported
        /// Does not answer the task that was asked.
        case offTopic = "off_topic"
    }

    struct Result: Equatable, Sendable {
        var verdict: String
        var reason: String

        /// Appended to the report the parent model reads. A passing verdict
        /// stays a single self-closing tag — the parent needs to know the
        /// check ran, not to re-read a reason for "nothing wrong".
        var note: String {
            guard verdict != Verdict.supported.rawValue else {
                return "<report-check verdict=\"supported\" />"
            }
            return """
            <report-check verdict="\(verdict)">
            \(reason)
            This is an advisory read of the report against the task it was given — no files were opened. \
            Treat the report's conclusions as unconfirmed on this point.
            </report-check>
            """
        }
    }

    /// Off by nobody's default, but escapable: a user who does not want the
    /// extra call per report-only worker can turn it off.
    static let defaultsKey = "willdeep.agent.judgeReportVerdicts"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// A report too short to contain a claim is not worth a model call.
    static let minimumReportCharacters = 120
    /// Both halves are clamped: the judge has one round and a worker payload
    /// budget, and a 40k report would spend it on the transcript alone.
    static let maximumTaskCharacters = 2_000
    static let maximumReportCharacters = 8_000

    /// Whether this finished run should be judged at all.
    static func shouldJudge(
        profileID: String,
        verifierPassed: Bool?,
        report: String,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        // A verifier's exit code already decided this run.
        guard verifierPassed == nil else { return false }
        // Judging a judge is an infinite regress: its runs are report-only too.
        guard profileID != AgentSubagentProfileCatalog.judgeID else { return false }
        return report.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumReportCharacters
    }

    static let outputSchema = AgentStructuredSchema(
        type: .object,
        properties: [
            "verdict": .init(
                type: .string,
                enumValues: [.string("supported"), .string("unsupported"), .string("off_topic")],
                description: "supported when the report answers the task and its claims rest on what it cited"
            ),
            "reason": .init(
                type: .string,
                description: "one sentence naming the specific claim that is unsupported, or the part of the task left unanswered; empty when supported"
            ),
        ],
        required: ["verdict", "reason"],
        additionalProperties: false
    )

    /// The report arrives with the runner's `<citation-check>` note already
    /// appended, so the deterministic result travels inside `report` — there
    /// is no separate citation argument to pass.
    static func prompt(task: String, report: String) -> String {
        """
        Check one worker's report before it reaches the model that asked for it.

        <task>
        \(clamp(task, to: maximumTaskCharacters))
        </task>

        <report>
        \(clamp(report, to: maximumReportCharacters))
        </report>

        You have no tools and cannot open any file. Judge only what is above.

        - `supported`: it answers the task, and the claims it makes rest on what it showed.
        - `unsupported`: it answers the task, but a load-bearing claim rests on nothing it showed.
        - `off_topic`: it does not answer the task that was asked.

        A report that says it could not do the job, and says why, is `supported` — reporting a
        blocker honestly is a real answer. Confidence is not evidence: a claim stated firmly with
        nothing behind it is `unsupported`. Name the specific claim or the unanswered part in one
        sentence; leave `reason` empty when the verdict is `supported`.
        """
    }

    static func decode(_ payload: String) -> Result? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = object["verdict"] as? String,
              Verdict(rawValue: verdict) != nil else { return nil }
        let reason = (object["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An `unsupported` verdict with no reason tells the parent nothing it
        // can act on, so it is dropped rather than shown as a bare accusation.
        guard verdict == Verdict.supported.rawValue || !reason.isEmpty else { return nil }
        return Result(verdict: verdict, reason: reason)
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        // Keep the tail of a report (conclusions land there) and the head of a
        // task (the ask lands there). One helper, so the caller picks by order.
        return String(text.prefix(limit)) + "\n…(trimmed)"
    }
}
