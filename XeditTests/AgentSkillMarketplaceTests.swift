//
//  AgentSkillMarketplaceTests.swift
//  WillDeepTests
//
//  Covers static marketplace install/update/uninstall guardrails.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentSkillMarketplaceTests {
    @Test
    func marketplaceSkillInstallStatusAndUninstallRoundTrip() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let entry = try #require(AgentSkillMarketplaceStore.entries().first)
        #expect(AgentSkillMarketplaceStore.status(for: entry, root: root) == .available)

        let skillURL = try AgentSkillMarketplaceStore.install(entry, root: root)
        #expect(FileManager.default.fileExists(atPath: skillURL.path))
        #expect(AgentSkillMarketplaceStore.status(for: entry, root: root) == .installed)

        let body = try String(contentsOf: skillURL, encoding: .utf8)
        #expect(body.contains("\(AgentSkillMarketplaceStore.markerPrefix) \(entry.id)"))
        #expect(body.contains("name: \(entry.skillName)"))

        try AgentSkillMarketplaceStore.uninstall(entry, root: root)
        #expect(AgentSkillMarketplaceStore.status(for: entry, root: root) == .available)
    }

    @Test
    func marketplaceInstallDoesNotOverwriteUserSkillWithSameSlug() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let entry = try #require(AgentSkillMarketplaceStore.entries().first)
        let skillDirectory = root.appendingPathComponent(entry.slug)
        let skillURL = skillDirectory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: \(entry.skillName)
        description: User-owned skill
        ---

        # User-owned skill
        """.write(to: skillURL, atomically: true, encoding: .utf8)

        #expect(AgentSkillMarketplaceStore.status(for: entry, root: root) == .conflict)
        #expect(throws: AgentSkillMarketplaceError.self) {
            try AgentSkillMarketplaceStore.install(entry, root: root)
        }
    }

    @Test
    func marketplaceCatalogIncludesDocumentAndImageSkills() {
        let ids = Set(AgentSkillMarketplaceStore.entries().map(\.id))
        #expect(ids.contains("ppt-story-architect"))
        #expect(ids.contains("pdf-design"))
        #expect(ids.contains("image-processing"))
    }

    @Test
    func marketplaceInstallWritesSupportFiles() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let entry = try #require(AgentSkillMarketplaceStore.entries().first { $0.id == "image-processing" })
        let skillURL = try AgentSkillMarketplaceStore.install(entry, root: root)
        let scriptURL = skillURL.deletingLastPathComponent()
            .appendingPathComponent("scripts/process_image.py")

        #expect(FileManager.default.fileExists(atPath: scriptURL.path))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(script.contains("--transparent-color"))
        #expect(script.contains("--trim-transparent"))
    }

    @Test
    func marketplaceInstallStoresDeclaredCredentialsInKeychain() throws {
        let root = try temporarySkillRoot()
        let suiteName = "willdeep-skill-credentials-\(UUID().uuidString)"
        AgentCredentialStore._setTestKeychainServiceOverride(suiteName)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
        }

        let requirement = AgentSkillCredentialRequirement(
            id: "example_api_key",
            label: "Example API Key",
            detail: "Used by tests",
            environmentVariable: "EXAMPLE_API_KEY",
            isRequired: true
        )
        let entry = AgentSkillMarketplaceEntry(
            id: "credentialed-skill",
            skillName: "credentialed-skill",
            displayName: "Credentialed Skill",
            tagline: "Needs a key.",
            detail: "Test skill.",
            version: "1.0.0",
            author: "WillDeep",
            category: "Test",
            tags: [],
            minimumAppVersion: "1.60.0",
            skillDescription: "Use in tests.",
            skillBody: "# Credentialed Skill",
            supportFiles: [:],
            credentialRequirements: [requirement]
        )

        let skillURL = try AgentSkillMarketplaceStore.install(
            entry,
            credentials: ["example_api_key": "test-secret"],
            root: root
        )
        let body = try String(contentsOf: skillURL, encoding: .utf8)
        let account = AgentSkillMarketplaceStore.credentialAccount(for: entry, requirement: requirement)

        #expect(body.contains("willdeep-credential-env: EXAMPLE_API_KEY=keychain://\(account)"))
        #expect(!body.contains("test-secret"))
        #expect(AgentCredentialStore.load(account: account) == "test-secret")
        #expect(AgentSkillMarketplaceStore.isCredentialConfigured(for: entry, requirement: requirement))

        try AgentSkillMarketplaceStore.uninstall(entry, root: root)
        #expect(AgentCredentialStore.load(account: account).isEmpty)
    }

    private func temporarySkillRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-marketplace-tests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
