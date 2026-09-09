import Foundation
import Testing
@testable import WillDeep

@Suite("Workshop Run bundled distribution")
struct WorkshopRunBundledPluginTests {
    private func bundledPackage() throws -> AgentPluginPackage {
        let resources = try #require(Bundle.main.resourceURL)
        let root = resources.appendingPathComponent("BundledPlugins/workshop-run")
        return try AgentPluginPackageLoader.load(
            packageURL: root,
            source: .bundled,
            currentWillDeepVersion: "1.357.0-rc1"
        )
    }

    @Test("Built application contains a loadable offline game")
    func applicationContainsPlayableRuntime() throws {
        let package = try bundledPackage()
        #expect(package.pluginID == "willdeep-workshop-run")
        let manifest = try #require(package.manifest)
        #expect(manifest.permissions.isEmpty)
        #expect(manifest.dependencies.mcpServers.isEmpty)
        #expect(manifest.dependencies.skills.isEmpty)
        let page = try #require(manifest.contributes.pages.first)
        #expect(page.entryPath == "ui/dist/client/index.html")
        let resources = try #require(Bundle.main.resourceURL)
        let root = resources.appendingPathComponent("BundledPlugins/workshop-run")
        let runtime = root.appendingPathComponent("ui/dist/client")
        for name in ["hero", "runner", "guard", "rack", "prank", "title"] {
            let data = try Data(contentsOf: runtime.appendingPathComponent("assets/\(name).png"))
            #expect(!data.isEmpty)
            #expect(data.count < 8 * 1024 * 1024)
        }
        let assets = try FileManager.default.contentsOfDirectory(atPath: runtime.appendingPathComponent("assets").path)
        #expect(assets.contains { $0.hasSuffix(".js") })
        #expect(assets.contains { $0.hasSuffix(".css") })
        for excluded in ["ui/src", "ui/node_modules", "ui/dist/server", "ui/dist/.openai", "ui/evidence", "scripts"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(excluded).path))
        }
    }

    @Test("Bundled game is available without installation approval")
    func enabledByDefaultWithoutForcedPin() throws {
        let package = try bundledPackage()
        let snapshot = AgentPluginRegistry.makeSnapshot(packages: [package], issues: [], state: .empty)
        let record = try #require(snapshot.records.first)
        #expect(record.isApproved)
        #expect(record.isEnabled)
        let destination = try #require(snapshot.activeDestinations.first)
        #expect(destination.qualifiedID == "willdeep-workshop-run:game")
        #expect(!destination.defaultPinned)
    }

    @Test("Explicit user disable overrides the bundled default")
    func userCanDisableBundledGame() throws {
        let package = try bundledPackage()
        var state = AgentPluginRegistryState.empty
        state.disabledPluginIDs = [package.pluginID]
        let snapshot = AgentPluginRegistry.makeSnapshot(packages: [package], issues: [], state: state)
        let record = try #require(snapshot.records.first)
        #expect(record.isApproved)
        #expect(!record.isEnabled)
        #expect(snapshot.activeDestinations.isEmpty)
    }
}
