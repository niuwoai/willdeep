//
//  AgentPatchApplierNewFileTests.swift
//  WillDeepTests
//
//  Covers apply_patch new-file (creation) diff parsing + application.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentPatchApplierNewFileTests {
    private let newFileDiff = """
    diff --git a/web/hello.txt b/web/hello.txt
    new file mode 100644
    index 0000000..e69de29
    --- /dev/null
    +++ b/web/hello.txt
    @@ -0,0 +1,3 @@
    +line one
    +line two
    +line three
    """

    @Test
    func parsesCreationDiffAsNewFile() throws {
        let changes = try AgentPatchApplier.parse(newFileDiff)
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.path == "web/hello.txt")
        #expect(change.isNewFile == true)
    }

    @Test
    func appliesCreationDiffOntoEmptyContent() throws {
        let change = try #require(try AgentPatchApplier.parse(newFileDiff).first)
        let content = try AgentPatchApplier.apply(change, to: "")
        #expect(content == "line one\nline two\nline three")
    }

    @Test
    func plainDevNullCreationWithoutNewFileModeIsStillNewFile() throws {
        let diff = """
        --- /dev/null
        +++ b/notes.md
        @@ -0,0 +1,1 @@
        +hello
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(change.isNewFile == true)
        #expect(try AgentPatchApplier.apply(change, to: "") == "hello")
    }

    @Test
    func modifyDiffIsNotMarkedNewFile() throws {
        let diff = """
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(change.isNewFile == false)
        #expect(try AgentPatchApplier.apply(change, to: "keep\nold") == "keep\nnew")
    }

    // MARK: - isAlreadyApplied

    private let insertDiff = """
    --- a/foo.txt
    +++ b/foo.txt
    @@ -1,2 +1,3 @@
     keep
    +added
     tail
    """

    @Test
    func alreadyAppliedTrueWhenFileHoldsTargetState() throws {
        let change = try #require(try AgentPatchApplier.parse(insertDiff).first)
        // File already contains the post-patch result: applying it again is a
        // no-op, and the raw apply would throw because the pre-patch context
        // no longer matches.
        #expect(AgentPatchApplier.isAlreadyApplied(change, to: "keep\nadded\ntail"))
        #expect(throws: AgentPatchError.self) {
            _ = try AgentPatchApplier.apply(change, to: "keep\nadded\ntail")
        }
    }

    @Test
    func alreadyAppliedFalseWhenChangeStillPending() throws {
        let change = try #require(try AgentPatchApplier.parse(insertDiff).first)
        // Genuine pre-patch state: the change has not landed, so this must NOT
        // be mistaken for already-applied.
        #expect(AgentPatchApplier.isAlreadyApplied(change, to: "keep\ntail") == false)
        #expect(try AgentPatchApplier.apply(change, to: "keep\ntail") == "keep\nadded\ntail")
    }

    @Test
    func alreadyAppliedFalseForNewFile() throws {
        let change = try #require(try AgentPatchApplier.parse(newFileDiff).first)
        #expect(AgentPatchApplier.isAlreadyApplied(change, to: "line one\nline two\nline three") == false)
    }

    @Test
    func alreadyAppliedFalseForPureDeletionHunk() throws {
        // A hunk with only removed lines has an empty replacement; presence
        // can't confirm it, so we stay conservative and report not-applied.
        let diff = """
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,1 +0,0 @@
        -remove
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(AgentPatchApplier.isAlreadyApplied(change, to: "") == false)
    }
}
