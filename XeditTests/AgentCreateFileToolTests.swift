//
//  AgentCreateFileToolTests.swift
//  WillDeepTests
//
//  Covers the create_file tool's diff synthesis. create_file hands the
//  model a clean (path, content) surface and internally builds a creation
//  diff that the existing apply_patch pipeline parses + writes. These tests
//  lock the round-trip: makeCreationDiff → parse → apply must reproduce the
//  original content byte-for-byte, so a new file lands exactly as given.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentCreateFileToolTests {
    /// Build → parse → apply and assert the file content round-trips and the
    /// change is recognized as a new file at the expected path.
    private func roundTrip(path: String, content: String) throws -> AgentPatchFileChange {
        let diff = AgentToolRunner.makeCreationDiff(path: path, content: content)
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(change.isNewFile == true)
        #expect(change.path == path)
        #expect(try AgentPatchApplier.apply(change, to: "") == content)
        return change
    }

    @Test
    func multiLineContentRoundTrips() throws {
        _ = try roundTrip(path: "src/util/date.ts", content: "export const x = 1\nexport const y = 2")
    }

    @Test
    func contentWithTrailingNewlineRoundTrips() throws {
        _ = try roundTrip(path: "docs/readme.md", content: "# Title\n\nBody paragraph.\n")
    }

    @Test
    func singleLineNoNewlineRoundTrips() throws {
        _ = try roundTrip(path: "VERSION", content: "1.2.3")
    }

    @Test
    func emptyContentCreatesEmptyFile() throws {
        _ = try roundTrip(path: "empty.txt", content: "")
    }

    @Test
    func contentContainingDiffMarkersRoundTrips() throws {
        // Lines that themselves start with +/-/@@ must survive: every line is
        // emitted as an added (`+`) line, so the parser never mistakes file
        // content for diff control lines.
        let tricky = "+ not a hunk\n- also not\n@@ fake header @@\n normal"
        _ = try roundTrip(path: "tricky.txt", content: tricky)
    }
}
