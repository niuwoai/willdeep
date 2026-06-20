//
//  AgentLocalAttachmentRetrieverTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentLocalAttachmentRetrieverTests {
    @Test("large attachments render local retrieval chunks for the current query")
    func largeAttachmentUsesRelevantLocalRetrievalChunks() {
        let unrelated = repeatedLine("legacy migration baseline keeps archived flags", count: 180)
        let relevant = repeatedLine("deepseek local retrieval should find quarterly revenue from sheet rows", count: 12)
        let body = """
        ```
        \(unrelated)
        \(relevant)
        \(unrelated)
        ```
        """

        let rendered = AgentLocalAttachmentRetriever.renderAttachment(
            relativePath: "reports/revenue.xlsx",
            body: body,
            query: "DeepSeek 本地检索 quarterly revenue"
        )

        #expect(rendered.contains("[local attachment retrieval]"))
        #expect(rendered.contains("reports/revenue.xlsx"))
        #expect(rendered.contains("quarterly revenue"))
        #expect(rendered.count < body.count)
    }

    @Test("small attachments remain complete instead of forced retrieval")
    func smallAttachmentRendersCompleteBody() {
        let body = """
        ```
        alpha
        beta target
        gamma
        ```
        """

        let rendered = AgentLocalAttachmentRetriever.renderAttachment(
            relativePath: "notes.txt",
            body: body,
            query: "target"
        )

        #expect(!rendered.contains("[local attachment retrieval]"))
        #expect(rendered.contains("alpha"))
        #expect(rendered.contains("beta target"))
        #expect(rendered.contains("gamma"))
    }

    private func repeatedLine(_ line: String, count: Int) -> String {
        Array(repeating: line, count: count).joined(separator: "\n")
    }
}
