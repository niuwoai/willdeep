//
//  MarkdownTableParserTests.swift
//  VeilWriterTests
//
//  Covers MarkdownPreviewParser's GFM-table detection: with/without
//  outer pipes, alignment-row tolerance, and the rule that a single
//  pipe-laden prose line must not be hijacked into a table when there's
//  no alignment row.
//

import Testing
import Foundation
@testable import VeilWriter

@Suite
struct MarkdownTableParserTests {
    @Test
    func parsesPlainGFMTable() {
        let md = """
        Before text.

        | Path | Note |
        |------|------|
        | .pnpm-store/ | pnpm cache (ignore) |
        | .config/alma/skills/ | local skills (ignore) |

        After text.
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        // [paragraph, table, paragraph]
        #expect(blocks.count == 3)
        let table = blocks[1]
        #expect(table.kind == .table)
        #expect(table.tableHeaders == ["Path", "Note"])
        #expect(table.tableRows?.count == 2)
        #expect(table.tableRows?[0] == [".pnpm-store/", "pnpm cache (ignore)"])
        #expect(table.tableRows?[1] == [".config/alma/skills/", "local skills (ignore)"])
    }

    @Test
    func acceptsAlignmentColons() {
        let md = """
        | A | B | C |
        |:---|:---:|---:|
        | one | two | three |
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .table)
        #expect(blocks[0].tableHeaders == ["A", "B", "C"])
        #expect(blocks[0].tableRows == [["one", "two", "three"]])
    }

    @Test
    func parsesTableImmediatelyAtEOF() {
        // No trailing blank line — the parser must still close the table
        // and not eat the last row as paragraph text.
        let md = """
        | k | v |
        |---|---|
        | a | 1 |
        | b | 2 |
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .table)
        #expect(blocks[0].tableRows?.count == 2)
    }

    @Test
    func pipeProseWithoutAlignmentRowStaysParagraph() {
        // A single line that just happens to contain `|` shouldn't get
        // turned into a degenerate table. The next line is paragraph
        // text, not alignment markers — so we expect a paragraph block.
        let md = "use grep '^\\(M\\|A\\|D\\)' to filter"
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test
    func looseFormWithoutOuterPipesWorks() {
        // Models occasionally emit tables without the leading/trailing
        // pipe. Accept those as long as the alignment row is present.
        let md = """
        col1 | col2
        ---  | ---
        a    | b
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .table)
        #expect(blocks[0].tableHeaders == ["col1", "col2"])
        #expect(blocks[0].tableRows == [["a", "b"]])
    }
}
