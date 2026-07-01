//
//  EditorLanguageServiceCodeActionCommandTests.swift
//  WillDeepTests
//
//  Focused tests for LSP code action commands.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceCodeActionCommandTests {
    @Test("LSP code action result decodes bare commands with arguments")
    func testLSPCodeActionResultDecodesBareCommands() throws {
        let result = try JSONDecoder().decode(LSPCodeActionResult.self, from: Data("""
        [
          {
            "title": "Organize Imports",
            "command": "gopls.organize_imports",
            "arguments": [
              "file:///tmp/main.go",
              { "only": "imports" }
            ]
          }
        ]
        """.utf8))
        let action = try #require(result.actions.first)

        #expect(action.title == "Organize Imports")
        #expect(action.edit == nil)
        #expect(action.command?.command == "gopls.organize_imports")
        #expect(action.command?.arguments == [
            .string("file:///tmp/main.go"),
            .object(["only": .string("imports")])
        ])
    }

    @Test("language service manager executes advertised code action commands")
    func testLanguageServiceManagerExecutesCodeActionCommands() async throws {
        let transport = CodeActionCommandFakeTransport()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        try await manager.executeCommand(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            language: .go,
            rootDirectory: URL(fileURLWithPath: "/tmp"),
            text: "package main\n",
            command: LSPCommand(
                title: "Organize Imports",
                command: "gopls.organize_imports",
                arguments: [.string("file:///tmp/main.go")]
            )
        )

        let methods = transport.sentPayloads.compactMap(CodeActionCommandFakeTransport.methodName)
        let executePayload = try #require(transport.sentPayloads.first {
            CodeActionCommandFakeTransport.methodName(from: $0) == "workspace/executeCommand"
        })
        let request = try #require(try JSONSerialization.jsonObject(with: executePayload) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let arguments = try #require(params["arguments"] as? [Any])

        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("workspace/executeCommand"))
        #expect(params["command"] as? String == "gopls.organize_imports")
        #expect(arguments.first as? String == "file:///tmp/main.go")
    }

    @Test("language service manager skips command execution without provider capability")
    func testLanguageServiceManagerSkipsCommandsWithoutProvider() async throws {
        let transport = CodeActionCommandFakeTransport(exposesExecuteCommand: false)
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in transport },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        await #expect(throws: LanguageServerClientError.unsupportedCapability("workspace/executeCommand gopls.organize_imports")) {
            try await manager.executeCommand(
                fileURL: URL(fileURLWithPath: "/tmp/main.go"),
                language: .go,
                rootDirectory: URL(fileURLWithPath: "/tmp"),
                text: "package main\n",
                command: LSPCommand(title: "Organize Imports", command: "gopls.organize_imports")
            )
        }

        let methods = transport.sentPayloads.compactMap(CodeActionCommandFakeTransport.methodName)
        #expect(methods.contains("initialize"))
        #expect(methods.contains("textDocument/didOpen"))
        #expect(!methods.contains("workspace/executeCommand"))
    }
}

private final class CodeActionCommandFakeTransport: LanguageServerTransport {
    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    private(set) var sentPayloads: [Data] = []
    private let exposesExecuteCommand: Bool

    init(exposesExecuteCommand: Bool = true) {
        self.exposesExecuteCommand = exposesExecuteCommand
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
            let capabilities: [String: Any] = exposesExecuteCommand ? [
                "executeCommandProvider": [
                    "commands": ["gopls.organize_imports"]
                ]
            ] : [:]
            push(responsePayload(id: id, result: ["capabilities": capabilities]))
        case "workspace/executeCommand":
            push(responsePayload(id: id, result: NSNull()))
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
