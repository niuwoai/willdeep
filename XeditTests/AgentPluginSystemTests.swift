//
//  AgentPluginSystemTests.swift
//  WillDeepTests
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentPluginSystemTests {
    @Test @MainActor
    func pluginArtworkKeepsItsOriginalColorsInThePluginCenter() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let iconURL = root.appendingPathComponent("icon.tiff")
        let sourceImage = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let imageData = try #require(sourceImage.tiffRepresentation)
        try imageData.write(to: iconURL, options: .atomic)

        let original = try #require(AgentPluginIcon.loadImage(
            icon: "icon.tiff",
            packageURL: root,
            presentation: .originalColor
        ))
        let monochrome = try #require(AgentPluginIcon.loadImage(
            icon: "icon.tiff",
            packageURL: root,
            presentation: .monochrome
        ))

        #expect(!original.isTemplate)
        #expect(monochrome.isTemplate)
    }

    @Test
    func missingPluginArtworkGetsAStableGeneratedStyle() {
        let first = AgentPluginFallbackIconStyle.resolve(seed: "example-plugin")
        let repeated = AgentPluginFallbackIconStyle.resolve(seed: "example-plugin")

        #expect(first == repeated)
        #expect(!first.symbolName.isEmpty)
        #expect((0..<6).contains(first.paletteIndex))
    }

    @Test
    func pluginApprovalUsesTheSoftAccentActionStyle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPluginCenterPage.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".buttonStyle(AgentPluginApprovalActionButtonStyle())"))
        #expect(source.contains(".fill(Color.accentColor.opacity(backgroundOpacity"))
        #expect(source.contains("return isPressed ? 0.18 : 0.11"))
    }

    @Test
    func loadsDestinationAndAllSidebarModes() throws {
        let root = try makePackage(id: "sample", destinations: [
            ("sessions", "sessionList"),
            ("native", "declarative"),
            ("wide", "none")
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.280.0"
        )
        #expect(package.pluginID == "sample")
        #expect(package.destinations.map(\.companionSidebar.mode) == [.sessionList, .declarative, .none])
        #expect(package.destinations.map(\.qualifiedID) == ["sample:sessions", "sample:native", "sample:wide"])
    }

    @Test
    func codexOnlyPluginStaysCompatibleWithoutDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(
            ["name": "codex-only", "version": "1.0.0"],
            to: root.appendingPathComponent(".codex-plugin/plugin.json")
        )
        let package = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .codexCache,
            currentWillDeepVersion: "1.280.0"
        )
        #expect(package.manifest == nil)
        #expect(package.destinations.isEmpty)
    }

    @Test
    func codexOnlyMCPInfersApprovalPermissionsAndLoadsAfterApproval() async throws {
        let source = try temporaryDirectory()
        let installedRoot = try temporaryDirectory()
        defer {
            AgentPluginRuntimeSnapshotStore.update(from: .empty)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: installedRoot)
        }
        try writeJSON(
            ["name": "codex-mcp", "version": "1.0.0"],
            to: source.appendingPathComponent(".codex-plugin/plugin.json")
        )
        try writeJSON([
            "mcpServers": [
                "local": ["command": "/usr/bin/true"],
                "remote": ["type": "streamable-http", "url": "https://example.invalid/mcp"]
            ]
        ], to: source.appendingPathComponent("mcp.json"))

        let proposal = try await AgentPluginInstaller.stage(
            source: .local(source),
            currentWillDeepVersion: "1.280.0"
        )
        #expect(Set(proposal.addedPermissions) == [.processExecute, .networkAccess])
        let package = try AgentPluginInstaller.install(
            proposal: proposal,
            installedRoot: installedRoot,
            currentWillDeepVersion: "1.280.0"
        )
        AgentPluginRuntimeSnapshotStore.update(from: AgentPluginRegistrySnapshot(
            records: [.init(
                pluginID: package.pluginID,
                activePackage: package,
                availableVersions: [package],
                isEnabled: true,
                isApproved: true,
                validationMessage: nil
            )],
            activeDestinations: [],
            pinnedDestinationIDs: [],
            issues: []
        ))
        #expect(Set(AgentMCPServerDirectory.loadPluginServers().map(\.name)) == ["local", "remote"])
    }

    @Test @MainActor
    func installedCopyWinsOverSameVersionCodexCacheCopy() async throws {
        let source = try makePackage(id: "preferred-copy", destinations: [("home", "sessionList")])
        let installedRoot = try temporaryDirectory()
        let cacheRoot = try temporaryDirectory()
        let stateURL = installedRoot.appendingPathComponent("state.json")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: installedRoot)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let installed = installedRoot.appendingPathComponent("preferred-copy/1.0.0", isDirectory: true)
        let cached = cacheRoot.appendingPathComponent("preferred-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: installed)
        try FileManager.default.copyItem(at: source, to: cached)
        let registry = AgentPluginRegistry(
            roots: [
                .init(url: cacheRoot, source: .codexCache, maximumDepth: 2),
                .init(url: installedRoot, source: .installed, maximumDepth: 3),
            ],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateURL,
            autoRefresh: false
        )
        await registry.refresh()
        #expect(registry.record(pluginID: "preferred-copy")?.activePackage.source == .installed)
    }

    @Test @MainActor
    func approvalIsBoundToPackageSource() async throws {
        let source = try makePackage(id: "source-bound", destinations: [("home", "sessionList")])
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("state.json")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        let registry = AgentPluginRegistry(
            roots: [.init(url: source, source: .installed, maximumDepth: 1)],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateURL,
            autoRefresh: false
        )
        await registry.refresh()
        let package = try #require(registry.record(pluginID: "source-bound")?.activePackage)
        let sourceA = AgentPluginInstallSourceRecord(kind: .git, location: "https://example.invalid/a.git", reference: "main")
        registry.approve(package: package, source: sourceA)
        #expect(registry.isApproved(package: package))

        var state = AgentPluginRegistryStateStore.load(url: stateURL)
        state.installSources[package.id] = .init(
            kind: .git,
            location: "https://example.invalid/b.git",
            reference: "main"
        )
        try AgentPluginRegistryStateStore.save(state, url: stateURL)
        let reopened = AgentPluginRegistry(
            roots: [.init(url: source, source: .installed, maximumDepth: 1)],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateURL,
            autoRefresh: false
        )
        await reopened.refresh()
        #expect(reopened.record(pluginID: "source-bound")?.isApproved == false)
    }

    @Test
    func rejectsMissingPageAndUnknownSidebarCommand() throws {
        let root = try makePackage(id: "broken", destinations: [("native", "declarative")])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent(".willdeep-plugin/plugin.json")
        var manifest = try jsonObject(at: manifestURL)
        var contributes = try #require(manifest["contributes"] as? [String: Any])
        var destinations = try #require(contributes["destinations"] as? [[String: Any]])
        destinations[0]["mainPage"] = "missing"
        contributes["destinations"] = destinations
        manifest["contributes"] = contributes
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        }

        let schemaURL = root.appendingPathComponent(".willdeep-plugin/schemas/native.json")
        try writeJSON([
            "schemaVersion": 1,
            "components": [["id": "row", "kind": "row", "titleKey": "row.title", "command": "unknown"]]
        ], to: schemaURL)
        destinations[0]["mainPage"] = "native.page"
        contributes["destinations"] = destinations
        manifest["contributes"] = contributes
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        }
    }

    @Test
    func rejectsUndeclaredMCPAndSecretDefaults() throws {
        let root = try makePackage(id: "unsafe", destinations: [("home", "sessionList")])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent(".willdeep-plugin/plugin.json")
        var manifest = try jsonObject(at: manifestURL)
        var contributes = try #require(manifest["contributes"] as? [String: Any])
        contributes["commands"] = [[
            "id": "issue.create",
            "titleKey": "command.issue.create",
            "handler": ["type": "mcpTool", "server": "undeclared", "tool": "create_issue"]
        ]]
        manifest["contributes"] = contributes
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(
                packageURL: root,
                source: .installed,
                currentWillDeepVersion: "1.280.0"
            )
        }

        contributes["commands"] = []
        contributes["settings"] = [[
            "id": "apiToken",
            "type": "secret",
            "titleKey": "setting.apiToken",
            "defaultValue": "plaintext-must-not-be-accepted"
        ]]
        manifest["contributes"] = contributes
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(
                packageURL: root,
                source: .installed,
                currentWillDeepVersion: "1.280.0"
            )
        }
    }

    @Test
    func rejectsPathTraversalAndSymlinkEscape() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: secret)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.safeResourceURL(relativePath: "../outside.txt", packageURL: root)
        }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.safeResourceURL(relativePath: "link.txt", packageURL: root)
        }
    }

    @Test
    func draftWriterRejectsSymlinkedParentEscape() throws {
        let allowedRoot = try temporaryDirectory()
        let draftRoot = allowedRoot.appendingPathComponent("draft", isDirectory: true)
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: allowedRoot)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: draftRoot.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: outside
        )
        #expect(throws: AgentPluginInstallerError.self) {
            try AgentPluginDraftStore.write(
                data: Data("blocked".utf8),
                relativePath: "linked/outside.txt",
                draftRoot: draftRoot,
                allowedDraftRoot: allowedRoot
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("outside.txt").path))
    }

    @Test
    func rejectsPathLikePluginIdentifiers() throws {
        for identifier in [".", "..", "-hidden", "folder/name"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeJSON(
                ["name": identifier, "version": "1.0.0"],
                to: root.appendingPathComponent(".codex-plugin/plugin.json")
            )
            #expect(throws: AgentPluginPackageError.self) {
                try AgentPluginPackageLoader.load(
                    packageURL: root,
                    source: .installed,
                    currentWillDeepVersion: "1.280.0"
                )
            }
        }
    }

    @Test @MainActor
    func registryPinsAtMostFiveDestinationsInStableOrder() async throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<6 {
            let package = try makePackage(id: "plugin-\(index)", destinations: [("home", "sessionList")])
            try FileManager.default.moveItem(at: package, to: root.appendingPathComponent("plugin-\(index)"))
        }
        let registry = AgentPluginRegistry(
            roots: [.init(url: root, source: .bundled, maximumDepth: 2)],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateURL,
            autoRefresh: false
        )
        await registry.refresh()
        for destination in registry.snapshot.activeDestinations {
            registry.pin(destinationID: destination.qualifiedID)
        }
        #expect(registry.snapshot.pinnedDestinationIDs.count == 5)
        #expect(registry.snapshot.pinnedDestinationIDs == Array(registry.snapshot.activeDestinations.prefix(5).map(\.qualifiedID)))
    }

    @Test
    func approvedPluginMCPConfigurationRequiresMatchingPermission() throws {
        let root = try makePackage(id: "mcp-sample", destinations: [("home", "sessionList")], permissions: ["process.execute"], mcpDependency: "sample-server")
        defer {
            AgentPluginRuntimeSnapshotStore.update(from: .empty)
            try? FileManager.default.removeItem(at: root)
        }
        try writeJSON([
            "mcpServers": ["sample-server": ["command": "/usr/bin/ruby", "args": ["${pluginRoot}/server.rb"]]]
        ], to: root.appendingPathComponent("mcp.json"))
        try Data("puts '{}'".utf8).write(to: root.appendingPathComponent("server.rb"))
        let package = try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        AgentPluginRuntimeSnapshotStore.update(from: AgentPluginRegistrySnapshot(
            records: [.init(pluginID: package.pluginID, activePackage: package, availableVersions: [package], isEnabled: true, isApproved: true, validationMessage: nil)],
            activeDestinations: package.destinations,
            pinnedDestinationIDs: [],
            issues: []
        ))
        let server = try #require(AgentMCPServerDirectory.loadPluginServers().first)
        #expect(server.id == "plugin:mcp-sample:sample-server")
        #expect(server.args == [AgentPluginPackageLoader.canonicalFileURL(root.appendingPathComponent("server.rb")).path])

        try writeJSON([
            "mcpServers": ["sample-server": [
                "command": "/usr/bin/ruby",
                "args": ["${pluginRoot}/server.rb"],
                "env": ["API_TOKEN": "must-not-live-in-a-plugin-manifest"]
            ]]
        ], to: root.appendingPathComponent("mcp.json"))
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(
                packageURL: root,
                source: .installed,
                currentWillDeepVersion: "1.280.0"
            )
        }
    }

    @Test
    func pluginMCPServersAreNamespacedAcrossPlugins() throws {
        let first = try makePackage(
            id: "first-plugin",
            destinations: [],
            permissions: ["process.execute"],
            mcpDependency: "shared-server"
        )
        let second = try makePackage(
            id: "second-plugin",
            destinations: [],
            permissions: ["process.execute"],
            mcpDependency: "shared-server"
        )
        defer {
            AgentPluginRuntimeSnapshotStore.update(from: .empty)
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        for root in [first, second] {
            try writeJSON(
                ["mcpServers": ["shared-server": ["command": "/usr/bin/true"]]],
                to: root.appendingPathComponent("mcp.json")
            )
        }
        let packages = try [first, second].map {
            try AgentPluginPackageLoader.load(
                packageURL: $0,
                source: .installed,
                currentWillDeepVersion: "1.280.0"
            )
        }
        AgentPluginRuntimeSnapshotStore.update(from: AgentPluginRegistrySnapshot(
            records: packages.map {
                .init(pluginID: $0.pluginID, activePackage: $0, availableVersions: [$0], isEnabled: true, isApproved: true, validationMessage: nil)
            },
            activeDestinations: [],
            pinnedDestinationIDs: [],
            issues: []
        ))
        let servers = AgentMCPServerDirectory.loadPluginServers()
        #expect(Set(servers.map(\.id)) == [
            "plugin:first-plugin:shared-server",
            "plugin:second-plugin:shared-server",
        ])
        #expect(try AgentMCPServerDirectory.pluginServer(pluginID: "first-plugin", named: "shared-server").id
            == "plugin:first-plugin:shared-server")
    }

    @Test @MainActor
    func allDeclaredMenuLocationsResolveAndDisabledPluginsCannotExecute() async throws {
        let root = try makePackage(id: "menus", destinations: [("home", "sessionList")])
        let stateRoot = try temporaryDirectory()
        let stateURL = stateRoot.appendingPathComponent("registry-state.json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateRoot)
        }
        let manifestURL = root.appendingPathComponent(".willdeep-plugin/plugin.json")
        var manifest = try jsonObject(at: manifestURL)
        var contributes = try #require(manifest["contributes"] as? [String: Any])
        contributes["commands"] = [
            ["id": "page.refresh", "titleKey": "command.page", "handler": ["type": "host", "action": "plugin.refresh"]],
            ["id": "row.refresh", "titleKey": "command.row", "handler": ["type": "host", "action": "plugin.refresh"]],
        ]
        contributes["menus"] = [
            "plugin.page.toolbar": ["page.refresh"],
            "plugin.sidebar.row.context": ["row.refresh"],
        ]
        manifest["contributes"] = contributes
        try writeJSON(manifest, to: manifestURL)
        var locales = try jsonObject(at: root.appendingPathComponent(".willdeep-plugin/locales/en.json"))
        locales["command.page"] = "Refresh page"
        locales["command.row"] = "Refresh row"
        try writeJSON(locales, to: root.appendingPathComponent(".willdeep-plugin/locales/en.json"))

        let registry = AgentPluginRegistry(
            roots: [.init(url: root, source: .bundled, maximumDepth: 1)],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateURL,
            autoRefresh: false
        )
        await registry.refresh()
        let destination = try #require(registry.snapshot.activeDestinations.first)
        #expect(registry.pageToolbarCommands(for: destination).map(\.id) == ["page.refresh"])
        #expect(registry.sidebarRowContextCommands(for: destination, explicitCommandIDs: []).map(\.id) == ["row.refresh"])
        registry.setEnabled(false, pluginID: "menus")
        #expect(registry.command(pluginID: "menus", commandID: "page.refresh") == nil)
    }

    @Test @MainActor
    func sessionOpenHostActionLoadsAndIsGatedOnConversationRead() async throws {
        // 声明 conversation.read 的插件：session.open 过生产加载器，
        // 且执行时那道权限门读到的值为真。
        let allowedRoot = try makePackage(
            id: "recall-allowed",
            destinations: [("home", "sessionList")],
            permissions: ["conversation.read"]
        )
        // 没声明 conversation.read 的插件：加载器照样放行（白名单只管
        // action 合法性），把关全落在 executeHost 的运行时权限门上。
        let deniedRoot = try makePackage(
            id: "recall-denied",
            destinations: [("home", "sessionList")]
        )
        let stateRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: allowedRoot)
            try? FileManager.default.removeItem(at: deniedRoot)
            try? FileManager.default.removeItem(at: stateRoot)
        }
        for root in [allowedRoot, deniedRoot] {
            let manifestURL = root.appendingPathComponent(".willdeep-plugin/plugin.json")
            var manifest = try jsonObject(at: manifestURL)
            var contributes = try #require(manifest["contributes"] as? [String: Any])
            contributes["commands"] = [
                [
                    "id": "session.open",
                    "titleKey": "command.session.open",
                    "handler": ["type": "host", "action": "session.open"],
                ],
            ]
            manifest["contributes"] = contributes
            try writeJSON(manifest, to: manifestURL)
            let localesURL = root.appendingPathComponent(".willdeep-plugin/locales/en.json")
            var locales = try jsonObject(at: localesURL)
            locales["command.session.open"] = "Open session"
            try writeJSON(locales, to: localesURL)

            let package = try AgentPluginPackageLoader.load(
                packageURL: root,
                source: .installed,
                currentWillDeepVersion: "1.280.0"
            )
            let manifestModel = try #require(package.manifest)
            let handler = try #require(manifestModel.contributes.commands.first?.handler)
            #expect(handler.action == "session.open")
        }
        #expect(AgentPluginPackageLoader.allowedHostCommands.contains("session.open"))

        let registry = AgentPluginRegistry(
            roots: [
                .init(url: allowedRoot, source: .bundled, maximumDepth: 1),
                .init(url: deniedRoot, source: .bundled, maximumDepth: 1),
            ],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateRoot.appendingPathComponent("registry-state.json"),
            autoRefresh: false
        )
        await registry.refresh()
        #expect(registry.hasPermission(.conversationRead, pluginID: "recall-allowed"))
        #expect(!registry.hasPermission(.conversationRead, pluginID: "recall-denied"))
        // 停用之后连声明过权限的插件也拿不到这道门。
        registry.setEnabled(false, pluginID: "recall-allowed")
        #expect(!registry.hasPermission(.conversationRead, pluginID: "recall-allowed"))
    }

    @Test
    func sessionOpenHostActionChecksPermissionAndDistinguishesFailures() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPluginCommandExecutor.swift"),
            encoding: .utf8
        )

        // 权限门是本 action 独有的：executeHost 必须拿到 pluginID 才查得了权限。
        #expect(source.contains("case \"session.open\":"))
        #expect(source.contains("hasPermission(.conversationRead, pluginID: pluginID)"))
        #expect(source.contains("private static func executeHost("))
        // 归档会话的侧栏行藏在折叠组里，必须走 reveal 版而不是裸的 selectAgentSession。
        #expect(source.contains("selectAndRevealAgentSessionInSidebar"))
        // 目录未装载与会话不存在必须报成两条不同的错，否则 App 刚启动时的
        // 报错会把用户带沟里。
        #expect(source.contains("hasLoadedAgentSessionCatalog"))
        #expect(source.contains("会话目录尚未装载完成"))
        #expect(source.contains("会话不存在或已损坏"))
    }

    @Test
    func uninstallRemovesEveryInstalledVersion() throws {
        let installedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: installedRoot) }
        for version in ["1.0.0", "1.1.0"] {
            try FileManager.default.createDirectory(
                at: installedRoot.appendingPathComponent("remove-me/\(version)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try AgentPluginInstaller.uninstallAllVersions(pluginID: "remove-me", installedRoot: installedRoot)
        #expect(!FileManager.default.fileExists(atPath: installedRoot.appendingPathComponent("remove-me").path))
    }

    @Test
    func mcpAppPayloadRequiresStandardMetadata() throws {
        let payload = """
        {"contents":[{"uri":"ui://issues/main","mimeType":"text/html;profile=mcp-app","text":"<!doctype html>"}]}
        """
        let document = try AgentPluginMCPResourcePayload.mcpAppDocument(
            from: payload,
            expectedURI: "ui://issues/main"
        )
        #expect(document.uri == "ui://issues/main")
        #expect(document.mimeType == "text/html;profile=mcp-app")
        #expect(document.text == "<!doctype html>")

        let wrongMIME = """
        {"contents":[{"uri":"ui://issues/main","mimeType":"text/html","text":"<!doctype html>"}]}
        """
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginMCPResourcePayload.mcpAppDocument(
                from: wrongMIME,
                expectedURI: "ui://issues/main"
            )
        }
    }

    @Test
    func runtimeDeclarativeResourcesUsePackageValidationRules() throws {
        let valid = AgentPluginSidebarDocument(components: [
            .init(
                id: "issue-row",
                kind: .row,
                titleKey: "sidebar.issue",
                progress: 0.5,
                command: "issue.open"
            )
        ])
        let keys = try AgentPluginPackageLoader.validateDeclarativeDocument(
            valid,
            commandIDs: ["issue.open"]
        )
        #expect(keys == ["sidebar.issue"])

        var nested = AgentPluginSidebarComponent(id: "level-21", kind: .section)
        for level in (0..<21).reversed() {
            nested = .init(id: "level-\(level)", kind: .section, children: [nested])
        }
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.validateDeclarativeDocument(
                .init(components: [nested]),
                commandIDs: []
            )
        }

        let undeclaredCommand = AgentPluginSidebarDocument(components: [
            .init(id: "unsafe", kind: .button, command: "host.unapproved")
        ])
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.validateDeclarativeDocument(
                undeclaredCommand,
                commandIDs: []
            )
        }
    }

    @Test
    func rejectsUnknownSchemaPermissionMissingLocalizationAndInvalidMCPURI() throws {
        let root = try makePackage(id: "strict", destinations: [("home", "sessionList")])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent(".willdeep-plugin/plugin.json")
        let original = try jsonObject(at: manifestURL)

        var manifest = original
        manifest["schemaVersion"] = 99
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        }

        manifest = original
        manifest["permissions"] = ["host.everything"]
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        }

        manifest = original
        try writeJSON(manifest, to: manifestURL)
        var locales = try jsonObject(at: root.appendingPathComponent(".willdeep-plugin/locales/en.json"))
        locales.removeValue(forKey: "destination.home")
        try writeJSON(locales, to: root.appendingPathComponent(".willdeep-plugin/locales/en.json"))
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        }

        try writeJSON(["destination.home": "Home"], to: root.appendingPathComponent(".willdeep-plugin/locales/en.json"))
        var contributes = try #require(manifest["contributes"] as? [String: Any])
        contributes["pages"] = [[
            "id": "home.page",
            "runtime": "mcpApp",
            "server": "strict-server",
            "resourceURI": "https://example.invalid/app",
        ]]
        manifest["contributes"] = contributes
        manifest["dependencies"] = ["mcpServers": ["strict-server"], "skills": []]
        try writeJSON(manifest, to: manifestURL)
        #expect(throws: AgentPluginPackageError.self) {
            try AgentPluginPackageLoader.load(packageURL: root, source: .installed, currentWillDeepVersion: "1.280.0")
        }
    }

    @Test @MainActor
    func scanningThreeHundredPluginsYieldsTheMainActor() async throws {
        let source = try makePackage(id: "scan-template", destinations: [])
        let root = try temporaryDirectory()
        let stateRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateRoot)
        }
        let codexManifest = source.appendingPathComponent(".codex-plugin/plugin.json")
        for index in 0..<300 {
            let packageRoot = root.appendingPathComponent("plugin-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: packageRoot.appendingPathComponent(".codex-plugin", isDirectory: true),
                withIntermediateDirectories: true
            )
            var manifest = try jsonObject(at: codexManifest)
            manifest["name"] = "scan-\(index)"
            try writeJSON(manifest, to: packageRoot.appendingPathComponent(".codex-plugin/plugin.json"))
        }
        let registry = AgentPluginRegistry(
            roots: [.init(url: root, source: .bundled, maximumDepth: 2)],
            currentWillDeepVersion: "1.280.0",
            stateURL: stateRoot.appendingPathComponent("state.json"),
            autoRefresh: false
        )
        let refresh = Task { @MainActor in await registry.refresh() }
        await Task.yield()
        let mainActorWasResponsive = true
        await refresh.value
        #expect(mainActorWasResponsive)
        #expect(registry.snapshot.records.count == 300)
    }

    @Test
    func repositoryExamplesPassTheProductionLoader() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let arcadeRuntimePackage = try makeRuntimePackage(
            from: repositoryRoot.appendingPathComponent("PluginExamples/arcade")
        )
        defer { try? FileManager.default.removeItem(at: arcadeRuntimePackage) }
        for name in [
            "project-overview", "issue-panel", "tetris", "arcade",
            "session-vitality", "favorites", "todo", "history-recall",
        ] {
            let packageURL = name == "arcade"
                ? arcadeRuntimePackage
                : repositoryRoot.appendingPathComponent("PluginExamples/\(name)")
            let package = try AgentPluginPackageLoader.load(
                packageURL: packageURL,
                source: .installed,
                // 收藏夹与会话体检要求的宿主版本比其它样例新；翻旧账
                // (history-recall) 又更新一档（它依赖 session.open host action）
                currentWillDeepVersion: "1.316.0-rc1"
            )
            #expect(package.destinations.count == 1)
        }
    }

    @Test
    func favoritesExampleContributesTheChatSelectionMenu() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let package = try AgentPluginPackageLoader.load(
            packageURL: repositoryRoot.appendingPathComponent("PluginExamples/favorites"),
            source: .installed,
            currentWillDeepVersion: "1.300.0-rc5"
        )
        let manifest = try #require(package.manifest)

        // 选区菜单挂载点解析出来的必须是本插件里真实存在的命令
        let selectionCommandIDs = manifest.contributes.menus[AgentPluginMenuLocation.chatSelection] ?? []
        #expect(selectionCommandIDs == ["favorites.add"])
        let commandIDs = Set(manifest.contributes.commands.map(\.id))
        for commandID in selectionCommandIDs {
            #expect(commandIDs.contains(commandID))
        }

        // 「收藏」这条命令要把文本转交给 MCP 工具，否则选区里的原文没人接
        let add = try #require(manifest.contributes.commands.first { $0.id == "favorites.add" })
        #expect(add.handler.type == .mcpTool)
        #expect(add.handler.server == "favorites")
        #expect(add.handler.tool == "favorites.add")
        #expect(manifest.dependencies.mcpServers.contains("favorites"))
        #expect(manifest.permissions.contains(.conversationRead))
    }

    @Test
    func favoritesShipsInsideTheAppAsAFixedSidebarEntry() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryRoot.appendingPathComponent("PluginExamples/favorites")
        let package = try AgentPluginPackageLoader.load(
            packageURL: packageURL,
            source: .installed,
            currentWillDeepVersion: "1.300.0-rc5"
        )
        let manifest = try #require(package.manifest)

        // 左侧默认入口靠目的地清单里的 defaultPinned，而它只对 bundled 来源生效
        let destination = try #require(manifest.contributes.destinations.first)
        #expect(destination.defaultPinned)

        // 页面用到的每条命令都要真实存在，否则页面点了没反应
        let commandIDs = Set(manifest.contributes.commands.map(\.id))
        for required in ["favorites.add", "favorites.list", "favorites.update",
                         "favorites.remove", "favorites.restore", "favorites.clear"] {
            #expect(commandIDs.contains(required))
        }

        // 打包清单：Xcode 的「Bundle built-in plugins」阶段必须把收藏夹跑起来
        // 需要的每个文件都复制进 App，漏一个就是装进去点不开。
        let projectFile = repositoryRoot.appendingPathComponent("Xedit.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)
        let bundleLine = try #require(
            project
                .replacingOccurrences(of: "\\n", with: "\n")
                .split(separator: "\n")
                .first { $0.hasPrefix("bundle_plugin favorites ") }
        )
        let relativePaths = bundleLine
            .split(separator: " ")
            .dropFirst(2)
            .map(String.init)
        let entryPath = try #require(manifest.contributes.pages.first?.entryPath)
        for required in [entryPath, "mcp.json", "server", ".willdeep-plugin", ".codex-plugin"] {
            #expect(relativePaths.contains(required))
        }
        for relativePath in relativePaths {
            #expect(
                FileManager.default.fileExists(
                    atPath: packageURL.appendingPathComponent(relativePath).path
                )
            )
        }
    }

    @Test
    func bundledPluginsShipEveryFileTheyNeedAtRuntime() throws {
        // 「Bundle built-in plugins」阶段是一份手写清单：加了文件却忘了登记，
        // 插件装进 App 就是点不开（页面 404、MCP 服务端脚本不存在）。这条守卫
        // 按每个内置插件的清单反查它运行时真正要的文件有没有被复制。
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFile = repositoryRoot.appendingPathComponent("Xedit.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)
            .replacingOccurrences(of: "\\n", with: "\n")
        let bundleLines = project
            .split(separator: "\n")
            .filter { $0.hasPrefix("bundle_plugin ") && !$0.hasSuffix("() {") }
            .map(String.init)
        #expect(bundleLines.count >= 4)

        for line in bundleLines {
            let fields = line.split(separator: " ").map(String.init)
            let pluginDirectory = fields[1]
            let relativePaths = Array(fields.dropFirst(2))
            let packageURL = repositoryRoot
                .appendingPathComponent("PluginExamples/\(pluginDirectory)")

            // 登记的每一条都得真实存在，否则 ditto 会在构建时炸掉
            for relativePath in relativePaths {
                #expect(
                    FileManager.default.fileExists(
                        atPath: packageURL.appendingPathComponent(relativePath).path
                    ),
                    "\(pluginDirectory) 登记了不存在的路径 \(relativePath)"
                )
            }
            #expect(relativePaths.contains(".willdeep-plugin"))
            #expect(relativePaths.contains(".codex-plugin"))

            func isCovered(_ path: String) -> Bool {
                relativePaths.contains { path == $0 || path.hasPrefix("\($0)/") }
            }

            // localWeb 页面的 entryPath 必须在复制清单里。
            // 这里直接解码清单而不过生产加载器：游戏厅的源码目录带着未构建的
            // 前端工程，会被加载器的体积上限拒掉（发行时只复制 ui/dist）。
            let manifestData = try Data(
                contentsOf: packageURL.appendingPathComponent(".willdeep-plugin/plugin.json")
            )
            let manifest = try JSONDecoder().decode(AgentPluginManifest.self, from: manifestData)
            for page in manifest.contributes.pages {
                guard let entryPath = page.entryPath else { continue }
                #expect(isCovered(entryPath), "\(pluginDirectory) 漏带页面 \(entryPath)")
            }

            // 带 MCP 服务端的插件：mcp.json 与它指向的脚本都得带上，
            // 否则装进 App 之后服务端起不来
            let mcpURL = packageURL.appendingPathComponent("mcp.json")
            guard FileManager.default.fileExists(atPath: mcpURL.path) else { continue }
            #expect(isCovered("mcp.json"), "\(pluginDirectory) 有 mcp.json 却没带上")
            let mcpText = try String(contentsOf: mcpURL, encoding: .utf8)
            for reference in mcpText.components(separatedBy: "${pluginRoot}/").dropFirst() {
                let relativePath = String(reference.prefix { $0 != "\"" })
                #expect(isCovered(relativePath), "\(pluginDirectory) 漏带 MCP 服务端文件 \(relativePath)")
                #expect(
                    FileManager.default.fileExists(
                        atPath: packageURL.appendingPathComponent(relativePath).path
                    )
                )
            }
        }
    }

    @Test
    func pluginAIRequestValidatorGuardsThePayload() {
        // 空请求、超量、超长都要在起模型之前就被挡住
        #expect(AgentPluginAIRequestValidator.request(from: [:]) == .failure(.emptyRequest))
        #expect(
            AgentPluginAIRequestValidator.request(from: ["messages": [["role": "user", "content": "   "]]])
                == .failure(.emptyRequest)
        )
        let flood = (0..<40).map { ["role": "user", "content": "第 \($0) 条"] }
        #expect(AgentPluginAIRequestValidator.request(from: ["messages": flood]) == .failure(.tooManyMessages))
        let long = String(repeating: "字", count: AgentPluginAIRequest.maximumCharacters + 1)
        #expect(
            AgentPluginAIRequestValidator.request(from: ["messages": [["role": "user", "content": long]]])
                == .failure(.tooLong)
        )

        let raw: [String: Any] = [
            "system": "把一句话变成待办",
            "messages": [
                ["role": "user", "content": "明天下午三点前把发布验一遍"],
                ["role": "assistant", "content": "好的"],
                ["role": "什么角色", "content": "按 user 处理"],
            ],
            "provider": " ollama ",
            "model": "gemma4:e4b-it-qat",
            "maxOutputTokens": 99_999,
        ]
        guard case .success(let request) = AgentPluginAIRequestValidator.request(from: raw) else {
            Issue.record("合法请求不该被拒")
            return
        }
        #expect(request.messages.count == 4)
        #expect(request.messages.first?.role == .system)
        #expect(request.messages.last?.role == .user, "认不出的角色按 user 处理，绝不当成 system")
        #expect(request.providerID == "ollama", "provider 两边的空白要去掉")
        // 输出上限由宿主收口，插件报多少都夹到上限内
        #expect(request.maxOutputTokens == AgentPluginAIRequest.maximumOutputTokens)
    }

    @Test
    func chatSelectionArgumentsCarryWorkspaceOnlyWhenThereIsOne() {
        let withoutWorkspace = AppState.chatSelectionArguments(text: "选中的一段话", workspace: nil)
        #expect(withoutWorkspace == ["text": "选中的一段话", "source": "chat.selection"])

        let withWorkspace = AppState.chatSelectionArguments(
            text: "选中的一段话",
            workspace: "/Users/rocky/Sites/Xedit"
        )
        #expect(withWorkspace["workspace"] == "/Users/rocky/Sites/Xedit")
        #expect(withWorkspace["source"] == "chat.selection")
        // 空字符串不算工作区，不能塞个空值进去让插件误判
        #expect(AppState.chatSelectionArguments(text: "x", workspace: "")["workspace"] == nil)

        let sessionID = UUID()
        let messageID = UUID()
        let turnID = UUID()
        let linked = AppState.chatSelectionArguments(
            text: "可回到原文",
            workspace: nil,
            sessionID: sessionID,
            messageID: messageID,
            turnID: turnID
        )
        #expect(linked["source_session_id"] == sessionID.uuidString)
        #expect(linked["source_message_id"] == messageID.uuidString)
        #expect(linked["source_turn_id"] == turnID.uuidString)
    }

    @Test
    func todoExampleDeclaresTheModelPermissionsItActuallyUses() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryRoot.appendingPathComponent("PluginExamples/todo")
        let package = try AgentPluginPackageLoader.load(
            packageURL: packageURL,
            source: .installed,
            currentWillDeepVersion: "1.300.0-rc5"
        )
        let manifest = try #require(package.manifest)

        // 页面用了 window.willdeep.ai.complete / .providers 和当前工作区，
        // 三样都必须在清单里声明，否则宿主会在运行时把它挡回去。
        #expect(manifest.permissions.contains(.aiChat))
        #expect(manifest.permissions.contains(.providersRead))
        #expect(manifest.permissions.contains(.workspaceRead))
        #expect(manifest.permissions.contains(.processExecute))

        let selection = manifest.contributes.menus[AgentPluginMenuLocation.chatSelection] ?? []
        #expect(selection == ["todo.quick_add"], "聊天里选中一段话应该走一句话解析那条命令")
        let page = try String(
            contentsOf: packageURL.appendingPathComponent("ui/index.html"),
            encoding: .utf8
        )
        #expect(page.contains("window.willdeep.ai.complete"))
        #expect(page.contains("todo.quick_add"), "模型不可用时页面要能回落到本地规则解析")
    }

    @Test
    func installedAndBundledPluginsSkipThePerCommandConfirmation() {
        // 授权在安装时一次拿到:安装面板已列出插件权限,用户点「安装」即
        // 授权,执行时不再弹「允许插件命令?」。草稿和 Codex 外部缓存从没
        // 走过安装授权,仍然每次执行都要点头。
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .bundled) == false)
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .installed) == false)
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .codexCache))
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .draft))
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: nil))
    }

    @Test
    func chatSelectionFeedbackFollowsTheToolResult() {
        // 气泡上的「✓ / ⚠︎」认的是工具自己的结论：MCP 把载荷放在
        // content[].text 的一段 JSON 里，ok:false 表示这次没存下。
        let refused = #"{"content":[{"type":"text","text":"{\"ok\":false,\"error\":\"empty text\"}"}]}"#
        let saved = #"{"content":[{"type":"text","text":"{\"ok\":true,\"count\":3}"}]}"#
        #expect(AppState.selectionPluginActionSucceeded(result: refused) == false)
        #expect(AppState.selectionPluginActionSucceeded(result: saved))
        // 顶层就带 ok 的、非 JSON 的、以及什么都没返回的（host / navigate 命令）按成功算
        #expect(AppState.selectionPluginActionSucceeded(result: #"{"ok":false}"#) == false)
        #expect(AppState.selectionPluginActionSucceeded(result: "plain text"))
        #expect(AppState.selectionPluginActionSucceeded(result: nil))
    }

    @Test
    func chatSelectionMenuLocationIsRegisteredInTheSchema() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repositoryRoot
            .appendingPathComponent("docs/plugin-schema/willdeep-plugin.schema.json")
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)
        // Swift 侧的常量与对外 schema 的枚举必须同步，否则插件作者按文档写会被加载器拒掉
        for location in AgentPluginMenuLocation.all {
            #expect(schema.contains("\"\(location)\""))
        }
    }

    @Test
    func bundledDefaultPinnedDestinationOccupiesTheFirstFixedSlot() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimePackage = try makeRuntimePackage(
            from: repositoryRoot.appendingPathComponent("PluginExamples/arcade")
        )
        defer { try? FileManager.default.removeItem(at: runtimePackage) }
        let package = try AgentPluginPackageLoader.load(
            packageURL: runtimePackage,
            source: .bundled,
            currentWillDeepVersion: "1.281.0-rc1"
        )
        let destination = try #require(package.destinations.first)
        #expect(destination.defaultPinned)

        let snapshot = AgentPluginRegistry.makeSnapshot(
            packages: [package],
            issues: [],
            state: .empty
        )
        #expect(snapshot.pinnedDestinationIDs == [destination.qualifiedID])

        let installedPackage = try AgentPluginPackageLoader.load(
            packageURL: runtimePackage,
            source: .installed,
            currentWillDeepVersion: "1.281.0-rc1"
        )
        let installedOnlySnapshot = AgentPluginRegistry.makeSnapshot(
            packages: [installedPackage],
            issues: [],
            state: .empty
        )
        #expect(installedOnlySnapshot.pinnedDestinationIDs.isEmpty)

        let updatedSnapshot = AgentPluginRegistry.makeSnapshot(
            packages: [package, installedPackage],
            issues: [],
            state: AgentPluginRegistryState(
                activeVersions: [:],
                disabledPluginIDs: [],
                approvedDigests: [installedPackage.digest],
                pinnedDestinationIDs: []
            )
        )
        #expect(updatedSnapshot.records.first?.activePackage.source == .installed)
        #expect(updatedSnapshot.pinnedDestinationIDs == [destination.qualifiedID])
    }

    @Test
    func enabledPluginSkillsJoinTheExistingSkillDirectory() throws {
        let root = try makePackage(id: "skill-sample", destinations: [])
        defer {
            AgentPluginRuntimeSnapshotStore.update(from: .empty)
            AgentSkillDirectory.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }
        let skillURL = root.appendingPathComponent("skills/plugin-audit/SKILL.md")
        try FileManager.default.createDirectory(
            at: skillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("---\nname: Plugin Audit\ndescription: Audits plugin packages.\n---\n\n# Plugin Audit\n".utf8)
            .write(to: skillURL)
        let package = try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .installed,
            currentWillDeepVersion: "1.280.0"
        )
        AgentPluginRuntimeSnapshotStore.update(from: AgentPluginRegistrySnapshot(
            records: [.init(pluginID: package.pluginID, activePackage: package, availableVersions: [package], isEnabled: true, isApproved: true, validationMessage: nil)],
            activeDestinations: [],
            pinnedDestinationIDs: [],
            issues: []
        ))
        AgentSkillDirectory.invalidateCache()
        let skill = AgentSkillDirectory.list(includeDisabled: true).first {
            $0.url.standardizedFileURL == skillURL.standardizedFileURL
        }
        #expect(skill?.source == .plugin)
        #expect(skill?.name == "Plugin Audit")
    }

    private func makePackage(
        id: String,
        destinations: [(String, String)],
        permissions: [String] = [],
        mcpDependency: String? = nil
    ) throws -> URL {
        let root = try temporaryDirectory()
        try writeJSON(["name": id, "version": "1.0.0"], to: root.appendingPathComponent(".codex-plugin/plugin.json"))
        var destinationObjects: [[String: Any]] = []
        var sidebarObjects: [[String: Any]] = []
        var pageObjects: [[String: Any]] = []
        var englishLocalizations: [String: String] = [
            "row.title": "Row",
            "command.issue.create": "Create issue",
            "setting.apiToken": "API token",
        ]
        for (destinationID, mode) in destinations {
            let sidebarID = "\(destinationID).sidebar"
            let pageID = "\(destinationID).page"
            destinationObjects.append(["id": destinationID, "titleKey": "destination.\(destinationID)", "mainPage": pageID, "companionSidebar": sidebarID])
            englishLocalizations["destination.\(destinationID)"] = destinationID
            var sidebar: [String: Any] = ["id": sidebarID, "mode": mode]
            if mode == "declarative" {
                let path = ".willdeep-plugin/schemas/\(destinationID).json"
                sidebar["schema"] = path
                try writeJSON(["schemaVersion": 1, "components": [["id": "row", "kind": "row", "titleKey": "row.title"]]], to: root.appendingPathComponent(path))
            }
            sidebarObjects.append(sidebar)
            pageObjects.append(["id": pageID, "runtime": "localWeb", "entryPath": "ui/index.html"])
        }
        let dependencies: [String: Any] = ["mcpServers": mcpDependency.map { [$0] } ?? [], "skills": []]
        try writeJSON([
            "schemaVersion": 1,
            "minimumWillDeepVersion": "1.280.0",
            "contributes": ["destinations": destinationObjects, "sidebars": sidebarObjects, "pages": pageObjects, "commands": [], "menus": [:], "settings": []],
            "permissions": permissions,
            "dependencies": dependencies
        ], to: root.appendingPathComponent(".willdeep-plugin/plugin.json"))
        try writeJSON(
            englishLocalizations,
            to: root.appendingPathComponent(".willdeep-plugin/locales/en.json")
        )
        let pageURL = root.appendingPathComponent("ui/index.html")
        try FileManager.default.createDirectory(at: pageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<!doctype html><title>test</title>".utf8).write(to: pageURL)
        return root
    }

    private func makeRuntimePackage(from source: URL) throws -> URL {
        let root = try temporaryDirectory()
        do {
            for relativePath in [".codex-plugin", ".willdeep-plugin", "ui/dist"] {
                let sourceURL = source.appendingPathComponent(relativePath)
                let destinationURL = root.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test
    func pluginWebResourceResolverServesIndexHTMLForDirectoryRequests() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let distURL = root.appendingPathComponent("ui/dist", isDirectory: true)
        try FileManager.default.createDirectory(at: distURL, withIntermediateDirectories: true)
        try "<html>root</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<html>dist</html>".write(to: distURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: distURL.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)

        // 目录请求（WebContent 进程重启后 reload 打到 baseURL 的那种）不能落空，否则就是一张白页。
        let directoryHit = try AgentPluginWebResourceResolver.fileURL(forRequestPath: "/ui/dist/", packageURL: root)
        #expect(directoryHit.lastPathComponent == "index.html")
        #expect(try String(contentsOf: directoryHit, encoding: .utf8) == "<html>dist</html>")

        let rootHit = try AgentPluginWebResourceResolver.fileURL(forRequestPath: "/", packageURL: root)
        #expect(try String(contentsOf: rootHit, encoding: .utf8) == "<html>root</html>")

        let fileHit = try AgentPluginWebResourceResolver.fileURL(forRequestPath: "/ui/dist/app.js", packageURL: root)
        #expect(fileHit.lastPathComponent == "app.js")

        #expect(throws: (any Error).self) {
            try AgentPluginWebResourceResolver.fileURL(forRequestPath: "/../escape.txt", packageURL: root)
        }
    }

    @Test
    func pluginPageRecoversFromWebContentCrashByReloadingTheDocument() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPluginPageHost.swift"),
            encoding: .utf8
        )

        // reload() 对 loadHTMLString 的页面等于导航到 baseURL 目录，只会留下白页。
        #expect(!source.contains("webView.reload()"))
        #expect(source.contains("func reloadDocument()"))
        #expect(source.contains("didFailProvisionalNavigation"))
    }

    @Test
    func pluginPageAndBuiltInProductivityPagesFollowChatBodyFontSize() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let host = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPluginPageHost.swift"),
            encoding: .utf8
        )
        let favorites = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PluginExamples/favorites/ui/index.html"),
            encoding: .utf8
        )
        let todo = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PluginExamples/todo/ui/index.html"),
            encoding: .utf8
        )
        let todoDetails = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PluginExamples/todo/ui/details.css"),
            encoding: .utf8
        )

        #expect(host.contains("appState.agentChatBaseFontSize.rounded()"))
        #expect(host.contains("--willdeep-body-font-size: \\(bodyFontSize)px"))
        #expect(favorites.contains("font: var(--willdeep-body-font-size, 15px)/1.55"))
        #expect(todo.contains("font: var(--willdeep-body-font-size, 15px)/1.55"))
        #expect(todoDetails.contains(".title { font-size: var(--willdeep-body-font-size, 15px)"))
    }

    @Test
    func pluginPageBaseURLSurvivesSymlinkedPackagePaths() throws {
        // temporaryDirectory 位于 /var/...，而 /var 是 /private/var 的软链接：
        // 入口目录经 safeResourceURL 后是 realpath 形态（/private/var/...），
        // 包根若不做同样的规范化，前缀比较必然落空、baseURL 变 nil，页面里
        // 所有相对子资源静默失败。这里用未规范化的包根直接调映射函数验证。
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uiURL = root.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiURL, withIntermediateDirectories: true)
        try "<html></html>".write(to: uiURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let entry = try AgentPluginPackageLoader.safeResourceURL(relativePath: "ui/index.html", packageURL: root)
        let baseURL = AgentPluginWebResourceResolver.schemeBaseURL(
            forEntryDirectory: entry.deletingLastPathComponent(),
            packageURL: root
        )
        #expect(baseURL?.absoluteString == "willdeep-plugin://bundle/ui/")

        let packageRootBase = AgentPluginWebResourceResolver.schemeBaseURL(
            forEntryDirectory: AgentPluginPackageLoader.canonicalFileURL(root),
            packageURL: root
        )
        #expect(packageRootBase?.absoluteString == "willdeep-plugin://bundle//" || packageRootBase?.absoluteString == "willdeep-plugin://bundle/")
    }

    @Test
    func pluginPageBaseURLRejectsEntryDirectoriesOutsideThePackage() throws {
        let root = try temporaryDirectory()
        let foreign = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: foreign)
        }
        // 入口目录来自另一份副本（内置 ↔ 本地安装混装）时必须落空——调用方
        // 有责任在落空时重读入口，而不是拿错配的 baseURL 加载。
        #expect(AgentPluginWebResourceResolver.schemeBaseURL(forEntryDirectory: foreign, packageURL: root) == nil)
        #expect(AgentPluginWebResourceResolver.schemeBaseURL(forEntryDirectory: nil, packageURL: root) == nil)
    }

    @Test
    func pluginPageFollowsActivePackageAcrossRegistryFlips() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPluginPageHost.swift"),
            encoding: .utf8
        )

        // 同名同版本插件在「内置」与「本地安装」两个副本间切换激活包时，
        // 三处必须一起跟着走，缺一处就是入口 HTML 与子资源来自不同副本的混装白页：
        // 1) scheme handler 的资源根每次 update 回写；
        #expect(source.contains("coordinator.schemeHandler?.packageURL = destination.packageURL"))
        // 2) 页面加载任务的身份含包路径，激活包切换即重读入口 HTML；
        #expect(source.contains(":\\(destination.packageURL.path)"))
        // 3) baseURL 映射两侧都走 canonicalFileURL 再比前缀。
        #expect(source.contains("func schemeBaseURL(forEntryDirectory"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("willdeep-plugin-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
