//
//  EditorLanguageServiceRenameTests.swift
//  WillDeepTests
//
//  Focused tests for LSP-backed rename preparation.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceRenameTests {
    @Test("first-stage IDE registry exposes prepare rename capability")
    func testFirstStageIDERegistryExposesPrepareRename() {
        for language in [Language.go, .typescript, .javascript, .swift] {
            #expect(EditorLanguageServiceRegistry.configuration(for: language)?.capabilities.contains(.prepareRename) == true)
        }
    }

    @Test("language service manager requests prepare rename through LSP")
    func testLanguageServiceManagerRequestsPrepareRename() async throws {
        let transport = PrepareRenameFakeTransport()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let nsText = text as NSString
        let offset = nsText.range(of: "value").location

        let prepared = try #require(try await manager.prepareRename(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        ))

        let methods = transport.sentPayloads.compactMap(PrepareRenameFakeTransport.methodName)
        let prepareRequest = try #require(transport.sentPayloads.first(where: {
            PrepareRenameFakeTransport.methodName(from: $0) == "textDocument/prepareRename"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: prepareRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/prepareRename"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(prepared.placeholder == "value")
        #expect(prepared.range == nsText.range(of: "value"))
    }
}

private final class PrepareRenameFakeTransport: LanguageServerTransport {
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
                    "renameProvider": [
                        "prepareProvider": true
                    ]
                ]
            ]))
        case "textDocument/prepareRename":
            push(responsePayload(id: id, result: [
                "range": [
                    "start": ["line": 3, "character": 13],
                    "end": ["line": 3, "character": 18]
                ],
                "placeholder": "value"
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
