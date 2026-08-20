//
//  MarkdownListNestingTests.swift
//  WillDeepTests
//
//  Covers MarkdownPreviewParser's nested-list indentation handling.
//  2-space indent = one nesting level; 4 spaces = two; tabs count as 4.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct MarkdownListNestingTests {
    @Test
    func topLevelListItemsAreIndentZero() {
        let blocks = MarkdownPreviewParser.blocks(from: "- a\n- b\n")
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.indent == 0 })
        #expect(blocks.map(\.text) == ["a", "b"])
    }

    @Test
    func twoSpaceIndentIsOneLevel() {
        let md = """
        - parent
          - child
            - grandchild
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 3)
        #expect(blocks[0].indent == 0)
        #expect(blocks[1].indent == 1)
        #expect(blocks[2].indent == 2)
        #expect(blocks.map(\.text) == ["parent", "child", "grandchild"])
    }

    @Test
    func fourSpaceIndentAlsoCountsAsLevels() {
        let md = """
        - parent
            - child (4 spaces)
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 2)
        #expect(blocks[0].indent == 0)
        #expect(blocks[1].indent == 2)
    }

    @Test
    func tabsCountAsFourSpaces() {
        let md = "- top\n\t- nested"
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 2)
        #expect(blocks[1].indent == 2)
    }

    @Test
    func orderedListsAlsoNest() {
        let md = """
        1. one
          2. nested under one
        2. two
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.kind == .orderedList })
        #expect(blocks[0].indent == 0)
        #expect(blocks[1].indent == 1)
        #expect(blocks[2].indent == 0)
    }

    @Test
    func repeatedOneMarkersRenderAsAContinuousListAcrossBlankLines() {
        let md = "1. first\n\n1. second\n\n1. third"
        let blocks = MarkdownPreviewParser.blocks(from: md)

        #expect(blocks.map(\.orderedListNumber) == [1, 2, 3])
    }

    @Test
    func orderedListPreservesItsStartAndResumesAfterNestedItems() {
        let md = """
        4. fourth
          1. nested first
          1. nested second
        1. fifth
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)

        #expect(blocks.map(\.orderedListNumber) == [4, 1, 2, 5])
    }

    @Test
    func paragraphStartsANewOrderedList() {
        let md = """
        1. first

        A paragraph between lists.

        1. first again
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        let numbers = blocks.compactMap(\.orderedListNumber)

        #expect(numbers == [1, 1])
    }
}
