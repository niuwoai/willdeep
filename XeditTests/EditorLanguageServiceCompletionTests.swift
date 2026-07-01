//
//  EditorLanguageServiceCompletionTests.swift
//  WillDeepTests
//
//  Focused tests for LSP-backed completion edits.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceCompletionTests {
    @Test("LSP completion item decodes text edit additional edits and snippet format")
    func testLSPCompletionItemDecodesServerEdits() throws {
        let item = try JSONDecoder().decode(LSPCompletionItem.self, from: Data("""
        {
          "label": "Println",
          "kind": 3,
          "insertTextFormat": 2,
          "textEdit": {
            "range": {
              "start": { "line": 3, "character": 5 },
              "end": { "line": 3, "character": 7 }
            },
            "newText": "Println(${1:value})$0"
          },
          "additionalTextEdits": [
            {
              "range": {
                "start": { "line": 2, "character": 0 },
                "end": { "line": 2, "character": 0 }
              },
              "newText": "import \\"fmt\\"\\n"
            }
          ]
        }
        """.utf8))

        #expect(item.label == "Println")
        #expect(item.insertTextFormat == 2)
        #expect(item.textEdit?.newText == "Println(${1:value})$0")
        #expect(item.additionalTextEdits?.first?.newText == "import \"fmt\"\n")
    }

    @Test("editor completion applies primary LSP text edit additional edits and strips snippet placeholders")
    func testEditorCompletionAppliesServerEdits() throws {
        let text = "package main\n\nfunc main() {\n\tfmt.Pr\n}\n"
        let item = EditorCompletionItem(
            item: LSPCompletionItem(
                label: "Println",
                kind: 3,
                detail: "func",
                documentation: nil,
                insertText: nil,
                insertTextFormat: 2,
                textEdit: .textEdit(LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 3, character: 5),
                        end: LSPPosition(line: 3, character: 7)
                    ),
                    newText: "Println(${1:value})$0"
                )),
                additionalTextEdits: [
                    LSPTextEdit(
                        range: LSPRange(
                            start: LSPPosition(line: 2, character: 0),
                            end: LSPPosition(line: 2, character: 0)
                        ),
                        newText: "import \"fmt\"\n"
                    )
                ]
            ),
            index: 0
        )
        let request = EditorCompletionRequest(
            characterOffset: (text as NSString).range(of: "Pr").location + 2,
            replacementRange: (text as NSString).range(of: "Pr"),
            prefix: "Pr"
        )

        let result = try #require(EditorCompletionTextEditApplier.apply(item: item, request: request, to: text))

        #expect(result.text == "package main\n\nimport \"fmt\"\nfunc main() {\n\tfmt.Println(value)\n}\n")
        #expect(result.cursorLocation == ("package main\n\nimport \"fmt\"\nfunc main() {\n\tfmt.Println(value)" as NSString).length)
    }

    @Test("editor completion uses local replacement range when server omits text edit")
    func testEditorCompletionFallsBackToLocalReplacementRange() throws {
        let text = "let va = 1\n"
        let item = EditorCompletionItem(
            item: LSPCompletionItem(label: "value", insertText: "value"),
            index: 0
        )
        let request = EditorCompletionRequest(
            characterOffset: 6,
            replacementRange: (text as NSString).range(of: "va"),
            prefix: "va"
        )

        let result = try #require(EditorCompletionTextEditApplier.apply(item: item, request: request, to: text))

        #expect(result.text == "let value = 1\n")
        #expect(result.cursorLocation == 9)
    }
}
