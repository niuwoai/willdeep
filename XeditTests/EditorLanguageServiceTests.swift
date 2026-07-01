//
//  EditorLanguageServiceTests.swift
//  WillDeepTests
//
//  Tests for first-stage IDE language service and LSP infrastructure.
//

import Foundation
import AppKit
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceTests {
    @Test("first-stage IDE registry supports Go TypeScript JavaScript and Swift")
    func testFirstStageIDERegistrySupportsRequestedLanguages() {
        #expect(EditorLanguageServiceRegistry.configuration(for: .go)?.id == "gopls")
        #expect(EditorLanguageServiceRegistry.configuration(for: .typescript)?.id == "typescript-language-server")
        #expect(EditorLanguageServiceRegistry.configuration(for: .javascript)?.id == "typescript-language-server")
        #expect(EditorLanguageServiceRegistry.configuration(for: .swift)?.id == "sourcekit-lsp")
        #expect(EditorLanguageServiceRegistry.configuration(for: .java) == nil)

        for language in [Language.go, .typescript, .javascript, .swift] {
            let configuration = EditorLanguageServiceRegistry.configuration(for: language)
            #expect(configuration?.capabilities.contains(.diagnostics) == true)
            #expect(configuration?.capabilities.contains(.hover) == true)
            #expect(configuration?.capabilities.contains(.declaration) == true)
            #expect(configuration?.capabilities.contains(.definition) == true)
            #expect(configuration?.capabilities.contains(.typeDefinition) == true)
            #expect(configuration?.capabilities.contains(.implementation) == true)
            #expect(configuration?.capabilities.contains(.workspaceSymbols) == true)
            #expect(configuration?.capabilities.contains(.documentSymbols) == true)
            #expect(configuration?.capabilities.contains(.documentLinks) == true)
            #expect(configuration?.capabilities.contains(.completion) == true)
            #expect(configuration?.capabilities.contains(.formatting) == true)
            #expect(configuration?.capabilities.contains(.inlayHints) == true)
            #expect(configuration?.capabilities.contains(.rename) == true)
            #expect(configuration?.capabilities.contains(.foldingRanges) == true)
            #expect(configuration?.capabilities.contains(.signatureHelp) == true)
            #expect(configuration?.capabilities.contains(.codeActions) == true)
            #expect(configuration?.capabilities.contains(.documentHighlights) == true)
            #expect(configuration?.capabilities.contains(.selectionRanges) == true)
            #expect(configuration?.capabilities.contains(.callHierarchy) == true)
        }
    }

    @Test("workspace root detection uses language-specific project markers")
    func testWorkspaceRootDetectionUsesProjectMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_lsp_root_\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "module demo".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let fileURL = nested.appendingPathComponent("main.go")
        try "package main".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let detected = EditorLanguageServiceRegistry.workspaceRoot(for: fileURL, language: .go, explicitRoot: nil)

        #expect(detected.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("LSP message framer extracts complete payloads and preserves partial data")
    func testLSPMessageFramerExtractsPayloads() throws {
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":true}"#.utf8)
        let framed = LSPMessageFramer.frame(payload: payload)
        var buffer = Data()
        buffer.append(framed.prefix(framed.count - 3))

        #expect(LSPMessageFramer.extractMessages(from: &buffer).isEmpty)
        #expect(!buffer.isEmpty)

        buffer.append(framed.suffix(3))
        let messages = LSPMessageFramer.extractMessages(from: &buffer)

        #expect(messages == [payload])
        #expect(buffer.isEmpty)
    }

    @Test("language server client sends document lifecycle notifications")
    func testLanguageServerClientSendsDocumentLifecycleNotifications() async throws {
        let transport = FakeLanguageServerTransport()
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.go, transport: transport)

        try await client.start()
        let url = URL(fileURLWithPath: "/tmp/main.go")
        try await client.openDocument(url: url, language: .go, version: 1, text: "package main\n")
        try await client.changeDocument(url: url, version: 2, text: "package main\nfunc main() {}\n")
        try await client.closeDocument(url: url)

        let methods = transport.sentPayloads.compactMap { payload -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                return nil
            }
            return object["method"] as? String
        }

        #expect(methods == [
            "textDocument/didOpen",
            "textDocument/didChange",
            "textDocument/didClose"
        ])
    }

    @Test("language server client sends watched file change notifications")
    func testLanguageServerClientSendsWatchedFileChangeNotifications() async throws {
        let transport = FakeLanguageServerTransport()
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.go, transport: transport)
        let url = URL(fileURLWithPath: "/tmp/main.go")

        try await client.start()
        try await client.didChangeWatchedFiles(changes: [
            LSPFileEvent(uri: url.absoluteString, type: .created)
        ])

        let payload = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "workspace/didChangeWatchedFiles"
        })
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let changes = try #require(params["changes"] as? [[String: Any]])
        let firstChange = try #require(changes.first)

        #expect(firstChange["uri"] as? String == url.absoluteString)
        #expect(firstChange["type"] as? Int == LSPFileChangeType.created.rawValue)
    }

    @Test("language server client sends didSave after server advertises save notifications")
    func testLanguageServerClientSendsDidSaveWhenAdvertised() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.go, transport: transport)
        let url = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\nfunc main() {}\n"

        try await client.start()
        try await client.initialize(rootURL: URL(fileURLWithPath: "/tmp"))
        try await client.saveDocument(url: url, text: text)

        let didSavePayload = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/didSave"
        })
        let object = try #require(try JSONSerialization.jsonObject(with: didSavePayload) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let textDocument = try #require(params["textDocument"] as? [String: Any])

        #expect(textDocument["uri"] as? String == url.absoluteString)
        #expect(params["text"] as? String == text)
    }

    @Test("language server client requests willSaveWaitUntil edits when advertised")
    func testLanguageServerClientRequestsWillSaveWaitUntilWhenAdvertised() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.go, transport: transport)
        let url = URL(fileURLWithPath: "/tmp/main.go")

        try await client.start()
        try await client.initialize(rootURL: URL(fileURLWithPath: "/tmp"))
        let edits = try await client.willSaveWaitUntil(url: url)

        let willSavePayload = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/willSaveWaitUntil"
        })
        let object = try #require(try JSONSerialization.jsonObject(with: willSavePayload) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let textDocument = try #require(params["textDocument"] as? [String: Any])

        #expect(textDocument["uri"] as? String == url.absoluteString)
        #expect(params["reason"] as? Int == 1)
        #expect(edits == FakeLanguageServerTransport.willSaveEdits)
    }

    @Test("language server client answers workspace configuration requests")
    func testLanguageServerClientAnswersWorkspaceConfigurationRequests() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.go, transport: transport)

        try await client.start()
        try await client.initialize(rootURL: URL(fileURLWithPath: "/tmp/project"))
        transport.pushServerPayload(Data("""
        {
          "jsonrpc": "2.0",
          "id": 91,
          "method": "workspace/configuration",
          "params": {
            "items": [
              { "scopeUri": "file:///tmp/project/main.go", "section": "gopls" },
              { "section": "willdeep" }
            ]
          }
        }
        """.utf8))

        let response = try await responseObject(id: 91, in: transport)
        let result = try #require(response["result"] as? [[String: Any]])

        #expect(result.count == 2)
        #expect(result[0].isEmpty)
        #expect(result[1].isEmpty)
    }

    @Test("language server client answers workspace folder requests")
    func testLanguageServerClientAnswersWorkspaceFolderRequests() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let configuration = try #require(EditorLanguageServiceRegistry.configuration(for: .typescript))
        let client = LanguageServerClient(configuration: configuration, transport: transport)
        let rootURL = URL(fileURLWithPath: "/tmp/project")

        try await client.start()
        try await client.initialize(rootURL: rootURL)
        transport.pushServerPayload(Data("""
        {
          "jsonrpc": "2.0",
          "id": 92,
          "method": "workspace/workspaceFolders"
        }
        """.utf8))

        let response = try await responseObject(id: 92, in: transport)
        let result = try #require(response["result"] as? [[String: Any]])
        let folder = try #require(result.first)

        #expect(folder["uri"] as? String == rootURL.absoluteString)
        #expect(folder["name"] as? String == "project")
    }

    @Test("language server client decodes request responses")
    func testLanguageServerClientDecodesRequestResponses() async throws {
        let transport = FakeLanguageServerTransport()
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.swift, transport: transport)

        try await client.start()
        let task = Task {
            try await client.definition(
                url: URL(fileURLWithPath: "/tmp/App.swift"),
                position: LSPPosition(line: 0, character: 5)
            )
        }

        while transport.sentPayloads.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let request = try #require(try JSONSerialization.jsonObject(with: transport.sentPayloads[0]) as? [String: Any])
        let id = try #require(request["id"] as? Int)
        let response = """
        {
          "jsonrpc": "2.0",
          "id": \(id),
          "result": [{
            "uri": "file:///tmp/App.swift",
            "range": {
              "start": { "line": 2, "character": 4 },
              "end": { "line": 2, "character": 10 }
            }
          }]
        }
        """.data(using: .utf8)!

        transport.pushServerPayload(response)
        let locations = try await task.value

        #expect(locations.count == 1)
        #expect(locations[0].uri == "file:///tmp/App.swift")
        #expect(locations[0].range.start.line == 2)
    }

    @Test("LSP hover content accepts markdown and marked string arrays")
    func testLSPHoverContentDecodesCommonShapes() throws {
        let markdown = try JSONDecoder().decode(LSPHover.self, from: Data("""
        {
          "contents": {
            "kind": "markdown",
            "value": "**Service** docs"
          }
        }
        """.utf8))
        let array = try JSONDecoder().decode(LSPHover.self, from: Data("""
        {
          "contents": [
            "plain docs",
            { "language": "go", "value": "func main()" }
          ]
        }
        """.utf8))

        #expect(markdown.contents.plainText == "**Service** docs")
        #expect(array.contents.plainText == "plain docs\n\n```go\nfunc main()\n```")
    }

    @Test("LSP completion result decodes array list and null shapes")
    func testLSPCompletionResultDecodesCommonShapes() throws {
        let items = try JSONDecoder().decode(LSPCompletionResult.self, from: Data("""
        [
          {
            "label": "Println",
            "kind": 3,
            "detail": "func",
            "insertText": "Println()"
          }
        ]
        """.utf8))
        let list = try JSONDecoder().decode(LSPCompletionResult.self, from: Data("""
        {
          "isIncomplete": false,
          "items": [
            {
              "label": "value",
              "documentation": {
                "kind": "markdown",
                "value": "Value docs"
              }
            }
          ]
        }
        """.utf8))
        let empty = try JSONDecoder().decode(LSPCompletionResult.self, from: Data("null".utf8))

        #expect(items.items.first?.label == "Println")
        #expect(items.items.first?.insertText == "Println()")
        #expect(list.items.first?.documentation?.plainText == "Value docs")
        #expect(empty.items.isEmpty)
    }

    @Test("LSP signature help decodes parameter string and range labels")
    func testLSPSignatureHelpDecodesParameterLabels() throws {
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: Data("""
        {
          "signatures": [{
            "label": "Println(a any, b string)",
            "documentation": { "kind": "markdown", "value": "Print docs" },
            "parameters": [
              { "label": [8, 13], "documentation": "first value" },
              { "label": "b string" }
            ],
            "activeParameter": 1
          }],
          "activeSignature": 0,
          "activeParameter": 0
        }
        """.utf8))
        let signature = try #require(help.signatures.first)
        let parameters = try #require(signature.parameters)

        #expect(signature.documentation?.plainText == "Print docs")
        #expect(parameters[0].label.text(in: signature.label) == "a any")
        #expect(parameters[0].documentation?.plainText == "first value")
        #expect(parameters[1].label.text(in: signature.label) == "b string")
    }

    @Test("LSP code action result decodes edits commands and null")
    func testLSPCodeActionResultDecodesCommonShapes() throws {
        let result = try JSONDecoder().decode(LSPCodeActionResult.self, from: Data("""
        [
          {
            "title": "Import fmt",
            "kind": "quickfix",
            "isPreferred": true,
            "edit": {
              "changes": {
                "file:///tmp/main.go": [{
                  "range": {
                    "start": { "line": 1, "character": 0 },
                    "end": { "line": 1, "character": 0 }
                  },
                  "newText": "import \\"fmt\\"\\n"
                }]
              }
            }
          },
          {
            "title": "Organize Imports",
            "command": "source.organizeImports"
          }
        ]
        """.utf8))
        let empty = try JSONDecoder().decode(LSPCodeActionResult.self, from: Data("null".utf8))

        #expect(result.actions.count == 2)
        #expect(result.actions[0].title == "Import fmt")
        #expect(result.actions[0].isPreferred == true)
        #expect(result.actions[0].edit?.textEditChanges["file:///tmp/main.go"]?.first?.newText == "import \"fmt\"\n")
        #expect(result.actions[1].command?.command == "source.organizeImports")
        #expect(empty.actions.isEmpty)
    }

    @Test("LSP workspace edit decodes changes and text document edits")
    func testLSPWorkspaceEditDecodesCommonShapes() throws {
        let edit = try JSONDecoder().decode(LSPWorkspaceEdit.self, from: Data("""
        {
          "changes": {
            "file:///tmp/main.go": [{
              "range": {
                "start": { "line": 3, "character": 13 },
                "end": { "line": 3, "character": 18 }
              },
              "newText": "renamedValue"
            }]
          },
          "documentChanges": [
            {
              "textDocument": { "uri": "file:///tmp/other.go", "version": null },
              "edits": [{
                "range": {
                  "start": { "line": 0, "character": 4 },
                  "end": { "line": 0, "character": 9 }
                },
                "newText": "renamedValue"
              }]
            },
            { "kind": "rename", "oldUri": "file:///tmp/a.go", "newUri": "file:///tmp/b.go" }
          ]
        }
        """.utf8))

        let changes = edit.textEditChanges

        #expect(changes["file:///tmp/main.go"]?.first?.newText == "renamedValue")
        #expect(changes["file:///tmp/other.go"]?.first?.range.start.character == 4)
        #expect(changes.count == 2)
    }

    @Test("LSP semantic token decoder maps relative token data into editor ranges")
    func testSemanticTokenDecoderMapsRelativeTokens() throws {
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let spans = EditorSemanticTokenDecoder.spans(
            from: FakeLanguageServerTransport.semanticTokens,
            legend: FakeLanguageServerTransport.semanticLegend,
            text: text
        )

        let printlnRange = (text as NSString).range(of: "Println")
        let valueRange = (text as NSString).range(of: "value")

        #expect(spans.count == 2)
        #expect(spans[0].range == printlnRange)
        #expect(spans[0].tokenType == "function")
        #expect(spans[0].tokenModifiers == ["definition"])
        #expect(spans[1].range == valueRange)
        #expect(spans[1].tokenType == "variable")
    }

    @Test("LSP position converts editor UTF-16 offsets into line and character")
    func testLSPPositionConvertsUTF16Offsets() {
        let text = "let icon = \"🧠\"\nprint(icon)\n"
        let secondLineOffset = (text as NSString).range(of: "print").location
        let emojiEndOffset = (text as NSString).range(of: "🧠").upperBound

        #expect(LSPPosition(utf16Offset: secondLineOffset, in: text) == LSPPosition(line: 1, character: 0))
        #expect(LSPPosition(utf16Offset: emojiEndOffset, in: text) == LSPPosition(line: 0, character: 14))
        #expect(LSPPosition(line: 1, character: 0).utf16Offset(in: text) == secondLineOffset)
        #expect(LSPRange(
            start: LSPPosition(line: 0, character: 12),
            end: LSPPosition(line: 0, character: 14)
        ).nsRange(in: text) == (text as NSString).range(of: "🧠"))
    }

    @Test("language service manager opens documents and resolves definitions through LSP")
    func testLanguageServiceManagerResolvesDefinitionThroughLSP() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let locations = try await manager.definition(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let definitionRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/definition"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: definitionRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("initialized"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/definition"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(locations == [FakeLanguageServerTransport.definitionLocation])
    }

    @Test("language service manager synchronizes document before didSave")
    func testLanguageServiceManagerSynchronizesDocumentBeforeDidSave() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\nfunc main() {}\n"

        try await manager.saveDocument(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let didOpenIndex = try #require(methods.firstIndex(of: "textDocument/didOpen"))
        let didSaveIndex = try #require(methods.firstIndex(of: "textDocument/didSave"))
        let didSavePayload = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/didSave"
        })
        let object = try #require(try JSONSerialization.jsonObject(with: didSavePayload) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])

        #expect(didOpenIndex < didSaveIndex)
        #expect(params["text"] as? String == text)
    }

    @Test("language service manager synchronizes document before willSaveWaitUntil")
    func testLanguageServiceManagerSynchronizesDocumentBeforeWillSaveWaitUntil() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\nfunc main() {}\n"

        let edits = try await manager.willSaveWaitUntil(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let didOpenIndex = try #require(methods.firstIndex(of: "textDocument/didOpen"))
        let willSaveIndex = try #require(methods.firstIndex(of: "textDocument/willSaveWaitUntil"))

        #expect(didOpenIndex < willSaveIndex)
        #expect(edits == FakeLanguageServerTransport.willSaveEdits)
    }

    @Test("language service manager notifies existing workspace sessions about non-source file changes")
    func testLanguageServiceManagerNotifiesExistingWorkspaceSessionsAboutNonSourceFileChanges() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let rootURL = URL(fileURLWithPath: "/tmp")
        let sourceURL = rootURL.appendingPathComponent("main.go")
        let packageURL = rootURL.appendingPathComponent("package.json")

        _ = try await manager.hover(
            fileURL: sourceURL,
            language: .go,
            rootDirectory: rootURL,
            text: "package main\n",
            characterOffset: 0
        )
        try await manager.didChangeWatchedFiles(
            fileURL: packageURL,
            language: nil,
            rootDirectory: rootURL,
            type: .changed
        )

        let watchedPayload = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "workspace/didChangeWatchedFiles"
        })
        let object = try #require(try JSONSerialization.jsonObject(with: watchedPayload) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let changes = try #require(params["changes"] as? [[String: Any]])
        let firstChange = try #require(changes.first)

        #expect(firstChange["uri"] as? String == packageURL.absoluteString)
        #expect(firstChange["type"] as? Int == LSPFileChangeType.changed.rawValue)
    }

    @Test("language service manager requests type definitions through LSP")
    func testLanguageServiceManagerRequestsTypeDefinition() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let locations = try await manager.typeDefinition(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let typeDefinitionRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/typeDefinition"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: typeDefinitionRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/typeDefinition"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(locations == [FakeLanguageServerTransport.typeDefinitionLocation])
    }

    @Test("language service manager resolves completion items through LSP")
    func testLanguageServiceManagerResolvesCompletionItems() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\n\nfunc main() {\n\tfmt.Pr\n}\n"

        let resolved = try await manager.resolveCompletionItem(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            item: FakeLanguageServerTransport.unresolvedCompletion
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let didOpenIndex = try #require(methods.firstIndex(of: "textDocument/didOpen"))
        let resolveIndex = try #require(methods.firstIndex(of: "completionItem/resolve"))
        let resolveRequest = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "completionItem/resolve"
        })
        let request = try #require(try JSONSerialization.jsonObject(with: resolveRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])

        #expect(didOpenIndex < resolveIndex)
        #expect(params["label"] as? String == "Println")
        #expect((params["data"] as? [String: Any])?["serverID"] as? String == "completion-println")
        #expect(resolved.detail == "func Println(a ...any)")
        #expect(resolved.additionalTextEdits?.first?.newText == "import \"fmt\"\n")
    }

    @Test("language service manager requests implementations through LSP")
    func testLanguageServiceManagerRequestsImplementation() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let locations = try await manager.implementation(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let implementationRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/implementation"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: implementationRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/implementation"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(locations == [FakeLanguageServerTransport.implementationLocation])
    }

    @Test("language service manager requests references through LSP")
    func testLanguageServiceManagerRequestsReferences() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let locations = try await manager.references(
            fileURL: fileURL,
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let referencesRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/references"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: referencesRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])
        let context = try #require(params["context"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/references"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(context["includeDeclaration"] as? Bool == true)
        #expect(locations == FakeLanguageServerTransport.referenceLocations)
    }

    @Test("editor reference item maps LSP location into display metadata")
    func testEditorReferenceItemMapsLSPMetadata() throws {
        let item = try #require(EditorReferenceItem(
            location: FakeLanguageServerTransport.referenceLocations[0],
            previewText: "\tfmt.Println(value)"
        ))

        #expect(item.fileName == "main.go")
        #expect(item.line == 4)
        #expect(item.column == 14)
        #expect(item.preview == "fmt.Println(value)")
    }

    @Test("language service manager requests document formatting through LSP")
    func testLanguageServiceManagerRequestsDocumentFormatting() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let edits = try await manager.documentFormatting(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: FakeLanguageServerTransport.unformattedText,
            options: LSPFormattingOptions(
                tabSize: 2,
                insertSpaces: false,
                trimTrailingWhitespace: true,
                insertFinalNewline: true,
                trimFinalNewlines: false
            )
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let formattingRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/formatting"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: formattingRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let options = try #require(params["options"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/formatting"))
        #expect(options["tabSize"] as? Int == 2)
        #expect(options["insertSpaces"] as? Bool == false)
        #expect(options["trimTrailingWhitespace"] as? Bool == true)
        #expect(options["insertFinalNewline"] as? Bool == true)
        #expect(options["trimFinalNewlines"] as? Bool == false)
        #expect(edits == FakeLanguageServerTransport.formattingEdits)
    }

    @Test("language service manager requests document range formatting through LSP")
    func testLanguageServiceManagerRequestsDocumentRangeFormatting() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let selectedRange = LSPRange(
            start: LSPPosition(line: 2, character: 0),
            end: LSPPosition(line: 3, character: 18)
        )

        let edits = try await manager.documentRangeFormatting(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: FakeLanguageServerTransport.unformattedText,
            range: selectedRange,
            options: LSPFormattingOptions(tabSize: 4, insertSpaces: true)
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let formattingRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/rangeFormatting"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: formattingRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let range = try #require(params["range"] as? [String: Any])
        let start = try #require(range["start"] as? [String: Any])
        let end = try #require(range["end"] as? [String: Any])
        let options = try #require(params["options"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/rangeFormatting"))
        #expect(start["line"] as? Int == 2)
        #expect(start["character"] as? Int == 0)
        #expect(end["line"] as? Int == 3)
        #expect(end["character"] as? Int == 18)
        #expect(options["tabSize"] as? Int == 4)
        #expect(options["insertSpaces"] as? Bool == true)
        #expect(edits == FakeLanguageServerTransport.formattingEdits)
    }

    @Test("editor text edit applier applies LSP edits from the end of the document")
    func testEditorTextEditApplierAppliesFormattingEdits() {
        let formatted = EditorTextEditApplier.apply(
            edits: FakeLanguageServerTransport.formattingEdits,
            to: FakeLanguageServerTransport.unformattedText
        )

        #expect(formatted == FakeLanguageServerTransport.formattedText)
    }

    @Test("language service manager requests rename through LSP")
    func testLanguageServiceManagerRequestsRename() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let edit = try await manager.rename(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset,
            newName: "renamedValue"
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let renameRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/rename"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: renameRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/rename"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(params["newName"] as? String == "renamedValue")
        #expect(edit.textEditChanges["file:///tmp/main.go"] == FakeLanguageServerTransport.renameEdits)
    }

    @Test("workspace edit applier filters file changes and applies rename edits")
    func testWorkspaceEditApplierMapsRenameEdits() throws {
        let edit = LSPWorkspaceEdit(changes: [
            "file:///tmp/main.go": FakeLanguageServerTransport.renameEdits,
            "https://example.test/main.go": FakeLanguageServerTransport.renameEdits
        ])

        let changes = EditorWorkspaceEditApplier.fileChanges(from: edit)
        let firstChange = try #require(changes.first)
        let renamed = try #require(EditorWorkspaceEditApplier.apply(
            fileChange: firstChange,
            to: "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        ))

        #expect(changes.count == 1)
        #expect(renamed.contains("renamedValue"))
        #expect(EditorWorkspaceEditApplier.isSafeFileURL(
            URL(fileURLWithPath: "/tmp/main.go"),
            inside: URL(fileURLWithPath: "/tmp")
        ))
        #expect(!EditorWorkspaceEditApplier.isSafeFileURL(
            URL(fileURLWithPath: "/private/main.go"),
            inside: URL(fileURLWithPath: "/tmp")
        ))
    }

    @Test("outline extractor maps nested LSP document symbols")
    func testOutlineExtractorMapsLSPDocumentSymbols() {
        let outline = EditorOutlineExtractor.outline(from: FakeLanguageServerTransport.documentSymbols)

        #expect(outline.map(\.title) == ["Service", "start ()", "endpoint string"])
        #expect(outline.map(\.kind) == [.type, .function, .property])
        #expect(outline.map(\.line) == [2, 3, 6])
        #expect(outline.map(\.level) == [0, 1, 0])
    }

    @Test("language service manager requests document symbols through LSP")
    func testLanguageServiceManagerRequestsDocumentSymbols() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let symbols = try await manager.documentSymbols(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: "package main\n\ntype Service struct {}\n"
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/documentSymbol"))
        #expect(symbols == FakeLanguageServerTransport.documentSymbols)
    }

    @Test("language service manager requests workspace symbols through LSP")
    func testLanguageServiceManagerRequestsWorkspaceSymbols() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"

        let items = try await manager.workspaceSymbols(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            query: "Service"
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let symbolRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "workspace/symbol"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: symbolRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("workspace/symbol"))
        #expect(params["query"] as? String == "Service")
        #expect(items.map(\.name) == ["Service", "start"])
        #expect(items.map(\.fileName) == ["service.go", "service.go"])
        #expect(items.map(\.line) == [2, 8])
        #expect(items.map(\.kind) == [.type, .function])
    }

    @Test("language service manager requests selection ranges through LSP")
    func testLanguageServiceManagerRequestsSelectionRanges() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let ranges = try await manager.selectionRanges(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let selectionRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/selectionRange"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: selectionRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let positions = try #require(params["positions"] as? [[String: Any]])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/selectionRange"))
        #expect(positions.first?["line"] as? Int == 3)
        #expect(positions.first?["character"] as? Int == 13)
        #expect(ranges == [
            (text as NSString).range(of: "value"),
            (text as NSString).range(of: "fmt.Println(value)"),
            (text as NSString).range(of: "\tfmt.Println(value)\n")
        ])
    }

    @Test("language service manager requests call hierarchy through LSP")
    func testLanguageServiceManagerRequestsCallHierarchy() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "main()").location

        let response = try await manager.callHierarchy(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let prepareRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/prepareCallHierarchy"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: prepareRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])
        let target = try #require(response.target)

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/prepareCallHierarchy"))
        #expect(methods.contains("callHierarchy/incomingCalls"))
        #expect(methods.contains("callHierarchy/outgoingCalls"))
        #expect(position["line"] as? Int == 2)
        #expect(position["character"] as? Int == 5)
        #expect(target.name == "main")
        #expect(response.incoming.map(\.from.name) == ["run"])
        #expect(response.outgoing.map(\.to.name) == ["Println"])
    }

    @Test("editor selection range resolver expands to the next larger semantic range")
    func testEditorSelectionRangeResolverExpandsToNextLargerRange() {
        let ranges = [
            NSRange(location: 10, length: 5),
            NSRange(location: 6, length: 18),
            NSRange(location: 0, length: 32)
        ]

        #expect(EditorSelectionRangeResolver.expandedRange(
            from: ranges,
            currentRange: NSRange(location: 12, length: 0),
            textLength: 40
        ) == NSRange(location: 10, length: 5))
        #expect(EditorSelectionRangeResolver.expandedRange(
            from: ranges,
            currentRange: NSRange(location: 10, length: 5),
            textLength: 40
        ) == NSRange(location: 6, length: 18))
        #expect(EditorSelectionRangeResolver.expandedRange(
            from: ranges,
            currentRange: NSRange(location: 0, length: 32),
            textLength: 40
        ) == nil)
    }

    @Test("language service manager requests hover through LSP")
    func testLanguageServiceManagerRequestsHover() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let hover = try await manager.hover(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let hoverRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/hover"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: hoverRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/hover"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(hover?.contents.plainText == FakeLanguageServerTransport.hover.contents.plainText)
    }

    @Test("language service manager requests completion through LSP")
    func testLanguageServiceManagerRequestsCompletion() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let offset = (text as NSString).range(of: "value").location

        let items = try await manager.completion(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let completionRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/completion"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: completionRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/completion"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(items == FakeLanguageServerTransport.completions)
    }

    @Test("language service manager requests signature help through LSP")
    func testLanguageServiceManagerRequestsSignatureHelp() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value, \"ok\")\n}\n"
        let offset = (text as NSString).range(of: "\"ok\"").location

        let help = try await manager.signatureHelp(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let signatureRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/signatureHelp"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: signatureRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/signatureHelp"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 20)
        #expect(help == FakeLanguageServerTransport.signatureHelp)
    }

    @Test("language service manager requests code actions through LSP")
    func testLanguageServiceManagerRequestsCodeActions() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
        let range = LSPRange(
            start: LSPPosition(line: 3, character: 13),
            end: LSPPosition(line: 3, character: 18)
        )

        let actions = try await manager.codeActions(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            range: range,
            diagnostics: FakeLanguageServerTransport.diagnostics
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let codeActionRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/codeAction"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: codeActionRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let context = try #require(params["context"] as? [String: Any])
        let diagnostics = try #require(context["diagnostics"] as? [[String: Any]])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/codeAction"))
        #expect(diagnostics.first?["message"] as? String == "undefined: value")
        #expect(actions == FakeLanguageServerTransport.codeActions)
    }

    @Test("language service manager resolves code actions through LSP")
    func testLanguageServiceManagerResolvesCodeActions() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"

        let resolved = try await manager.resolveCodeAction(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            action: FakeLanguageServerTransport.unresolvedCodeAction
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let didOpenIndex = try #require(methods.firstIndex(of: "textDocument/didOpen"))
        let resolveIndex = try #require(methods.firstIndex(of: "codeAction/resolve"))
        let resolveRequest = try #require(transport.sentPayloads.first {
            FakeLanguageServerTransport.methodName(from: $0) == "codeAction/resolve"
        })
        let request = try #require(try JSONSerialization.jsonObject(with: resolveRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])

        #expect(didOpenIndex < resolveIndex)
        #expect(params["title"] as? String == "Create missing value")
        #expect((params["data"] as? [String: Any])?["serverID"] as? String == "code-action-create-value")
        #expect(resolved.edit?.textEditChanges["file:///tmp/main.go"]?.first?.newText == "func value() string { return \"ok\" }\n")
    }

    @Test("language service manager requests document highlights through LSP")
    func testLanguageServiceManagerRequestsDocumentHighlights() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n\tvalue = 2\n}\n"
        let nsText = text as NSString
        let firstValueRange = nsText.range(of: "value")
        let secondSearchRange = NSRange(
            location: NSMaxRange(firstValueRange),
            length: nsText.length - NSMaxRange(firstValueRange)
        )
        let secondValueRange = nsText.range(of: "value", options: [], range: secondSearchRange)
        let offset = firstValueRange.location

        let spans = try await manager.documentHighlights(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text,
            characterOffset: offset
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        let highlightRequest = try #require(transport.sentPayloads.first(where: {
            FakeLanguageServerTransport.methodName(from: $0) == "textDocument/documentHighlight"
        }))
        let request = try #require(try JSONSerialization.jsonObject(with: highlightRequest) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let position = try #require(params["position"] as? [String: Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/documentHighlight"))
        #expect(position["line"] as? Int == 3)
        #expect(position["character"] as? Int == 13)
        #expect(spans.map(\.range) == [firstValueRange, secondValueRange])
        #expect(spans.map(\.kind) == [2, 3])
    }

    @Test("language service manager requests semantic tokens through LSP")
    func testLanguageServiceManagerRequestsSemanticTokens() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"

        let spans = try await manager.semanticTokens(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/semanticTokens/full"))
        #expect(spans.map(\.tokenType) == ["function", "variable"])
        #expect(spans.map(\.range) == [
            (text as NSString).range(of: "Println"),
            (text as NSString).range(of: "value")
        ])
    }

    @Test("LSP folding ranges map to editor scope guides")
    func testFoldingRangesMapToScopeGuides() {
        let guides = EditorFoldingRangeMapper.scopeGuides(from: [
            LSPFoldingRange(startLine: 1, startCharacter: 2, endLine: 4, kind: "region"),
            LSPFoldingRange(startLine: 2, startCharacter: 4, endLine: 3, kind: "imports"),
            LSPFoldingRange(startLine: 5, startCharacter: 0, endLine: 5, kind: "comment")
        ])

        #expect(guides == [
            ScopeGuide(startLine: 2, endLine: 5, column: 2, depth: 0),
            ScopeGuide(startLine: 3, endLine: 4, column: 4, depth: 1)
        ])
    }

    @Test("language service manager requests folding ranges through LSP")
    func testLanguageServiceManagerRequestsFoldingRanges() async throws {
        let transport = FakeLanguageServerTransport()
        transport.autoRespond = true
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let text = "package main\n\nfunc main() {\n\tif value {\n\t\tfmt.Println(value)\n\t}\n}\n"

        let guides = try await manager.foldingRanges(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: text
        )

        let methods = transport.sentPayloads.compactMap(FakeLanguageServerTransport.methodName)
        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("textDocument/foldingRange"))
        #expect(guides == [
            ScopeGuide(startLine: 3, endLine: 7, column: 0, depth: 0),
            ScopeGuide(startLine: 4, endLine: 6, column: 1, depth: 1)
        ])
    }

    @Test("editor hover info converts non-empty LSP hover content")
    func testEditorHoverInfoConvertsLSPHover() throws {
        let request = EditorHoverRequest(symbol: "value", characterOffset: 12)
        let info = try #require(EditorHoverInfo(request: request, hover: FakeLanguageServerTransport.hover))

        #expect(info.title == "value")
        #expect(info.content == "```go\nfunc value() string\n```")
        #expect(info.isLoading == false)
        #expect(EditorHoverInfo(request: request, hover: nil) == nil)
    }

    @Test("editor signature help state highlights active parameter")
    func testEditorSignatureHelpPanelStateHighlightsActiveParameter() throws {
        let request = EditorSignatureHelpRequest(characterOffset: 42)
        let state = try #require(EditorSignatureHelpPanelState(
            request: request,
            signatureHelp: FakeLanguageServerTransport.signatureHelp
        ))

        #expect(state.signatureLabel == "Println(a any, b string)")
        #expect(state.documentation == "Print docs")
        #expect(state.parameters.map(\.label) == ["a any", "b string"])
        #expect(state.parameters.map(\.isActive) == [false, true])
        #expect(state.parameters[0].documentation == "first value")
        #expect(EditorSignatureHelpPanelState(request: request, signatureHelp: nil) == nil)
    }

    @Test("editor code action item maps LSP action metadata")
    func testEditorCodeActionItemMapsLSPMetadata() throws {
        let action = try #require(FakeLanguageServerTransport.codeActions.first)
        let item = EditorCodeActionItem(action: action, index: 0)

        #expect(item.title == "Import fmt")
        #expect(item.kind == "quickfix")
        #expect(item.isPreferred == true)
        #expect(item.edit?.textEditChanges["file:///tmp/main.go"]?.first?.newText == "import \"fmt\"\n")
    }

    @Test("language server client surfaces publish diagnostics notifications")
    func testLanguageServerClientSurfacesDiagnosticsNotifications() async throws {
        let transport = FakeLanguageServerTransport()
        let client = LanguageServerClient(configuration: EditorLanguageServiceRegistry.go, transport: transport)
        final class DiagnosticsCapture: @unchecked Sendable {
            var uri: String?
            var diagnostics: [LSPDiagnostic] = []
        }
        let capture = DiagnosticsCapture()

        await client.setDiagnosticsHandler { uri, diagnostics in
            capture.uri = uri
            capture.diagnostics = diagnostics
        }
        try await client.start()
        transport.pushServerPayload(FakeLanguageServerTransport.publishDiagnosticsPayload())

        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(capture.uri == "file:///tmp/main.go")
        #expect(capture.diagnostics == FakeLanguageServerTransport.diagnostics)
    }

    @Test("editor diagnostic issues preserve LSP severity and UTF-16 range")
    func testEditorDiagnosticIssueConvertsLSPDiagnostic() throws {
        let text = "let icon = \"🧠\"\nprint(icon)\n"
        let diagnostic = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 12),
                end: LSPPosition(line: 0, character: 14)
            ),
            severity: 1,
            code: .string("E001"),
            source: "sourcekit-lsp",
            message: "Unexpected icon"
        )

        let issue = try #require(EditorDiagnosticIssue(diagnostic: diagnostic, in: text))

        #expect(issue.range == (text as NSString).range(of: "🧠"))
        #expect(issue.line == 1)
        #expect(issue.severity == .error)
        #expect(issue.message == "Unexpected icon")
        #expect(issue.source == "sourcekit-lsp")
    }

    @Test("editor completion items prefer insert text and fall back to label")
    func testEditorCompletionItemUsesInsertTextFallback() {
        let fallback = EditorCompletionItem(
            item: LSPCompletionItem(
                label: "value",
                kind: 6,
                detail: "string",
                documentation: .markdown("Value docs"),
                insertText: nil,
                sortText: nil,
                filterText: nil
            ),
            index: 0
        )
        let explicit = EditorCompletionItem(
            item: LSPCompletionItem(
                label: "valueFactory",
                kind: 3,
                detail: "func",
                documentation: nil,
                insertText: "valueFactory()",
                sortText: nil,
                filterText: nil
            ),
            index: 1
        )

        #expect(fallback.insertText == "value")
        #expect(fallback.documentation == "Value docs")
        #expect(explicit.insertText == "valueFactory()")
    }

    @Test("LSP document highlight result decodes arrays and null")
    func testLSPDocumentHighlightResultDecodesArraysAndNull() throws {
        let highlights = try JSONDecoder().decode(LSPDocumentHighlightResult.self, from: Data("""
        [
          {
            "range": {
              "start": { "line": 0, "character": 4 },
              "end": { "line": 0, "character": 9 }
            },
            "kind": 2
          }
        ]
        """.utf8))
        let none = try JSONDecoder().decode(LSPDocumentHighlightResult.self, from: Data("null".utf8))

        #expect(highlights.highlights.count == 1)
        #expect(highlights.highlights.first?.kind == 2)
        #expect(none.highlights.isEmpty)
    }

    @Test("semantic token spans override regex highlight colors")
    func testSemanticTokenSpansOverrideRegexHighlightColors() {
        let text = "func value() {}\n"
        let valueRange = (text as NSString).range(of: "value")
        let highlighted = SyntaxHighlighter.highlightSync(
            text,
            language: .swift,
            theme: .paper,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            semanticTokenSpans: [
                EditorSemanticTokenSpan(
                    range: valueRange,
                    tokenType: "function",
                    tokenModifiers: ["definition"]
                )
            ]
        )
        let attributes = highlighted.attributes(at: valueRange.location, effectiveRange: nil)

        #expect((attributes[.foregroundColor] as? NSColor)?.isEqual(EditorTheme.paper.headerColor) == true)
        #expect(attributes[.font] != nil)
    }

    @Test("semantic token spans color variables parameters and labels")
    func testSemanticTokenSpansColorCommonIdentifierKinds() {
        let text = "func greet(name: String) { let Value = name }\n"
        let nsText = text as NSString
        let valueRange = nsText.range(of: "Value")
        let nameRange = nsText.range(of: "name")
        let highlighted = SyntaxHighlighter.highlightSync(
            text,
            language: .swift,
            theme: .paper,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            semanticTokenSpans: [
                EditorSemanticTokenSpan(
                    range: valueRange,
                    tokenType: "variable",
                    tokenModifiers: ["definition"]
                ),
                EditorSemanticTokenSpan(
                    range: nameRange,
                    tokenType: "parameter",
                    tokenModifiers: []
                )
            ]
        )

        let valueAttributes = highlighted.attributes(at: valueRange.location, effectiveRange: nil)
        let nameColor = highlighted.attribute(.foregroundColor, at: nameRange.location, effectiveRange: nil) as? NSColor

        #expect((valueAttributes[.foregroundColor] as? NSColor)?.isEqual(EditorTheme.paper.foregroundColor) == true)
        #expect(valueAttributes[.font] != nil)
        #expect(nameColor?.isEqual(EditorTheme.paper.numberColor) == true)
    }

    private func responseObject(id: Int, in transport: FakeLanguageServerTransport) async throws -> [String: Any] {
        for _ in 0..<100 {
            if let object = transport.sentPayloads.compactMap({ payload -> [String: Any]? in
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      object["id"] as? Int == id,
                      object["method"] == nil else {
                    return nil
                }
                return object
            }).first {
                return object
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try #require(nil as [String: Any]?)
    }
}

private final class FakeLanguageServerTransport: LanguageServerTransport {
    static let definitionLocation = LSPLocation(
        uri: "file:///tmp/main.go",
        range: LSPRange(
            start: LSPPosition(line: 8, character: 1),
            end: LSPPosition(line: 8, character: 6)
        )
    )

    static let referenceLocations = [
        LSPLocation(
            uri: "file:///tmp/main.go",
            range: LSPRange(
                start: LSPPosition(line: 3, character: 13),
                end: LSPPosition(line: 3, character: 18)
            )
        )
    ]

    static let typeDefinitionLocation = LSPLocation(
        uri: "file:///tmp/types.go",
        range: LSPRange(
            start: LSPPosition(line: 1, character: 5),
            end: LSPPosition(line: 1, character: 10)
        )
    )

    static let implementationLocation = LSPLocation(
        uri: "file:///tmp/impl.go",
        range: LSPRange(
            start: LSPPosition(line: 5, character: 0),
            end: LSPPosition(line: 8, character: 1)
        )
    )

    static let unformattedText = "package main\n\nfunc main(){\nfmt.Println(value)\n}\n"
    static let formattedText = "package main\n\nfunc main() {\n\tfmt.Println(value)\n}\n"
    static let formattingEdits = [
        LSPTextEdit(
            range: LSPRange(
                start: LSPPosition(line: 2, character: 0),
                end: LSPPosition(line: 3, character: 18)
            ),
            newText: "func main() {\n\tfmt.Println(value)"
        )
    ]
    static let willSaveEdits = [
        LSPTextEdit(
            range: LSPRange(
                start: LSPPosition(line: 1, character: 0),
                end: LSPPosition(line: 1, character: 0)
            ),
            newText: "\n"
        )
    ]
    static let renameEdits = [
        LSPTextEdit(
            range: LSPRange(
                start: LSPPosition(line: 3, character: 13),
                end: LSPPosition(line: 3, character: 18)
            ),
            newText: "renamedValue"
        )
    ]

    static let documentSymbols = [
        LSPDocumentSymbol(
            name: "Service",
            detail: nil,
            kind: 23,
            range: LSPRange(
                start: LSPPosition(line: 1, character: 5),
                end: LSPPosition(line: 4, character: 1)
            ),
            selectionRange: LSPRange(
                start: LSPPosition(line: 1, character: 5),
                end: LSPPosition(line: 1, character: 12)
            ),
            children: [
                LSPDocumentSymbol(
                    name: "start",
                    detail: "()",
                    kind: 6,
                    range: LSPRange(
                        start: LSPPosition(line: 2, character: 4),
                        end: LSPPosition(line: 3, character: 5)
                    ),
                    selectionRange: LSPRange(
                        start: LSPPosition(line: 2, character: 9),
                        end: LSPPosition(line: 2, character: 14)
                    ),
                    children: nil
                )
            ]
        ),
        LSPDocumentSymbol(
            name: "endpoint",
            detail: "string",
            kind: 14,
            range: LSPRange(
                start: LSPPosition(line: 5, character: 6),
                end: LSPPosition(line: 5, character: 24)
            ),
            selectionRange: LSPRange(
                start: LSPPosition(line: 5, character: 6),
                end: LSPPosition(line: 5, character: 14)
            ),
            children: nil
        )
    ]

    static let workspaceSymbols = [
        LSPWorkspaceSymbol(
            name: "Service",
            kind: 23,
            location: LSPLocation(
                uri: "file:///tmp/service.go",
                range: LSPRange(
                    start: LSPPosition(line: 1, character: 5),
                    end: LSPPosition(line: 1, character: 12)
                )
            ),
            containerName: "api"
        ),
        LSPWorkspaceSymbol(
            name: "start",
            kind: 6,
            location: LSPLocation(
                uri: "file:///tmp/service.go",
                range: LSPRange(
                    start: LSPPosition(line: 7, character: 6),
                    end: LSPPosition(line: 7, character: 11)
                )
            ),
            containerName: "Service"
        )
    ]

    static let selectionRanges = [
        LSPSelectionRange(
            range: LSPRange(
                start: LSPPosition(line: 3, character: 13),
                end: LSPPosition(line: 3, character: 18)
            ),
            parent: LSPSelectionRange(
                range: LSPRange(
                    start: LSPPosition(line: 3, character: 1),
                    end: LSPPosition(line: 3, character: 19)
                ),
                parent: LSPSelectionRange(
                    range: LSPRange(
                        start: LSPPosition(line: 3, character: 0),
                        end: LSPPosition(line: 4, character: 0)
                    ),
                    parent: nil
                )
            )
        )
    ]

    static let callHierarchyTarget = LSPCallHierarchyItem(
        name: "main",
        kind: 12,
        tags: nil,
        detail: "func main()",
        uri: "file:///tmp/main.go",
        range: LSPRange(
            start: LSPPosition(line: 2, character: 0),
            end: LSPPosition(line: 4, character: 1)
        ),
        selectionRange: LSPRange(
            start: LSPPosition(line: 2, character: 5),
            end: LSPPosition(line: 2, character: 9)
        ),
        data: .object(["serverID": .string("target-main")])
    )

    static let callHierarchyIncoming = [
        LSPCallHierarchyIncomingCall(
            from: LSPCallHierarchyItem(
                name: "run",
                kind: 12,
                tags: nil,
                detail: "func run()",
                uri: "file:///tmp/runner.go",
                range: LSPRange(
                    start: LSPPosition(line: 9, character: 0),
                    end: LSPPosition(line: 11, character: 1)
                ),
                selectionRange: LSPRange(
                    start: LSPPosition(line: 9, character: 5),
                    end: LSPPosition(line: 9, character: 8)
                ),
                data: .object(["serverID": .string("incoming-run")])
            ),
            fromRanges: [
                LSPRange(
                    start: LSPPosition(line: 10, character: 1),
                    end: LSPPosition(line: 10, character: 7)
                )
            ]
        )
    ]

    static let callHierarchyOutgoing = [
        LSPCallHierarchyOutgoingCall(
            to: LSPCallHierarchyItem(
                name: "Println",
                kind: 12,
                tags: nil,
                detail: "func Println(a ...any)",
                uri: "file:///tmp/fmt.go",
                range: LSPRange(
                    start: LSPPosition(line: 20, character: 0),
                    end: LSPPosition(line: 22, character: 1)
                ),
                selectionRange: LSPRange(
                    start: LSPPosition(line: 20, character: 5),
                    end: LSPPosition(line: 20, character: 12)
                ),
                data: .object(["serverID": .string("outgoing-println")])
            ),
            fromRanges: [
                LSPRange(
                    start: LSPPosition(line: 3, character: 5),
                    end: LSPPosition(line: 3, character: 12)
                )
            ]
        )
    ]

    static let hover = LSPHover(
        contents: .markedString(.languageString(language: "go", value: "func value() string")),
        range: nil
    )

    static let completions = [
        LSPCompletionItem(
            label: "value",
            kind: 6,
            detail: "string",
            documentation: .markdown("Value docs"),
            insertText: "value",
            sortText: nil,
            filterText: nil
        ),
        LSPCompletionItem(
            label: "valueFactory",
            kind: 3,
            detail: "func",
            documentation: nil,
            insertText: "valueFactory()",
            sortText: nil,
            filterText: nil
        )
    ]

    static let unresolvedCompletion = LSPCompletionItem(
        label: "Println",
        kind: 3,
        insertText: "Println",
        data: .object(["serverID": .string("completion-println")])
    )

    static let resolvedCompletion = LSPCompletionItem(
        label: "Println",
        kind: 3,
        detail: "func Println(a ...any)",
        documentation: .markdown("Println formats using default formats and writes to standard output."),
        insertText: "Println(${1:value})$0",
        insertTextFormat: 2,
        additionalTextEdits: [
            LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 2, character: 0),
                    end: LSPPosition(line: 2, character: 0)
                ),
                newText: "import \"fmt\"\n"
            )
        ],
        data: .object(["serverID": .string("completion-println")])
    )

    static let signatureHelp = LSPSignatureHelp(
        signatures: [
            LSPSignatureInformation(
                label: "Println(a any, b string)",
                documentation: .markedString(.markdown("Print docs")),
                parameters: [
                    LSPParameterInformation(
                        label: .range(8, 13),
                        documentation: .markedString(.string("first value"))
                    ),
                    LSPParameterInformation(label: .string("b string"), documentation: nil)
                ],
                activeParameter: 1
            )
        ],
        activeSignature: 0,
        activeParameter: 0
    )

    static let documentHighlights = [
        LSPDocumentHighlight(
            range: LSPRange(
                start: LSPPosition(line: 3, character: 13),
                end: LSPPosition(line: 3, character: 18)
            ),
            kind: 2
        ),
        LSPDocumentHighlight(
            range: LSPRange(
                start: LSPPosition(line: 4, character: 1),
                end: LSPPosition(line: 4, character: 6)
            ),
            kind: 3
        )
    ]

    static let semanticLegend = LSPSemanticTokensLegend(
        tokenTypes: ["variable", "function"],
        tokenModifiers: ["definition"]
    )

    static let semanticTokens = LSPSemanticTokens(
        resultId: nil,
        data: [
            3, 5, 7, 1, 1,
            0, 8, 5, 0, 0
        ]
    )

    static let foldingRanges = [
        LSPFoldingRange(startLine: 2, startCharacter: 0, endLine: 6, endCharacter: 1, kind: "region"),
        LSPFoldingRange(startLine: 3, startCharacter: 1, endLine: 5, endCharacter: 2, kind: "region")
    ]

    static let diagnostics = [
        LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 2, character: 1),
                end: LSPPosition(line: 2, character: 8)
            ),
            severity: 1,
            code: .string("compile"),
            source: "gopls",
            message: "undefined: value"
        )
    ]

    static let codeActions = [
        LSPCodeAction(
            title: "Import fmt",
            kind: "quickfix",
            diagnostics: diagnostics,
            isPreferred: true,
            edit: LSPWorkspaceEdit(changes: [
                "file:///tmp/main.go": [
                    LSPTextEdit(
                        range: LSPRange(
                            start: LSPPosition(line: 1, character: 0),
                            end: LSPPosition(line: 1, character: 0)
                        ),
                        newText: "import \"fmt\"\n"
                    )
                ]
            ]),
            command: nil
        ),
        LSPCodeAction(
            title: "Organize Imports",
            command: LSPCommand(title: "Organize Imports", command: "source.organizeImports")
        )
    ]

    static let unresolvedCodeAction = LSPCodeAction(
        title: "Create missing value",
        kind: "quickfix",
        diagnostics: diagnostics,
        isPreferred: true,
        data: .object(["serverID": .string("code-action-create-value")])
    )

    static let resolvedCodeAction = LSPCodeAction(
        title: "Create missing value",
        kind: "quickfix",
        diagnostics: diagnostics,
        isPreferred: true,
        edit: LSPWorkspaceEdit(changes: [
            "file:///tmp/main.go": [
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 5, character: 0),
                        end: LSPPosition(line: 5, character: 0)
                    ),
                    newText: "func value() string { return \"ok\" }\n"
                )
            ]
        ]),
        data: .object(["serverID": .string("code-action-create-value")])
    )

    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    var autoRespond = false
    private(set) var sentPayloads: [Data] = []

    func start() throws {}

    func send(_ data: Data) throws {
        var buffer = data
        let payloads = LSPMessageFramer.extractMessages(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
        guard autoRespond else { return }
        for payload in payloads {
            respondIfNeeded(to: payload)
        }
    }

    func stop() {}

    func pushServerPayload(_ payload: Data) {
        onData?(LSPMessageFramer.frame(payload: payload))
    }

    static func publishDiagnosticsPayload() -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": "file:///tmp/main.go",
                "diagnostics": diagnostics.map { diagnostic in
                    [
                        "range": rangeObject(diagnostic.range),
                        "severity": diagnostic.severity ?? 3,
                        "code": "compile",
                        "source": diagnostic.source ?? "gopls",
                        "message": diagnostic.message
                    ]
                }
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

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
            pushServerPayload(responsePayload(id: id, result: [
                    "capabilities": [
                        "textDocumentSync": [
                            "openClose": true,
                            "change": 1,
                            "willSaveWaitUntil": true,
                            "save": [
                                "includeText": true
                            ]
                        ],
                        "definitionProvider": true,
                        "typeDefinitionProvider": true,
                        "implementationProvider": true,
                        "referencesProvider": true,
                        "workspaceSymbolProvider": true,
                        "documentFormattingProvider": true,
                        "documentRangeFormattingProvider": true,
                        "renameProvider": true,
                        "semanticTokensProvider": [
                            "legend": [
                                "tokenTypes": Self.semanticLegend.tokenTypes,
                                "tokenModifiers": Self.semanticLegend.tokenModifiers
                            ],
                            "full": true,
                            "range": false
                        ],
                        "signatureHelpProvider": [
                            "triggerCharacters": ["(", ","]
                        ],
                        "completionProvider": [
                            "triggerCharacters": ["."],
                            "resolveProvider": true
                        ],
                        "codeActionProvider": [
                            "resolveProvider": true
                        ],
                        "documentHighlightProvider": true,
                        "documentSymbolProvider": true,
                        "foldingRangeProvider": true,
                        "selectionRangeProvider": true,
                        "callHierarchyProvider": true
                    ]
            ]))
        case "textDocument/definition":
            pushServerPayload(responsePayload(id: id, result: [Self.locationObject(Self.definitionLocation)]))
        case "textDocument/typeDefinition":
            pushServerPayload(responsePayload(id: id, result: Self.locationObject(Self.typeDefinitionLocation)))
        case "textDocument/implementation":
            pushServerPayload(responsePayload(id: id, result: [Self.locationObject(Self.implementationLocation)]))
        case "textDocument/references":
            pushServerPayload(responsePayload(id: id, result: Self.referenceLocations.map(Self.locationObject)))
        case "textDocument/formatting":
            pushServerPayload(responsePayload(id: id, result: Self.formattingEdits.map(Self.textEditObject)))
        case "textDocument/willSaveWaitUntil":
            pushServerPayload(responsePayload(id: id, result: Self.willSaveEdits.map(Self.textEditObject)))
        case "textDocument/rangeFormatting":
            pushServerPayload(responsePayload(id: id, result: Self.formattingEdits.map(Self.textEditObject)))
        case "textDocument/rename":
            pushServerPayload(responsePayload(id: id, result: [
                "changes": [
                    "file:///tmp/main.go": Self.renameEdits.map(Self.textEditObject)
                ]
            ]))
        case "textDocument/documentSymbol":
            pushServerPayload(responsePayload(id: id, result: Self.documentSymbols.map(Self.documentSymbolObject)))
        case "workspace/symbol":
            pushServerPayload(responsePayload(id: id, result: Self.workspaceSymbols.map(Self.workspaceSymbolObject)))
        case "textDocument/selectionRange":
            pushServerPayload(responsePayload(id: id, result: Self.selectionRanges.map(Self.selectionRangeObject)))
        case "textDocument/prepareCallHierarchy":
            pushServerPayload(responsePayload(id: id, result: [Self.callHierarchyItemObject(Self.callHierarchyTarget)]))
        case "callHierarchy/incomingCalls":
            pushServerPayload(responsePayload(id: id, result: Self.callHierarchyIncoming.map(Self.callHierarchyIncomingObject)))
        case "callHierarchy/outgoingCalls":
            pushServerPayload(responsePayload(id: id, result: Self.callHierarchyOutgoing.map(Self.callHierarchyOutgoingObject)))
        case "textDocument/hover":
            pushServerPayload(responsePayload(id: id, result: [
                "contents": [
                    "language": "go",
                    "value": "func value() string"
                ]
            ]))
        case "textDocument/completion":
            pushServerPayload(responsePayload(id: id, result: [
                "isIncomplete": false,
                "items": Self.completions.map(Self.completionItemObject)
            ]))
        case "completionItem/resolve":
            pushServerPayload(responsePayload(id: id, result: Self.completionItemObject(Self.resolvedCompletion)))
        case "textDocument/signatureHelp":
            pushServerPayload(responsePayload(id: id, result: Self.signatureHelpObject(Self.signatureHelp)))
        case "textDocument/codeAction":
            pushServerPayload(responsePayload(id: id, result: Self.codeActions.map(Self.codeActionObject)))
        case "codeAction/resolve":
            pushServerPayload(responsePayload(id: id, result: Self.codeActionObject(Self.resolvedCodeAction)))
        case "textDocument/documentHighlight":
            pushServerPayload(responsePayload(id: id, result: Self.documentHighlights.map(Self.documentHighlightObject)))
        case "textDocument/semanticTokens/full":
            pushServerPayload(responsePayload(id: id, result: [
                "data": Self.semanticTokens.data
            ]))
        case "textDocument/foldingRange":
            pushServerPayload(responsePayload(id: id, result: Self.foldingRanges.map(Self.foldingRangeObject)))
        default:
            break
        }
    }

    private static func locationObject(_ location: LSPLocation) -> [String: Any] {
        [
            "uri": location.uri,
            "range": rangeObject(location.range)
        ]
    }

    private static func textEditObject(_ edit: LSPTextEdit) -> [String: Any] {
        [
            "range": rangeObject(edit.range),
            "newText": edit.newText
        ]
    }

    private static func codeActionObject(_ action: LSPCodeAction) -> [String: Any] {
        var object: [String: Any] = [
            "title": action.title
        ]
        if let kind = action.kind {
            object["kind"] = kind
        }
        if let diagnostics = action.diagnostics {
            object["diagnostics"] = diagnostics.map { diagnostic in
                var diagnosticObject: [String: Any] = [
                    "range": rangeObject(diagnostic.range),
                    "severity": diagnostic.severity ?? 3,
                    "source": diagnostic.source ?? "",
                    "message": diagnostic.message
                ]
                switch diagnostic.code {
                case .int(let value):
                    diagnosticObject["code"] = value
                case .string(let value):
                    diagnosticObject["code"] = value
                case nil:
                    break
                }
                return diagnosticObject
            }
        }
        if let isPreferred = action.isPreferred {
            object["isPreferred"] = isPreferred
        }
        if let edit = action.edit {
            object["edit"] = workspaceEditObject(edit)
        }
        if let command = action.command {
            object["command"] = [
                "title": command.title,
                "command": command.command
            ]
        }
        if let data = action.data {
            object["data"] = jsonObject(data)
        }
        return object
    }

    private static func workspaceEditObject(_ edit: LSPWorkspaceEdit) -> [String: Any] {
        var object: [String: Any] = [:]
        if !edit.changes.isEmpty {
            object["changes"] = edit.changes.mapValues { edits in
                edits.map(textEditObject)
            }
        }
        if !edit.documentChanges.isEmpty {
            object["documentChanges"] = edit.documentChanges.map { documentEdit in
                var textDocument: [String: Any] = [
                    "uri": documentEdit.textDocument.uri
                ]
                if let version = documentEdit.textDocument.version {
                    textDocument["version"] = version
                }
                return [
                    "textDocument": textDocument,
                    "edits": documentEdit.edits.map(textEditObject)
                ]
            }
        }
        return object
    }

    private static func foldingRangeObject(_ range: LSPFoldingRange) -> [String: Any] {
        var object: [String: Any] = [
            "startLine": range.startLine,
            "endLine": range.endLine
        ]
        if let startCharacter = range.startCharacter {
            object["startCharacter"] = startCharacter
        }
        if let endCharacter = range.endCharacter {
            object["endCharacter"] = endCharacter
        }
        if let kind = range.kind {
            object["kind"] = kind
        }
        return object
    }

    private static func documentHighlightObject(_ highlight: LSPDocumentHighlight) -> [String: Any] {
        var object: [String: Any] = [
            "range": rangeObject(highlight.range)
        ]
        if let kind = highlight.kind {
            object["kind"] = kind
        }
        return object
    }

    private static func completionItemObject(_ item: LSPCompletionItem) -> [String: Any] {
        var object: [String: Any] = [
            "label": item.label
        ]
        if let kind = item.kind {
            object["kind"] = kind
        }
        if let detail = item.detail {
            object["detail"] = detail
        }
        if let insertText = item.insertText {
            object["insertText"] = insertText
        }
        if let insertTextFormat = item.insertTextFormat {
            object["insertTextFormat"] = insertTextFormat
        }
        if let textEdit = item.textEdit {
            object["textEdit"] = textEditObject(textEdit.replacementEdit)
        }
        if let additionalTextEdits = item.additionalTextEdits {
            object["additionalTextEdits"] = additionalTextEdits.map(Self.textEditObject)
        }
        if let documentation = item.documentation {
            object["documentation"] = markedStringObject(documentation)
        }
        if let data = item.data {
            object["data"] = jsonObject(data)
        }
        return object
    }

    private static func jsonObject(_ value: LSPAnyValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        case .array(let values):
            return values.map(Self.jsonObject)
        case .object(let object):
            return object.mapValues(Self.jsonObject)
        }
    }

    private static func signatureHelpObject(_ help: LSPSignatureHelp) -> [String: Any] {
        var object: [String: Any] = [
            "signatures": help.signatures.map(Self.signatureInformationObject)
        ]
        if let activeSignature = help.activeSignature {
            object["activeSignature"] = activeSignature
        }
        if let activeParameter = help.activeParameter {
            object["activeParameter"] = activeParameter
        }
        return object
    }

    private static func signatureInformationObject(_ signature: LSPSignatureInformation) -> [String: Any] {
        var object: [String: Any] = [
            "label": signature.label
        ]
        if let documentation = signature.documentation {
            object["documentation"] = hoverContentObject(documentation)
        }
        if let parameters = signature.parameters {
            object["parameters"] = parameters.map { parameter in
                var parameterObject: [String: Any] = [
                    "label": parameterLabelObject(parameter.label)
                ]
                if let documentation = parameter.documentation {
                    parameterObject["documentation"] = hoverContentObject(documentation)
                }
                return parameterObject
            }
        }
        if let activeParameter = signature.activeParameter {
            object["activeParameter"] = activeParameter
        }
        return object
    }

    private static func parameterLabelObject(_ label: LSPParameterLabel) -> Any {
        switch label {
        case .string(let value):
            return value
        case .range(let start, let end):
            return [start, end]
        }
    }

    private static func hoverContentObject(_ content: LSPHoverContent) -> Any {
        switch content {
        case .markedString(let value):
            return markedStringObject(value)
        case .markedStrings(let values):
            return values.map(markedStringObject)
        }
    }

    private static func markedStringObject(_ value: LSPMarkedString) -> Any {
        switch value {
        case .string(let text):
            return text
        case .markdown(let text):
            return [
                "kind": "markdown",
                "value": text
            ]
        case .languageString(let language, let text):
            return [
                "language": language,
                "value": text
            ]
        }
    }

    private static func documentSymbolObject(_ symbol: LSPDocumentSymbol) -> [String: Any] {
        var object: [String: Any] = [
            "name": symbol.name,
            "kind": symbol.kind,
            "range": rangeObject(symbol.range),
            "selectionRange": rangeObject(symbol.selectionRange)
        ]
        if let detail = symbol.detail {
            object["detail"] = detail
        }
        if let children = symbol.children {
            object["children"] = children.map(documentSymbolObject)
        }
        return object
    }

    private static func workspaceSymbolObject(_ symbol: LSPWorkspaceSymbol) -> [String: Any] {
        var object: [String: Any] = [
            "name": symbol.name,
            "kind": symbol.kind,
            "location": locationObject(symbol.location)
        ]
        if let containerName = symbol.containerName {
            object["containerName"] = containerName
        }
        return object
    }

    private static func selectionRangeObject(_ range: LSPSelectionRange) -> [String: Any] {
        var object: [String: Any] = [
            "range": rangeObject(range.range)
        ]
        if let parent = range.parent {
            object["parent"] = selectionRangeObject(parent)
        }
        return object
    }

    private static func callHierarchyItemObject(_ item: LSPCallHierarchyItem) -> [String: Any] {
        var object: [String: Any] = [
            "name": item.name,
            "kind": item.kind,
            "uri": item.uri,
            "range": rangeObject(item.range),
            "selectionRange": rangeObject(item.selectionRange)
        ]
        if let tags = item.tags {
            object["tags"] = tags
        }
        if let detail = item.detail {
            object["detail"] = detail
        }
        if let data = item.data {
            object["data"] = anyValueObject(data)
        }
        return object
    }

    private static func callHierarchyIncomingObject(_ call: LSPCallHierarchyIncomingCall) -> [String: Any] {
        [
            "from": callHierarchyItemObject(call.from),
            "fromRanges": call.fromRanges.map(rangeObject)
        ]
    }

    private static func callHierarchyOutgoingObject(_ call: LSPCallHierarchyOutgoingCall) -> [String: Any] {
        [
            "to": callHierarchyItemObject(call.to),
            "fromRanges": call.fromRanges.map(rangeObject)
        ]
    }

    private static func anyValueObject(_ value: LSPAnyValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        case .array(let values):
            return values.map(anyValueObject)
        case .object(let object):
            return object.mapValues(anyValueObject)
        }
    }

    private static func rangeObject(_ range: LSPRange) -> [String: Any] {
        [
            "start": positionObject(range.start),
            "end": positionObject(range.end)
        ]
    }

    private static func positionObject(_ position: LSPPosition) -> [String: Any] {
        [
            "line": position.line,
            "character": position.character
        ]
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
