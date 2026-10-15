import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentRegistryConflictResolutionTests {
    @Test func sameVersionBranchesRequireExplicitNewVersionButCloudCanBeChosen() throws {
        for keepLocal in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "willdeep-conflict-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
            let library = AgentDefinitionLibrary(root: directory, defaults: defaults)
            let definition = AgentDefinitionV1(schema: AgentDefinitionV1.schemaID, definition_id: "user/conflict-fixture", version: "1.0.0-rc2",
                name: ["en": "Fixture"], purpose: "Read-only", base_role: "reviewer", instructions: "Local branch.",
                input_modalities: ["text"], tools: ["workspace.read"], skills: [], forked_from: nil)
            let local = try AgentPackageV1.unsigned(definition)
            var remoteDefinition = definition; remoteDefinition.instructions = "Cloud branch."
            let remote = try AgentPackageV1.unsigned(remoteDefinition)
            var installation = try library.install(local, source: .private, account: "fixture-account")
            installation.conflict = .init(definition_id: definition.definition_id, sha256: remote.sha256, version: definition.version,
                deleted: false, etag: "observed-cloud-etag", package: remote)
            try library.update(installation)
            #expect(throws: AgentAssetError.immutableVersion) { try library.install(remote, source: .private, account: "fixture-account") }
            #expect(try library.suggestedConflictVersion(installation) == "1.0.0-rc3")
            if keepLocal {
                #expect(throws: AgentAssetError.immutableVersion) { try library.resolve(installation, keepLocal: true) }
                #expect(throws: AgentAssetError.immutableVersion) { try library.resolve(installation, keepLocal: true, newVersion: "1.0.0-rc2") }
                try library.resolve(installation, keepLocal: true, newVersion: "1.0.0-rc3")
            } else {
                try library.resolve(installation, keepLocal: false)
            }
            let resolved = try #require(library.state().installations.first)
            let package = try library.package(revision: resolved.selected, account: "fixture-account")
            #expect(resolved.conflict == nil && resolved.etag == "observed-cloud-etag")
            #expect(resolved.dirty == keepLocal)
            #expect(package.definition.version == (keepLocal ? "1.0.0-rc3" : "1.0.0-rc2"))
            #expect(package.definition.instructions == (keepLocal ? definition.instructions : remoteDefinition.instructions))
            #expect(resolved.revisions.contains(local.sha256) && resolved.revisions.contains(remote.sha256))
            #expect(try library.package(revision: local.sha256, account: "fixture-account") == local)
            #expect(try library.package(revision: remote.sha256, account: "fixture-account") == remote)
            #expect(throws: AgentAssetError.conflict) { try library.resolve(installation, keepLocal: false) }
            // Explicit branch archival never weakens ordinary edit validation.
            #expect(throws: AgentAssetError.immutableVersion) { try library.install(remote, source: .private, account: "fixture-account") }
        }
    }
}
