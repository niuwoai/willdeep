//
//  AgentSubagentCitationAuditTests.swift
//  WillDeepTests
//
//  The check has to hold in both directions. Catching an invented path is the
//  point; not flagging a real one is what keeps the check switched on.
//

import Foundation
import Testing

@testable import WillDeep

@Suite("Subagent citation audit")
struct AgentSubagentCitationAuditTests {
    private func makeWorkspace(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xedit-citations-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try "one\ntwo\nthree\n".write(
            to: root.appendingPathComponent("Sources/Real.swift"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    @Test("A real path and an in-range line are not flagged")
    func realCitationsSurvive() throws {
        let root = try makeWorkspace("clean")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AgentSubagentCitationAudit.audit(
            report: "The handler lives in `Sources/Real.swift:2`, and `Sources/Real.swift` has no other callers.",
            workspaceURL: root
        )
        #expect(result.checked == 2)
        #expect(result.unverifiable.isEmpty)
        #expect(result.note == "<citation-check checked=\"2\" unverifiable=\"0\" />")
    }

    @Test("An invented path and a line past the end both point at nothing")
    func inventedCitationsAreCaught() throws {
        let root = try makeWorkspace("dirty")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AgentSubagentCitationAudit.audit(
            report: "See `Sources/Invented.swift:10` and `Sources/Real.swift:900` for the retry logic.",
            workspaceURL: root
        )
        #expect(result.checked == 2)
        #expect(result.unverifiable.count == 2)
        // The note names the offenders: a count alone tells the parent that
        // something is wrong without telling it what to stop believing.
        #expect(result.note?.contains("Sources/Invented.swift:10") == true)
        #expect(result.note?.contains("Sources/Real.swift:900") == true)
    }

    @Test("Prose is not a citation, and nothing checked is not a clean sheet")
    func proseIsNotCounted() throws {
        let root = try makeWorkspace("prose")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AgentSubagentCitationAudit.audit(
            report: "The retry logic looks correct to me, though I did not read the tests.",
            workspaceURL: root
        )
        #expect(result.checked == 0)
        #expect(result.note == nil)
    }

    @Test("Token shapes the parser must and must not treat as citations")
    func tokenClassification() {
        #expect(AgentSubagentCitationAudit.pathCitation(in: "Sources/Real.swift:12")?.line == 12)
        #expect(AgentSubagentCitationAudit.pathCitation(in: "Sources/Real.swift")?.line == nil)
        // Absolute paths, URLs and bare words are somebody else's business.
        #expect(AgentSubagentCitationAudit.pathCitation(in: "/etc/hosts") == nil)
        #expect(AgentSubagentCitationAudit.pathCitation(in: "https://example.com/a.html") == nil)
        #expect(AgentSubagentCitationAudit.pathCitation(in: "retryBudget") == nil)

        #expect(AgentSubagentCitationAudit.isCommitHash("0badc0de1234"))
        // Pure letters or pure digits are words and numbers, not hashes.
        #expect(!AgentSubagentCitationAudit.isCommitHash("deadbeef"))
        #expect(!AgentSubagentCitationAudit.isCommitHash("12345678"))
        #expect(!AgentSubagentCitationAudit.isCommitHash("abc"))
    }

    @Test("A commit that does not resolve is flagged; a real one is not")
    func commitCitations() throws {
        let root = try makeWorkspace("commits")
        defer { try? FileManager.default.removeItem(at: root) }

        for arguments in [
            ["init", "--quiet", "--initial-branch=main"],
            ["add", "."],
            [
                "-c", "user.name=range", "-c", "user.email=range@local",
                "commit", "--quiet", "-m", "seed",
            ],
        ] {
            _ = AppState.runGitCommand(arguments: arguments, in: root)
        }
        let head = AppState.runGit(arguments: ["rev-parse", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!head.isEmpty)

        let result = AgentSubagentCitationAudit.audit(
            report: "Introduced in \(head), not in 0badc0de1234 as the report claimed.",
            workspaceURL: root
        )
        #expect(result.checked == 2)
        #expect(result.unverifiable == ["0badc0de1234"])
    }

    @Test("Citation accuracy is nil until something has been checked")
    func kpiTreatsEmptyDenominatorAsNoData() {
        var kpis = AgentSkillWorkerKPIs()
        #expect(kpis.citationAccuracy == nil)
        kpis.citationsChecked = 4
        kpis.citationsResolved = 3
        #expect(kpis.citationAccuracy == 0.75)
    }
}
