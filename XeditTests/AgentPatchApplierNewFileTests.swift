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
}
