//
//  MarkdownTableParserTests.swift
//  WillDeepTests
//
//  Covers MarkdownPreviewParser's GFM-table detection: with/without
//  outer pipes, alignment-row tolerance, and the rule that a single
//  pipe-laden prose line must not be hijacked into a table when there's
//  no alignment row.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
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
    func toleratesExtraWhitespaceInAlignmentCells() {
        // Hand-written tables often pad the alignment row with spaces
        // for readability: `| --- | --- |`. Must still register.
        let md = """
        | h1 | h2 |
        | --- | --- |
        | a | b |
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .table)
        #expect(blocks[0].tableHeaders == ["h1", "h2"])
    }

    @Test
    func toleratesLongDashAlignmentRow() {
        // The screenshotted reply had alignment rows like
        // `|---------|----------|---------|`. Any number of dashes
        // per cell must work.
        let md = """
        | h1 | h2 |
        |---------|----------|
        | a | b |
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .table)
    }

    @Test
    func parsesCJKHeaderTableWithInlineMarkdownCells() {
        // Mirrors a real assistant reply from the field — CJK headers,
        // an alignment row with long dashes, and cells that contain
        // inline-code spans and bold marks. The whole thing must come
        // out as one .table block, not stay as paragraph noise.
        let md = """
        最近提交总结 (近 15 条)

        按从新到旧:

        | 时间    | 提交      | 作者     | 说明                                  |
        |---------|----------|----------|--------------------------------------|
        | 06-04 13:47 | `1633595` | insight68 | 合并 main 分支 |
        | 06-04 13:33 | `561a2e9` | insight68 | **hermes**(Hermes agent 相关) |
        | 06-03 22:15 | `f779ee2` | rocky | **fix(artifacts):** 修复生成图片卡片的渲染 |
        """

        let blocks = MarkdownPreviewParser.blocks(from: md)
        let tables = blocks.filter { $0.kind == .table }
        #expect(tables.count == 1)
        let table = tables[0]
        #expect(table.tableHeaders == ["时间", "提交", "作者", "说明"])
        #expect(table.tableRows?.count == 3)
        #expect(table.tableRows?[0] == ["06-04 13:47", "`1633595`", "insight68", "合并 main 分支"])
        #expect(table.tableRows?[2] == ["06-03 22:15", "`f779ee2`", "rocky", "**fix(artifacts):** 修复生成图片卡片的渲染"])
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

    @Test
    func tableLayoutUsesOneWidthPerColumnAcrossAllRows() {
        let widths = MarkdownTableColumnLayout.widths(
            headers: ["组件", "是否依赖", "说明"],
            rows: [
                ["MySQL", "强烈建议（生产必需）", "未配置 DSN 时，部分 API 不可用。"],
                ["Redis", "否", "当前代码中未发现 Redis 客户端。"]
            ],
            fontSize: 15
        )

        #expect(widths.count == 3)
        #expect(widths[1] > widths[0])
        #expect(widths[2] > widths[0])
        #expect(widths.allSatisfy { $0 >= MarkdownTableColumnLayout.minimumWidth })
    }

    @Test
    func tableLayoutCapsLongCellsSoTheyWrapInsideThePreview() {
        let longDSN = String(repeating: "user:pass@tcp(host:3306)/database?parseTime=true", count: 20)
        let widths = MarkdownTableColumnLayout.widths(
            headers: ["变量", "说明"],
            rows: [["MYSQL_DSN", longDSN]],
            fontSize: 15
        )

        #expect(widths[1] == MarkdownTableColumnLayout.maximumWidth)
    }

    @Test
    func tableLayoutMeasuresVisibleInlineMarkdownOnly() {
        let plain = MarkdownTableColumnLayout.widths(
            headers: ["值"],
            rows: [["important"]],
            fontSize: 15
        )
        let styled = MarkdownTableColumnLayout.widths(
            headers: ["值"],
            rows: [["**important**"]],
            fontSize: 15
        )

        #expect(styled == plain)
    }
}
