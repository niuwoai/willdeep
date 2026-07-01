//
//  EditorLanguageServiceNavigationTests.swift
//  WillDeepTests
//
//  Focused tests for LSP-backed source navigation.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceNavigationTests {
    @Test("language service manager requests declarations through LSP")
    func testLanguageServiceManagerRequestsDeclaration() async throws {
        let transport = DeclarationFakeTransport()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let locations = try await manager.declaration(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(DeclarationFakeTransport.methodName)
        let declarationRequest = try #require(transport.sentPayloads.first(where: {
            DeclarationFakeTransport.methodName(from: $0) == "textDocument/declaration"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: declarationRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/declaration"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(locations == [DeclarationFakeTransport.declarationLocation])
    }
}

private final class DeclarationFakeTransport: LanguageServerTransport {
    static let declarationLocation = LSPLocation(
        uri: "file:///tmp/decl.go",
        range: LSPRange(
            start: LSPPosition(line: 2, character: 0),
            end: LSPPosition(line: 2, character: 5)
        )
    )

    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    private(set) var sentPayloads: [Data] = []

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
            push(responsePayload(id: id, result: [
                "capabilities": [
                    "declarationProvider": true
                ]
            ]))
        case "textDocument/declaration":
            push(responsePayload(id: id, result: Self.locationObject(Self.declarationLocation)))
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

    private static func locationObject(_ location: LSPLocation) -> [String: Any] {
        [
            "uri": location.uri,
            "range": [
                "start": [
                    "line": location.range.start.line,
                    "character": location.range.start.character
                ],
                "end": [
                    "line": location.range.end.line,
                    "character": location.range.end.character
                ]
            ]
        ]
    }
}
