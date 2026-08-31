import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSubagentWriteAccessTests {
    private let access = AgentSubagentWriteAccess(targetRelativePath: "Sources/Auth.swift")

    private func diff(path: String) -> String {
        """
        --- a/\(path)
        +++ b/\(path)
        @@ -1,3 +1,3 @@
         line one
        -line two
        +line two changed
         line three
        """
    }

    private func argumentsJSON(diff: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["diff": diff])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Path normalization

    @Test("relative paths normalize, traversal and absolute paths are refused")
    func normalizationRejectsEscapes() {
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("./Sources/Auth.swift") == "Sources/Auth.swift")
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("Sources//Auth.swift") == "Sources/Auth.swift")

        // Refused rather than resolved: the approval card showed a relative
        // path, and resolving could quietly land elsewhere.
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("/etc/passwd") == nil)
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("~/secrets") == nil)
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("../outside.swift") == nil)
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("Sources/../../x") == nil)
        #expect(AgentSubagentWriteAccess.normalizedTargetPath("   ") == nil)
    }

    // MARK: Patch scoping

    @Test("a patch to the approved file is allowed")
    func targetFilePatchPasses() {
        let violation = access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: diff(path: "Sources/Auth.swift")),
            workspaceURL: nil
        )

        #expect(violation == nil)
    }

    @Test("a patch to any other file is denied and names both paths")
    func otherFilePatchIsDenied() throws {
        let violation = try #require(access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: diff(path: "Sources/Other.swift")),
            workspaceURL: nil
        ))

        #expect(violation.contains("Sources/Other.swift"))
        #expect(violation.contains("Sources/Auth.swift"))
    }

    @Test("a multi-file patch is denied even when it includes the approved file")
    func multiFilePatchIsDenied() {
        let combined = diff(path: "Sources/Auth.swift") + "\n" + diff(path: "Sources/Other.swift")

        let violation = access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: combined),
            workspaceURL: nil
        )

        #expect(violation != nil)
    }

    @Test("a declared new file may be created but deletion stays denied")
    func declaredCreationIsAllowedAndDeletionIsDenied() throws {
        let creation = """
        --- /dev/null
        +++ b/Sources/Auth.swift
        @@ -0,0 +1,1 @@
        +new
        """

        #expect(access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: creation),
            workspaceURL: nil
        ) == nil)

        let deletion = """
        --- a/Sources/Auth.swift
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -old
        """
        let violation = try #require(access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: deletion),
            workspaceURL: nil
        ))
        #expect(violation.contains("cannot delete"))
    }

    @Test("create_file is allowed only for a declared path")
    func createFileChecksTheSameWriteSet() {
        #expect(access.violationMessage(
            forToolName: "create_file",
            argumentsJSON: #"{"path":"Sources/Auth.swift","content":"new"}"#,
            workspaceURL: nil
        ) == nil)
        #expect(access.violationMessage(
            forToolName: "create_file",
            argumentsJSON: #"{"path":"Sources/Other.swift","content":"new"}"#,
            workspaceURL: nil
        ) != nil)
    }

    @Test("a writing worker may declare at most sixteen paths")
    func writeSetHasAReviewableCeiling() {
        let sixteen = (0..<16).map { "Sources/File\($0).swift" }
        let seventeen = (0..<17).map { "Sources/File\($0).swift" }

        #expect(AgentSubagentWriteAccess(targetRelativePaths: sixteen) != nil)
        #expect(AgentSubagentWriteAccess(targetRelativePaths: seventeen) == nil)
    }

    @Test("a malformed or missing diff is denied rather than passed through")
    func malformedDiffIsDenied() {
        #expect(access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: "{}",
            workspaceURL: nil
        ) != nil)
        #expect(access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: "just some prose, no headers"),
            workspaceURL: nil
        ) != nil)
    }

    @Test("diff headers with trailing timestamps still resolve")
    func timestampedHeadersParse() {
        let timestamped = """
        --- a/Sources/Auth.swift\t2026-08-06 10:00:00
        +++ b/Sources/Auth.swift\t2026-08-06 10:05:00
        @@ -1,1 +1,1 @@
        -a
        +b
        """

        #expect(access.violationMessage(
            forToolName: "apply_patch",
            argumentsJSON: argumentsJSON(diff: timestamped),
            workspaceURL: nil
        ) == nil)
    }
}

@Suite
@MainActor
struct AgentSubagentEditorLockTests {
    @Test("a second editor cannot claim a file that is already being edited")
    func lockExcludesConcurrentEditors() {
        let lock = AgentSubagentEditorLock.shared
        let parent = UUID()
        let first = UUID()
        let second = UUID()
        defer {
            lock.release(runID: first)
            lock.release(runID: second)
        }

        #expect(lock.acquire(path: "A.swift", parentRuntimeID: parent, runID: first))
        #expect(!lock.acquire(path: "A.swift", parentRuntimeID: parent, runID: second))
        // A different file is unaffected.
        #expect(lock.acquire(path: "B.swift", parentRuntimeID: parent, runID: second))
    }

    @Test("releasing frees the file for the next editor")
    func releaseFreesTheFile() {
        let lock = AgentSubagentEditorLock.shared
        let parent = UUID()
        let first = UUID()
        let second = UUID()
        defer { lock.release(runID: second) }

        #expect(lock.acquire(path: "C.swift", parentRuntimeID: parent, runID: first))
        lock.release(runID: first)

        #expect(!lock.isLocked(path: "C.swift", parentRuntimeID: parent))
        #expect(lock.acquire(path: "C.swift", parentRuntimeID: parent, runID: second))
    }

    @Test("the same run re-acquiring its own file is not a conflict")
    func reacquireBySameRunSucceeds() {
        let lock = AgentSubagentEditorLock.shared
        let parent = UUID()
        let runID = UUID()
        defer { lock.release(runID: runID) }

        #expect(lock.acquire(path: "D.swift", parentRuntimeID: parent, runID: runID))
        // Escalation re-runs under the same run id and must not deadlock.
        #expect(lock.acquire(path: "D.swift", parentRuntimeID: parent, runID: runID))
    }

    @Test("locks are scoped per parent session")
    func lockIsScopedPerSession() {
        let lock = AgentSubagentEditorLock.shared
        let runA = UUID()
        let runB = UUID()
        defer {
            lock.release(runID: runA)
            lock.release(runID: runB)
        }

        #expect(lock.acquire(path: "E.swift", parentRuntimeID: UUID(), runID: runA))
        #expect(lock.acquire(path: "E.swift", parentRuntimeID: UUID(), runID: runB))
    }
}

@Suite
@MainActor
struct AgentSubagentEscalationTests {
    private func outcome(report: String, roundCount: Int) -> AgentSubagentRunner.Outcome {
        AgentSubagentRunner.Outcome(
            report: report,
            usageTokens: 100,
            roundCount: roundCount,
            toolInvocationCount: 1
        )
    }

    @Test("a stalled cheap trade escalates")
    func roundCapTriggersEscalation() {
        let scout = AgentSubagentProfileCatalog.scout

        #expect(AgentSubagentEscalation.shouldEscalate(
            outcome: outcome(report: "a decent length report about where things are", roundCount: scout.maxRounds),
            profile: scout
        ))
    }

    @Test("an empty report escalates, not merely a short one")
    func emptyReportTriggersEscalation() {
        #expect(AgentSubagentEscalation.shouldEscalate(
            outcome: outcome(report: "", roundCount: 2),
            profile: AgentSubagentProfileCatalog.scout
        ))
    }

    @Test("a real answer within budget does not escalate")
    func goodOutcomeDoesNotEscalate() {
        #expect(!AgentSubagentEscalation.shouldEscalate(
            outcome: outcome(
                report: "AgentSubagents.swift:471 defines allowedToolNames; the filter runs at line 478.",
                roundCount: 3
            ),
            profile: AgentSubagentProfileCatalog.scout
        ))
    }

    @Test("deep never escalates — there is nothing above it")
    func deepNeverEscalates() {
        #expect(!AgentSubagentEscalation.shouldEscalate(
            outcome: outcome(report: "", roundCount: AgentSubagentProfileCatalog.deep.maxRounds),
            profile: AgentSubagentProfileCatalog.deep
        ))
    }

    @Test("the retry advances one configured tier without widening tools or budgets")
    func escalatedProfileKeepsAuthority() {
        let escalated = AgentSubagentEscalation.escalatedProfile(
            from: AgentSubagentProfileCatalog.scout
        )

        #expect(escalated.modelBinding.workerTier == .advanced)
        #expect(escalated.toolNames == AgentSubagentProfileCatalog.scout.toolNames)
        #expect(escalated.maxRounds == AgentSubagentProfileCatalog.scout.maxRounds)
        // Only upward, and only once.
        #expect(escalated.escalation == .none)
    }

    @Test("an escalated editor keeps its single-file write scope")
    func escalatedEditorStaysScoped() {
        let escalated = AgentSubagentEscalation.escalatedProfile(
            from: AgentSubagentProfileCatalog.editor
        )

        #expect(escalated.requiresWriteAccess)
        #expect(escalated.toolNames == AgentSubagentProfileCatalog.editor.toolNames)
        #expect(!escalated.toolNames.contains("run_command"))
    }

    @Test("provider context-overflow errors are recognized")
    func contextOverflowDetection() {
        struct StubError: LocalizedError {
            let errorDescription: String?
        }

        #expect(AgentSubagentEscalation.isContextOverflow(
            StubError(errorDescription: "This model's maximum context length is 128000 tokens")
        ))
        #expect(!AgentSubagentEscalation.isContextOverflow(
            StubError(errorDescription: "401 Unauthorized")
        ))
    }

    @Test("escalation is recorded on the transcript, not left silent")
    func transcriptRecordsEscalation() throws {
        let transcript = AgentSubagentTranscript(
            runID: UUID(),
            label: "find auth",
            prompt: "where is auth",
            model: "claude-opus-5",
            profileID: "scout",
            escalatedFromModel: "glm-5"
        )

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(AgentSubagentTranscript.self, from: data)

        #expect(decoded.profileID == "scout")
        #expect(decoded.escalatedFromModel == "glm-5")
    }

    @Test("records written before profiles existed still decode")
    func legacyTranscriptDecodes() throws {
        let legacy = """
        {
          "runID": "\(UUID().uuidString)",
          "label": "old run",
          "prompt": "p",
          "model": "m",
          "status": "completed",
          "rounds": [],
          "report": "r",
          "usageTokens": 0,
          "startedAt": "2026-01-01T00:00:00Z",
          "didTruncate": false
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSubagentTranscript.self, from: Data(legacy.utf8))

        #expect(decoded.profileID == nil)
        #expect(decoded.escalatedFromModel == nil)
    }
}
