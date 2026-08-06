//
//  AgentEditFileToolTests.swift
//  WillDeepTests
//
//  Covers the edit_file tool's exact-string-replacement edit synthesis.
//  edit_file hands the model a (path, old_string, new_string) surface and
//  internally builds a machine-accurate unified diff that the existing
//  apply_patch pipeline parses + applies. These tests lock the invariant
//  that makes edit_file reliable where hand-written diffs weren't: the
//  synthesized diff, applied to the original content through the shared
//  applier, must reproduce the expected new content byte-for-byte.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentEditFileToolTests {
    /// makeEdit → parse → apply must reproduce `Edit.newContent` exactly.
    /// (makeEdit performs this same round-trip internally and throws on
    /// mismatch; asserting here keeps the invariant visible in tests.)
    @discardableResult
    private func roundTrip(
        content: String,
        old: String,
        new: String,
        replaceAll: Bool = false
    ) throws -> AgentEditFileSupport.Edit {
        let edit = try AgentEditFileSupport.makeEdit(
            path: "sample.txt",
            oldContent: content,
            oldString: old,
            newString: new,
            replaceAll: replaceAll
        )
        let change = try #require(try AgentPatchApplier.parse(edit.diff).first)
        #expect(change.path == "sample.txt")
        #expect(try AgentPatchApplier.apply(change, to: content) == edit.newContent)
        return edit
    }

    @Test
    func singleLineReplacementRoundTrips() throws {
        let edit = try roundTrip(
            content: "alpha\nbeta\ngamma\n",
            old: "beta",
            new: "BETA"
        )
        #expect(edit.newContent == "alpha\nBETA\ngamma\n")
        #expect(edit.occurrences == 1)
    }

    @Test
    func multiLineOldStringRoundTrips() throws {
        let content = "one\ntwo\nthree\nfour\nfive\n"
        let edit = try roundTrip(
            content: content,
            old: "two\nthree\nfour",
            new: "TWO\nTHREE"
        )
        #expect(edit.newContent == "one\nTWO\nTHREE\nfive\n")
    }

    @Test
    func partialLineReplacementRoundTrips() throws {
        let edit = try roundTrip(
            content: "let value = 1\nlet other = 2\n",
            old: "value = 1",
            new: "value = 42"
        )
        #expect(edit.newContent == "let value = 42\nlet other = 2\n")
    }

    @Test
    func replacementAtFileStartAndUnterminatedEndRoundTrips() throws {
        // No trailing newline; edits touch both the first and last line.
        let edit = try roundTrip(
            content: "first\nmiddle\nlast",
            old: "first",
            new: "FIRST"
        )
        #expect(edit.newContent == "FIRST\nmiddle\nlast")

        let tail = try roundTrip(
            content: "first\nmiddle\nlast",
            old: "last",
            new: "LAST"
        )
        #expect(tail.newContent == "first\nmiddle\nLAST")
    }

    @Test
    func emptyNewStringDeletesText() throws {
        let edit = try roundTrip(
            content: "keep\ndrop this line\nkeep too\n",
            old: "drop this line\n",
            new: ""
        )
        #expect(edit.newContent == "keep\nkeep too\n")
    }

    @Test
    func wholeLineReplacementKeepingNewlineRoundTrips() throws {
        let edit = try roundTrip(
            content: "keep\nold line\nkeep too\n",
            old: "old line\n",
            new: "new line\n"
        )
        #expect(edit.newContent == "keep\nnew line\nkeep too\n")
    }

    @Test
    func replacementConsumingNewlineMergesWithNextLine() throws {
        // old_string eats the line terminator but new_string has none —
        // the edit must merge with the following line, exactly as the
        // character-level replacement does.
        let edit = try roundTrip(
            content: "a value\nnext\n",
            old: "value\n",
            new: "X"
        )
        #expect(edit.newContent == "a Xnext\n")
    }

    @Test
    func replaceAllReplacesScatteredOccurrencesAsSeparateHunks() throws {
        // Occurrences far apart (> 2×context lines) become separate hunks.
        let filler = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let content = "TOKEN start\n\(filler)\nTOKEN end\n"
        let edit = try roundTrip(content: content, old: "TOKEN", new: "SYMBOL", replaceAll: true)
        #expect(edit.occurrences == 2)
        #expect(edit.newContent.contains("SYMBOL start"))
        #expect(edit.newContent.contains("SYMBOL end"))
        #expect(edit.diff.components(separatedBy: "@@ -").count == 3) // 2 hunks
    }

    @Test
    func replaceAllMergesAdjacentOccurrencesIntoOneHunk() throws {
        let content = "a TOKEN b\nc TOKEN d\ne\n"
        let edit = try roundTrip(content: content, old: "TOKEN", new: "X", replaceAll: true)
        #expect(edit.occurrences == 2)
        #expect(edit.newContent == "a X b\nc X d\ne\n")
        #expect(edit.diff.components(separatedBy: "@@ -").count == 2) // 1 hunk
    }

    @Test
    func multipleOccurrencesOnOneLineReplaceAll() throws {
        let edit = try roundTrip(
            content: "foo(foo)\nbar\n",
            old: "foo",
            new: "qux",
            replaceAll: true
        )
        #expect(edit.newContent == "qux(qux)\nbar\n")
        #expect(edit.occurrences == 2)
    }

    @Test
    func removedSqlCommentLineRoundTrips() throws {
        // A removed line starting "-- " serializes as "--- …" in the diff;
        // the parser must not mistake it for a file header inside a hunk.
        let content = "SELECT 1;\n-- old comment\nSELECT 2;\n"
        let edit = try roundTrip(
            content: content,
            old: "-- old comment\n",
            new: ""
        )
        #expect(edit.newContent == "SELECT 1;\nSELECT 2;\n")
    }

    @Test
    func unicodeContentRoundTrips() throws {
        let edit = try roundTrip(
            content: "第一行 🚀\n第二行内容\n第三行\n",
            old: "第二行内容",
            new: "第二行已改 ✅"
        )
        #expect(edit.newContent == "第一行 🚀\n第二行已改 ✅\n第三行\n")
    }

    @Test("GitHub Actions expressions remain literal during exact replacement")
    func githubActionsExpressionsRoundTrip() throws {
        let content = """
        env:
          DEPLOY_TOKEN: ${{ secrets.OLD_DEPLOY_TOKEN }}
        """
        let edit = try roundTrip(
            content: content,
            old: "${{ secrets.OLD_DEPLOY_TOKEN }}",
            new: "${{ secrets.DEPLOY_TOKEN }}"
        )
        #expect(edit.newContent.contains("DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}"))
    }

    @Test
    func oldStringNotFoundThrows() {
        #expect(throws: AgentEditFileError.oldStringNotFound("sample.txt", hint: nil)) {
            try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: "alpha\nbeta\n",
                oldString: "missing",
                newString: "x",
                replaceAll: false
            )
        }
    }

    @Test
    func ambiguousOldStringThrowsWithCount() {
        #expect(throws: AgentEditFileError.oldStringNotUnique("sample.txt", 2)) {
            try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: "dup\nother\ndup\n",
                oldString: "dup",
                newString: "x",
                replaceAll: false
            )
        }
    }

    @Test
    func identicalOldAndNewStringsThrow() {
        #expect(throws: AgentEditFileError.identicalReplacement("sample.txt")) {
            try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: "alpha\n",
                oldString: "alpha",
                newString: "alpha",
                replaceAll: false
            )
        }
    }

    @Test
    func emptyOldStringThrows() {
        #expect(throws: AgentEditFileError.emptyOldString) {
            try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: "alpha\n",
                oldString: "",
                newString: "x",
                replaceAll: false
            )
        }
    }

    // MARK: - Whitespace-tolerant fallback

    @Test("trailing whitespace differences no longer fail the edit")
    func trailingWhitespaceMismatchStillMatches() throws {
        // File has trailing spaces the model can't see in read_file output.
        let content = "func a() {   \n    body()\t\n}\n"
        let edit = try roundTrip(
            content: content,
            old: "func a() {\n    body()\n}",
            new: "func a() {\n    body2()\n}"
        )
        #expect(edit.newContent == "func a() {\n    body2()\n}\n")
    }

    @Test("CRLF files fail with an actionable line-ending hint, not a crash or internal error")
    func crlfContentReportsLineEndingHint() {
        // The applier's diff parser splits on .newlines, so "\r" hunk lines
        // can never round-trip — the fallback must refuse CRLF windows and
        // the error must tell the model to normalize line endings.
        let content = "one\r\ntwo\r\nthree\r\n"
        do {
            _ = try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: content,
                oldString: "two\nthree",
                newString: "TWO\nTHREE",
                replaceAll: false
            )
            Issue.record("expected a CRLF-related error")
        } catch let error as AgentEditFileError {
            #expect(error.errorDescription?.contains("CRLF") == true)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("uniformly shifted indentation matches and re-indents new_string")
    func uniformIndentShiftMatchesAndReindents() throws {
        let content = "start\n        let a = 1\n        let b = 2\nend\n"
        // Model lost one indent level on every line; new_string is written
        // at the same (wrong) level and must be shifted back.
        let edit = try roundTrip(
            content: content,
            old: "    let a = 1\n    let b = 2",
            new: "    let a = 10\n    let b = 20"
        )
        #expect(edit.newContent == "start\n        let a = 10\n        let b = 20\nend\n")
    }

    @Test("indent-tolerant match still rejects ambiguity")
    func indentTolerantMatchRejectsAmbiguity() {
        let content = "if x {\n    call()\n}\nif y {\n        call()\n}\n"
        #expect(throws: AgentEditFileError.oldStringNotUnique("sample.txt", 2)) {
            try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: content,
                oldString: "  call()",
                newString: "  other()",
                replaceAll: false
            )
        }
    }

    @Test("non-uniform indentation divergence stays a hard error")
    func nonUniformIndentDoesNotMatch() {
        // Line 1 is over-indented by 2, line 2 by 4 — no uniform shift
        // explains both, so this must NOT silently match anywhere.
        let content = "    aa\n    b\n"
        #expect(throws: AgentEditFileError.self) {
            try AgentEditFileSupport.makeEdit(
                path: "sample.txt",
                oldContent: content,
                oldString: "  aa\n      b",
                newString: "x",
                replaceAll: false
            )
        }
    }

    @Test("line-number prefixes in old_string produce a targeted hint")
    func lineNumberPrefixHint() {
        let hint = AgentEditFileSupport.notFoundHint(
            oldContent: "alpha\nbeta\n",
            oldString: "    1  alpha\n    2  beta"
        )
        #expect(hint?.contains("line-number prefixes") == true)
    }

    @Test("diverging-after-first-line failures report the anchor line")
    func firstLineAnchorHint() {
        let hint = AgentEditFileSupport.notFoundHint(
            oldContent: "one\ntwo\nthree\n",
            oldString: "two\nTHREE-noexist"
        )
        #expect(hint?.contains("file line 2") == true)
    }

    // MARK: - Tool surface

    @Test("edit_file queues a patch proposal without writing files")
    @MainActor
    func toolQueuesProposalWithoutWritingFiles() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_edit_file_tool_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        try "let value = 1\nlet other = 2\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var queuedProposal: AgentPatchProposal?
        let context = AgentToolContext(
            rootDirectory: workspace,
            patchProposalSink: { title, diff, _ in
                let proposal = AgentPatchProposal(
                    messageID: UUID(),
                    title: title ?? "Agent Patch",
                    diff: diff
                )
                queuedProposal = proposal
                return proposal
            }
        )

        let result = try await AgentToolRunner.run(
            name: "edit_file",
            arguments: [
                "path": .string("Sample.swift"),
                "old_string": .string("let value = 1"),
                "new_string": .string("let value = 2")
            ],
            context: context
        )

        let proposal = try #require(queuedProposal)
        #expect(proposal.title == "编辑文件: Sample.swift")
        let change = try #require(try AgentPatchApplier.parse(proposal.diff).first)
        let applied = try AgentPatchApplier.apply(change, to: "let value = 1\nlet other = 2\n")
        #expect(applied == "let value = 2\nlet other = 2\n")
        #expect(result.summary == "patch queued: 1 file")
        #expect(result.payload.contains("Replaced 1 occurrence"))
        // Queuing must not touch the file — apply happens on user approval.
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 1\nlet other = 2\n")
    }

    @Test("edit_file matches against the editable-content provider, not disk")
    @MainActor
    func toolPrefersEditableContentProvider() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_edit_file_tab_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        // Disk is stale; the "open tab" holds the current buffer.
        try "stale disk content\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let tabContent = "let fresh = true\n"

        var queuedDiff: String?
        let context = AgentToolContext(
            rootDirectory: workspace,
            patchProposalSink: { title, diff, _ in
                queuedDiff = diff
                return AgentPatchProposal(messageID: UUID(), title: title ?? "Agent Patch", diff: diff)
            },
            editableContentProvider: { _ in tabContent }
        )

        _ = try await AgentToolRunner.run(
            name: "edit_file",
            arguments: [
                "path": .string("Sample.swift"),
                "old_string": .string("let fresh = true"),
                "new_string": .string("let fresh = false")
            ],
            context: context
        )

        let diff = try #require(queuedDiff)
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(try AgentPatchApplier.apply(change, to: tabContent) == "let fresh = false\n")
    }

    @Test("edit_file surfaces a model-actionable error for ambiguous matches")
    @MainActor
    func toolReportsAmbiguousMatch() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_edit_file_ambiguous_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        try "dup\nother\ndup\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = AgentToolContext(
            rootDirectory: workspace,
            patchProposalSink: { _, diff, _ in
                AgentPatchProposal(messageID: UUID(), title: "unused", diff: diff)
            }
        )

        await #expect(throws: AgentEditFileError.oldStringNotUnique("Sample.swift", 2)) {
            _ = try await AgentToolRunner.run(
                name: "edit_file",
                arguments: [
                    "path": .string("Sample.swift"),
                    "old_string": .string("dup"),
                    "new_string": .string("x")
                ],
                context: context
            )
        }
        // Nothing queued, nothing written.
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "dup\nother\ndup\n")
    }
}
