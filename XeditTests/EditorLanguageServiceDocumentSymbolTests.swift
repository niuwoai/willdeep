//
//  EditorLanguageServiceDocumentSymbolTests.swift
//  WillDeepTests
//
//  Focused tests for LSP-backed document symbols and outline mapping.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceDocumentSymbolTests {
    @Test("LSP document symbol result decodes hierarchical flat and null shapes")
    func testLSPDocumentSymbolResultDecodesCommonShapes() throws {
        let hierarchical = try JSONDecoder().decode(LSPDocumentSymbolResult.self, from: Data("""
        [
          {
            "name": "Service",
            "detail": "struct",
            "kind": 23,
            "range": { "start": { "line": 1, "character": 0 }, "end": { "line": 4, "character": 1 } },
            "selectionRange": { "start": { "line": 1, "character": 5 }, "end": { "line": 1, "character": 12 } },
            "children": []
          }
        ]
        """.utf8))
        let flat = try JSONDecoder().decode(LSPDocumentSymbolResult.self, from: Data("""
        [
          {
            "name": "start",
            "kind": 12,
            "location": {
              "uri": "file:///tmp/main.go",
              "range": { "start": { "line": 2, "character": 4 }, "end": { "line": 3, "character": 5 } }
            },
            "containerName": "Service"
          }
        ]
        """.utf8))
        let empty = try JSONDecoder().decode(LSPDocumentSymbolResult.self, from: Data("null".utf8))

        #expect(hierarchical.documentSymbols.map(\.name) == ["Service"])
        #expect(hierarchical.documentSymbols[0].detail == "struct")
        #expect(flat.documentSymbols.map(\.name) == ["start"])
        #expect(flat.documentSymbols[0].detail == "Service")
        #expect(flat.documentSymbols[0].range.start.line == 2)
        #expect(empty.documentSymbols.isEmpty)
    }

    @Test("language service manager maps flat SymbolInformation document symbols")
    func testLanguageServiceManagerMapsFlatSymbolInformationDocumentSymbols() async throws {
        let transport = DocumentSymbolFakeTransport()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let symbols = try await manager.documentSymbols(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: "package main\n\ntype Service struct {}\nfunc start() {}\n"
        )
        let outline = EditorOutlineExtractor.outline(from: symbols)
        let methods = transport.sentPayloads.compactMap(DocumentSymbolFakeTransport.methodName)

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/documentSymbol"))
        #expect(symbols.map(\.name) == ["Service", "start"])
        #expect(symbols.map(\.detail) == [nil, "Service"])
        #expect(outline.map(\.title) == ["Service", "start Service"])
        #expect(outline.map(\.kind) == [.type, .function])
        #expect(outline.map(\.line) == [3, 4])
    }

    @Test("language service manager skips document symbols when server does not advertise support")
    func testLanguageServiceManagerSkipsDocumentSymbolsWithoutCapability() async throws {
        let transport = DocumentSymbolFakeTransport(exposesDocumentSymbols: false)
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let symbols = try await manager.documentSymbols(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: "package main\n"
        )
        let methods = transport.sentPayloads.compactMap(DocumentSymbolFakeTransport.methodName)

        #expect(symbols.isEmpty)
        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(!methods.contains("textDocument/documentSymbol"))
    }
}

private final class DocumentSymbolFakeTransport: LanguageServerTransport {
    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    private(set) var sentPayloads: [Data] = []
    private let exposesDocumentSymbols: Bool

    init(exposesDocumentSymbols: Bool = true) {
        self.exposesDocumentSymbols = exposesDocumentSymbols
    }

    func start() throws {}

    func send(_ data: Data) throws {
        var buffer = data
        let payloads = LSPMessageFramer.extractMessages(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
        for payload in payloads {
            respondIfNeeded(to: payload)
        }
    }

    func stop() {}

    static func methodName(from payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }

    private func respondIfNeeded(to payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = object["id"] as? Int,
              let method = object["method"] as? String else {
            return
        }

        switch method {
        case "initialize":
            let capabilities: [String: Any] = exposesDocumentSymbols ? [
                "documentSymbolProvider": true
            ] : [:]
            push(responsePayload(id: id, result: [
                "capabilities": capabilities
            ]))
        case "textDocument/documentSymbol":
            push(responsePayload(id: id, result: [
                [
                    "name": "Service",
                    "kind": 23,
                    "location": [
                        "uri": "file:///tmp/main.go",
                        "range": [
                            "start": ["line": 2, "character": 5],
                            "end": ["line": 2, "character": 12]
                        ]
                    ]
                ],
                [
                    "name": "start",
                    "kind": 12,
                    "location": [
                        "uri": "file:///tmp/main.go",
                        "range": [
                            "start": ["line": 3, "character": 5],
                            "end": ["line": 3, "character": 10]
                        ]
                    ],
                    "containerName": "Service"
                ]
            ]))
        default:
            break
        }
    }

    private func push(_ payload: Data) {
        onData?(LSPMessageFramer.frame(payload: payload))
    }

    private func responsePayload(id: Int, result: Any) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
