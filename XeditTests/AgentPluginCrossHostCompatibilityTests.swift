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

    /// `networkDomains` 是 `net.fetch` 唯一的门，所以它**不**走「认不出就降级」
    /// 那条路：写法不合共享 schema 的 pattern 就拒装。装得上却永远匹配不中，
    /// 插件作者只会看到一个解释不了的 networkHostNotDeclared。
    @Test func malformedNetworkDomainsAreRefusedAtLoad() throws {
        for bad in ["https://example.com", "example.com:443", "example.com/path", "*", "-bad.example.com"] {
            let root = try makePackage(
                permissions: ["network.access"],
                hostAction: "session.open",
                menuLocation: "commandPalette",
                networkDomains: [bad]
            )
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(throws: AgentPluginPackageError.self, "\(bad) should be refused") {
                _ = try AgentPluginPackageLoader.load(
                    packageURL: root,
                    source: .installed,
                    currentWillDeepVersion: "1.342.0"
                )
            }
        }
    }

    @Test func wellFormedNetworkDomainsLoad() throws {
        let root = try makePackage(
            permissions: ["network.access"],
            hostAction: "session.open",
            menuLocation: "commandPalette",
            networkDomains: ["some.im", "*.example.com", "api-1.example.co.uk"]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.342.0"
        )
        #expect(try #require(package.manifest).networkDomains.count == 3)
    }

    /// 这份判定与共享 schema 的 `pattern` 必须一致：两端各写一份实现，
    /// 谁偷偷放宽都会让「同一个包在另一端装不上」重演。
    @Test func theDomainRuleMatchesTheSharedSchemaPattern() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-schema/willdeep-plugin.schema.json")
        let data = try Data(contentsOf: schemaURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let domains = try #require(properties["networkDomains"] as? [String: Any])
        let items = try #require(domains["items"] as? [String: Any])
        let pattern = try #require(items["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        for candidate in [
            "some.im", "*.example.com", "api-1.example.co.uk",
            "https://example.com", "example.com:443", "*", "-bad.example.com", "example",
        ] {
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            let schemaAccepts = regex.firstMatch(in: candidate, range: range) != nil
            #expect(
                AgentPluginPackageLoader.isValidNetworkDomain(candidate) == schemaAccepts,
                "host and schema disagree about \(candidate)"
            )
        }
    }

    /// 装机产物与版本库内部状态不进 digest，**任意层级、任意类型**。
    ///
    /// git worktree 的 `.git` 是普通文件；只按目录跳的话，它进 digest 而安装时
    /// 的剪枝按名字把它剪掉，同一个包于是有两个指纹，安装恒报 proposalChanged。
    /// willdeep-rs 先踩到这个坑（那边整个包装不上）。
    @Test func buildArtifactsAndGitStateNeverReachTheDigest() throws {
        let root = try makePackage(
            permissions: [],
            hostAction: "session.open",
            menuLocation: "commandPalette"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.342.0"
        ).digest

        // 嵌套的 worktree gitfile（是文件，不是目录）、顶层 .git 目录、
        // 前端依赖目录——三种此前会改变指纹的东西。
        let worktree = root.appendingPathComponent(".claude/worktrees/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere/.git/worktrees/demo\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        let modules = root.appendingPathComponent("ui/node_modules/left-pad", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("module.exports = 1\n".utf8).write(to: modules.appendingPathComponent("index.js"))

        let after = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.342.0"
        ).digest
        #expect(before == after)
    }

    /// 装得上，而且装机产物不进共享安装目录。
    ///
    /// 这是上面那条 digest 规则的另一半，只看指纹抓不到：剪枝要真的把这些东西
    /// 从落盘的那一份里去掉（否则装机产物会进共用安装目录），而且剪完之后算出的
    /// 指纹必须仍与装之前相同——两侧一旦对某一类路径看法不同，`install` 就会抛
    /// proposalChanged。所以这条测试必须真的走一遍安装，并同时断言两件事。
    @Test func installingAPackageThatCarriesBuildArtifactsSucceedsAndLeavesThemOut() async throws {
        let source = try makePackage(
            permissions: [],
            hostAction: "session.open",
            menuLocation: "commandPalette"
        )
        let installedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-crosshost-install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: installedRoot)
        }
        let worktree = source.appendingPathComponent(".claude/worktrees/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere/.git/worktrees/demo\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))
        let modules = source.appendingPathComponent("ui/node_modules/left-pad", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("module.exports = 1\n".utf8).write(to: modules.appendingPathComponent("index.js"))

        let proposal = try await AgentPluginInstaller.stage(
            source: .local(source),
            currentWillDeepVersion: "1.342.0"
        )
        let package = try AgentPluginInstaller.install(
            proposal: proposal,
            installedRoot: installedRoot,
            currentWillDeepVersion: "1.342.0"
        )
        let installed = package.packageURL
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: installed.appendingPathComponent("ui/index.html").path))
        #expect(!manager.fileExists(atPath: installed.appendingPathComponent("ui/node_modules").path))
        #expect(!manager.fileExists(atPath: installed.appendingPathComponent(".claude/worktrees/demo/.git").path))
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
        menuLocation: String,
        networkDomains: [String] = []
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-crosshost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(["name": "com.example.crosshost", "version": "1.0.0"],
                  to: root.appendingPathComponent(".codex-plugin/plugin.json"))
        try write([
            "schemaVersion": 1,
            "permissions": permissions,
            "networkDomains": networkDomains,
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
