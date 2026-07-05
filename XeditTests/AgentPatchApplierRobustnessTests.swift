//
//  AgentPatchApplierRobustnessTests.swift
//  WillDeepTests
//
//  Covers apply_patch robustness fixes (1.129.0-rc33):
//    - CRLF files: a clean LF diff applies and the file stays CRLF.
//    - Ambiguous full-file fallback: a context block that appears more than
//      once (outside the ±6 anchor window) refuses instead of patching the
//      wrong copy.
//    - Out-of-range hunk anchor: a bogus/oversized `oldStart` fails safely
//      instead of trapping the ClosedRange.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentPatchApplierRobustnessTests {

    // MARK: CRLF

    @Test("LF diff applies to a CRLF file and preserves CRLF endings")
    func appliesLFDiffToCRLFFilePreservingEndings() throws {
        let content = "alpha\r\nbeta\r\ngamma\r\n"
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         alpha
        -beta
        +BETA
         gamma
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        let result = try AgentPatchApplier.apply(change, to: content)
        #expect(result == "alpha\r\nBETA\r\ngamma\r\n")
        // No lone LF slipped through — every newline is a full CRLF.
        #expect(!result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("LF file is untouched by the CRLF-restore path")
    func lfFileStaysLF() throws {
        let content = "alpha\nbeta\ngamma\n"
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         alpha
        -beta
        +BETA
         gamma
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        let result = try AgentPatchApplier.apply(change, to: content)
        #expect(result == "alpha\nBETA\ngamma\n")
        #expect(!result.contains("\r"))
    }

    // MARK: Ambiguous fuzzy match

    @Test("ambiguous full-file fallback refuses rather than patching the wrong copy")
    func ambiguousFallbackRefuses() throws {
        // The context+removed block ("marker" / "  body") appears twice, at
        // the top (lines 0-1) and far below (lines 40-41). The hunk header
        // points between them (line 21), so the ±6 window matches neither and
        // the full-file fallback runs — and must refuse because the block is
        // not unique, rather than silently patching the first copy.
        var rows = ["marker", "  body"]                       // 0-1  copy A
        rows += (2..<40).map { "fill\($0)" }                  // 2-39 filler
        rows += ["marker", "  body"]                          // 40-41 copy B
        rows += (42..<45).map { "fill\($0)" }                 // 42-44 filler
        let content = rows.joined(separator: "\n")

        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -21,2 +21,2 @@
         marker
        -  body
        +  BODY
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(throws: AgentPatchError.self) {
            _ = try AgentPatchApplier.apply(change, to: content)
        }
    }

    @Test("unique block beyond the window still applies via full-file fallback")
    func uniqueDriftedBlockStillApplies() throws {
        // Only one occurrence of the block; even though the header line is
        // wrong (drifted far), the unique full-file match applies.
        let lead = (0..<30).map { "filler\($0)" }
        let content = (lead + ["needle", "  keep"]).joined(separator: "\n")

        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -2,2 +2,2 @@
         needle
        -  keep
        +  KEEP
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        let result = try AgentPatchApplier.apply(change, to: content)
        #expect(result.contains("needle\n  KEEP"))
        #expect(!result.contains("  keep"))
    }

    // MARK: Out-of-range anchor

    @Test("hunk anchor past EOF fails safely instead of trapping")
    func oversizedAnchorFailsSafely() throws {
        let content = "one\ntwo\nthree"
        // oldStart 900 is far past a 3-line file; must not crash the range.
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -900,1 +900,1 @@
        -nope
        +yep
        """
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(throws: AgentPatchError.self) {
            _ = try AgentPatchApplier.apply(change, to: content)
        }
    }
}
