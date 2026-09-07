//
//  AgentPluginCrossHostCompatibilityTests.swift
//  WillDeepTests
//
//  插件包由 macOS 版与 willdeep-rs 共享，两端的词汇表却各自校验。一侧先加
//  一项，另一侧原本会把整个包判非法——实测 rs 就因此装不上待办、短剧工坊和
//  历史回溯三个自带插件。这里锁住新的约定：认不出就记下来并降级，绝不拒装。
//

import Foundation
import Testing
@testable import WillDeep

@Suite struct AgentPluginCrossHostCompatibilityTests {
    /// 与 `docs/plugin-schema/willdeep-plugin.schema.json` 同一份名单。
    /// 这里少一项，就意味着另一端装得上的插件在 macOS 版装不上。
    private static let schemaPermissions = [
        "conversation.read", "conversation.write", "workspace.read", "workspace.write",
        "process.execute", "network.access", "credentials.use", "ai.chat", "ai.image",
        "providers.read", "skills.read", "clipboard.write", "notifications",
    ]

    @Test func theHostKnowsEveryPermissionInTheSharedSchema() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-schema/willdeep-plugin.schema.json")
        let data = try Data(contentsOf: schemaURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let permissions = try #require(properties["permissions"] as? [String: Any])
        let items = try #require(permissions["items"] as? [String: Any])
        let declared = try #require(items["enum"] as? [String])
        #expect(Set(declared) == Set(Self.schemaPermissions))
        for raw in declared {
            #expect(
                AgentPluginPackageLoader.allowedPermissions.contains(AgentPluginPermission(rawValue: raw)),
                "schema declares \(raw) but the host does not allow it"
            )
        }
    }

    @Test func aPackageBuiltForTheOtherHostStillInstallsAndSaysWhatIsMissing() throws {
        let root = try makePackage(
            permissions: ["workspace.read", "telepathy.read"],
            hostAction: "editor.splitPane",
            menuLocation: "editor.gutter"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.342.0"
        )
        let manifest = try #require(package.manifest)
        #expect(manifest.permissions.contains(AgentPluginPermission(rawValue: "telepathy.read")))
        #expect(AgentPluginPackageLoader.unsupportedItems(in: manifest) == [
            "hostAction:editor.splitPane",
            "menu:editor.gutter",
            "permission:telepathy.read",
        ])
        // 认不出的权限授不出任何东西：宿主的门问的都是已知常量。
        #expect(!manifest.permissions.contains(.processExecute))
        #expect(!manifest.permissions.contains(.workspaceWrite))
    }

    @Test func aPackageUsingOnlyKnownVocabularyReportsNothingUnsupported() throws {
        let root = try makePackage(
            permissions: ["conversation.read"],
            hostAction: "session.open",
            menuLocation: "chat.selection"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.342.0"
        )
        let manifest = try #require(package.manifest)
        #expect(AgentPluginPackageLoader.unsupportedItems(in: manifest).isEmpty)
    }

    @Test func hostActionsStillNeedToBeWritten() throws {
        let root = try makePackage(
            permissions: [],
            hostAction: "",
            menuLocation: "commandPalette"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AgentPluginPackageError.self) {
            _ = try AgentPluginPackageLoader.load(
                packageURL: root,
                source: .installed,
                currentWillDeepVersion: "1.342.0"
            )
        }
    }

    private func makePackage(
        permissions: [String],
        hostAction: String,
        menuLocation: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-crosshost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(["name": "com.example.crosshost", "version": "1.0.0"],
                  to: root.appendingPathComponent(".codex-plugin/plugin.json"))
        try write([
            "schemaVersion": 1,
            "permissions": permissions,
            "dependencies": ["mcpServers": [], "skills": []],
            "contributes": [
                "destinations": [[
                    "id": "main", "titleKey": "destination.main", "mainPage": "main.page",
                ]],
                "sidebars": [],
                "pages": [["id": "main.page", "runtime": "localWeb", "entryPath": "ui/index.html"]],
                "commands": [[
                    "id": "cmd.host",
                    "titleKey": "command.host",
                    "handler": ["type": "host", "action": hostAction],
                ]],
                "menus": [menuLocation: ["cmd.host"]],
                "settings": [],
            ],
        ], to: root.appendingPathComponent(".willdeep-plugin/plugin.json"))
        try write([
            "destination.main": "Main",
            "command.host": "Host command",
        ], to: root.appendingPathComponent(".willdeep-plugin/locales/en.json"))
        let page = root.appendingPathComponent("ui/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<!doctype html><title>t</title>".utf8).write(to: page)
        return root
    }

    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
