//
//  EditorLanguageServiceDocumentLinkTests.swift
//  WillDeepTests
//
//  Focused tests for LSP-backed document links.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceDocumentLinkTests {
    @Test("LSP document link result decodes arrays null and safe targets")
    func testLSPDocumentLinkResultDecodesCommonShapes() throws {
        let result = try JSONDecoder().decode(LSPDocumentLinkResult.self, from: Data("""
        [
          {
            "range": { "start": { "line": 1, "character": 8 }, "end": { "line": 1, "character": 19 } },
            "target": "file:///tmp/pkg/service.go",
            "tooltip": "Open service.go"
          },
          {
            "range": { "start": { "line": 2, "character": 4 }, "end": { "line": 2, "character": 23 } },
            "target": "x-apple.systempreferences:com.apple.preference.security"
          }
        ]
        """.utf8))
        let empty = try JSONDecoder().decode(LSPDocumentLinkResult.self, from: Data("null".utf8))

        #expect(result.links.count == 2)
        #expect(result.links[0].targetURL == URL(string: "file:///tmp/pkg/service.go"))
        #expect(result.links[0].tooltip == "Open service.go")
        #expect(result.links[1].targetURL == nil)
        #expect(empty.links.isEmpty)
    }

    @Test("language service manager requests document links through LSP")
    func testLanguageServiceManagerRequestsDocumentLinks() async throws {
        let transport = DocumentLinkFakeTransport()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nimport \"example.com/pkg\"\n"

        let links = try await manager.documentLinks(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )
        let methods = transport.sentPayloads.compactMap(DocumentLinkFakeTransport.methodName)

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/documentLink"))
        let firstLink = try #require(links.first)
        #expect(links.count == 1)
        #expect(firstLink.range == (text as NSString).range(of: "example.com/pkg"))
        #expect(firstLink.target == URL(string: "file:///tmp/pkg"))
        #expect(firstLink.tooltip == "Open package")
        #expect(firstLink.lspLink.target == "file:///tmp/pkg")
    }

    @Test("language service manager skips document links without capability")
    func testLanguageServiceManagerSkipsDocumentLinksWithoutCapability() async throws {
        let transport = DocumentLinkFakeTransport(exposesDocumentLinks: false)
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let links = try await manager.documentLinks(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: "package main\n"
        )
        let methods = transport.sentPayloads.compactMap(DocumentLinkFakeTransport.methodName)

        #expect(links.isEmpty)
        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(!methods.contains("textDocument/documentLink"))
    }

    @Test("language service manager resolves document links through LSP")
    func testLanguageServiceManagerResolvesDocumentLinks() async throws {
        let transport = DocumentLinkFakeTransport(resolveProvider: true, returnsUnresolvedLink: true)
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nimport \"example.com/pkg\"\n"

        let links = try await manager.documentLinks(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )
        let firstLink = try #require(links.first)
        let resolved = try await manager.resolveDocumentLink(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            link: firstLink.lspLink
        )

        let methods = transport.sentPayloads.compactMap(DocumentLinkFakeTransport.methodName)
        let resolveRequest = try #require(transport.sentPayloads.first {
            DocumentLinkFakeTransport.methodName(from: $0) == "documentLink/resolve"
        })
        let request = try #require(try JSONSerialization.jsonObject(with: resolveRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])

        #expect(firstLink.target == nil)
        #expect(methods.contains("textDocument/documentLink"))
        #expect(methods.contains("documentLink/resolve"))
        #expect((params["data"] as? [String: Any])?["serverID"] as? String == "document-link-package")
        #expect(resolved.targetURL == URL(string: "file:///tmp/pkg"))
    }
}

private final class DocumentLinkFakeTransport: LanguageServerTransport {
    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    private(set) var sentPayloads: [Data] = []
    private let exposesDocumentLinks: Bool
    private let resolveProvider: Bool
    private let returnsUnresolvedLink: Bool

    init(exposesDocumentLinks: Bool = true, resolveProvider: Bool = false, returnsUnresolvedLink: Bool = false) {
        self.exposesDocumentLinks = exposesDocumentLinks
        self.resolveProvider = resolveProvider
        self.returnsUnresolvedLink = returnsUnresolvedLink
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
            let capabilities: [String: Any] = exposesDocumentLinks ? [
                "documentLinkProvider": ["resolveProvider": resolveProvider]
            ] : [:]
            push(responsePayload(id: id, result: [
                "capabilities": capabilities
            ]))
        case "textDocument/documentLink":
            var link: [String: Any] = [
                "range": [
                    "start": ["line": 2, "character": 8],
                    "end": ["line": 2, "character": 23]
                ],
                "tooltip": "Open package"
            ]
            if returnsUnresolvedLink {
                link["data"] = ["serverID": "document-link-package"]
            } else {
                link["target"] = "file:///tmp/pkg"
            }
            push(responsePayload(id: id, result: [link]))
        case "documentLink/resolve":
            push(responsePayload(id: id, result: [
                "range": [
                    "start": ["line": 2, "character": 8],
                    "end": ["line": 2, "character": 23]
                ],
                "target": "file:///tmp/pkg",
                "tooltip": "Open package",
                "data": ["serverID": "document-link-package"]
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
