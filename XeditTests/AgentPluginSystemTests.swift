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
        for name in ["project-overview", "issue-panel", "tetris", "arcade", "session-vitality", "favorites"] {
            let packageURL = name == "arcade"
                ? arcadeRuntimePackage
                : repositoryRoot.appendingPathComponent("PluginExamples/\(name)")
            let package = try AgentPluginPackageLoader.load(
                packageURL: packageURL,
                source: .installed,
                // 收藏夹与会话体检要求的宿主版本比其它样例新
                currentWillDeepVersion: "1.300.0-rc1"
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
            currentWillDeepVersion: "1.300.0-rc1"
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
            currentWillDeepVersion: "1.300.0-rc1"
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
    func bundledPluginsSkipThePerCommandConfirmation() {
        // 随 App 签名发行的第一方插件不再逐条弹确认：收藏夹这种默认入口
        // 每翻一次页面都要点「执行」根本没法用。其它来源仍然每次都要点头。
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .bundled) == false)
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .installed))
        #expect(AgentPluginCommandExecutor.requiresExecutionConfirmation(source: .codexCache))
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
