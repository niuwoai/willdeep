//
//  EditorLanguageServiceInlayHintTests.swift
//  WillDeepTests
//
//  Focused tests for LSP-backed inlay hints.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceInlayHintTests {
    @Test("LSP inlay hint result decodes string array and null labels")
    func testLSPInlayHintResultDecodesCommonShapes() throws {
        let result = try JSONDecoder().decode(LSPInlayHintResult.self, from: Data("""
        [
          {
            "position": { "line": 3, "character": 14 },
            "label": ": string",
            "kind": 1
          },
          {
            "position": { "line": 3, "character": 19 },
            "label": [
              { "value": "name" },
              { "value": ": " }
            ],
            "kind": 2
          }
        ]
        """.utf8))
        let empty = try JSONDecoder().decode(LSPInlayHintResult.self, from: Data("null".utf8))

        #expect(result.hints.count == 2)
        #expect(result.hints[0].label.plainText == ": string")
        #expect(result.hints[1].label.plainText == "name: ")
        #expect(empty.hints.isEmpty)
    }

    @Test("language service manager requests inlay hints through LSP")
    func testLanguageServiceManagerRequestsInlayHints() async throws {
        let transport = InlayHintFakeTransport()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"

        let hints = try await manager.inlayHints(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )

        let methods = transport.sentPayloads.compactMap(InlayHintFakeTransport.methodName)
        let hintRequest = try #require(transport.sentPayloads.first(where: {
            InlayHintFakeTransport.methodName(from: $0) == "textDocument/inlayHint"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: hintRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let range = try #require(params["range"] as? [String: Any])
        let start = try #require(range["start"] as? [String: Any])
        let end = try #require(range["end"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/inlayHint"))
        #expect(start["line"] as? Int == 0)
        #expect(start["character"] as? Int == 0)
        #expect(end["line"] as? Int == 5)
        #expect(hints == [
            EditorInlayHintSpan(
                location: (text as NSString).range(of: "value").location,
                label: "value:",
                kind: 2
            )
        ])
    }

    @Test("language service manager resolves inlay hints through LSP")
    func testLanguageServiceManagerResolvesInlayHints() async throws {
        let transport = InlayHintFakeTransport(resolveProvider: true, returnsResolvableHint: true)
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"

        let hints = try await manager.inlayHints(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )

        let methods = transport.sentPayloads.compactMap(InlayHintFakeTransport.methodName)
        let resolveRequest = try #require(transport.sentPayloads.first(where: {
            InlayHintFakeTransport.methodName(from: $0) == "inlayHint/resolve"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: resolveRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let data = try #require(params["data"] as? [String: Any])

        #expect(methods.contains("textDocument/inlayHint"))
        #expect(methods.contains("inlayHint/resolve"))
        #expect(data["serverID"] as? String == "inlay-hint-value")
        #expect(hints.first?.label == "value:")
        #expect(hints.first?.tooltip == "Resolved value hint")
    }
}

private final class InlayHintFakeTransport: LanguageServerTransport {
    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    private(set) var sentPayloads: [Data] = []
    private let resolveProvider: Bool
    private let returnsResolvableHint: Bool

    init(resolveProvider: Bool = false, returnsResolvableHint: Bool = false) {
        self.resolveProvider = resolveProvider
        self.returnsResolvableHint = returnsResolvableHint
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
            let provider: Any = resolveProvider ? ["resolveProvider": true] : true
            push(responsePayload(id: id, result: [
                "capabilities": [
                    "inlayHintProvider": provider
                ]
            ]))
        case "textDocument/inlayHint":
            var hint: [String: Any] = [
                "position": [
                    "line": 3,
                    "character": 13
                ],
                "label": "value:",
                "kind": 2
            ]
            if returnsResolvableHint {
                hint["data"] = ["serverID": "inlay-hint-value"]
            }
            push(responsePayload(id: id, result: [hint]))
        case "inlayHint/resolve":
            push(responsePayload(id: id, result: [
                "position": [
                    "line": 3,
                    "character": 13
                ],
                "label": "value:",
                "kind": 2,
                "tooltip": "Resolved value hint",
                "data": ["serverID": "inlay-hint-value"]
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
