import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentSubagentLocalPromptTests {
    @Test("every built-in sends its complete local instructions exactly once",
          arguments: AgentSubagentProfileCatalog.builtIn.map(\.id))
    func everyTradeSendsInstructions(id: String) {
        let profile = AgentSubagentProfileCatalog.profile(id: id)
        let section = profile.capabilityPromptSection.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = AgentSubagentRunner.systemPrompt(workspaceURL: nil, profile: profile)
        #expect(!section.isEmpty)
        #expect(prompt.components(separatedBy: section).count == 2)
        #expect(prompt.contains("cannot ask the user"))
        #expect(profile.hostedVirtualModel == nil)
    }

    @Test("old hosted metadata never suppresses a customized soul or safety rules")
    func legacyProfileKeepsCustomInstructions() throws {
        var legacy = AgentSubagentProfileCatalog.scout
        legacy.hostedVirtualModel = "someim-32b-scout"
        legacy.modelBinding.model = "someim-32b-scout"
        legacy.capabilityPromptSection += "\nCustom worker instruction: cite verified evidence."
        let decoded = try JSONDecoder().decode(
            AgentSubagentProfile.self, from: JSONEncoder().encode(legacy)
        )
        let prompt = AgentSubagentRunner.systemPrompt(workspaceURL: nil, profile: decoded)
        #expect(decoded == legacy)
        #expect(prompt.contains(decoded.capabilityPromptSection))
        #expect(prompt.contains("READ-ONLY"))
        #expect(prompt.contains("cannot ask the user"))
    }

    @Test("model escalation preserves local job instructions")
    func retryPreservesInstructions() {
        let original = AgentSubagentProfileCatalog.reader
        let retry = AgentSubagentEscalation.escalatedProfile(from: original)
        let prompt = AgentSubagentRunner.systemPrompt(workspaceURL: nil, profile: retry)
        #expect(prompt.contains(original.capabilityPromptSection))
    }

    @Test("the unified profile projects both built-in and user soul instructions")
    func profileSoulSurvivesProjection() throws {
        var profile = AgentProfile.from(trade: AgentSubagentProfileCatalog.scout)
        profile.soul.promptSection = "Custom requirement: verify every cited path."
        profile.runtime.modelBinding.model = "someim-32b-scout"
        let trade = try #require(profile.asSubagentProfile())
        let prompt = AgentSubagentRunner.systemPrompt(workspaceURL: nil, profile: trade)
        #expect(prompt.contains(AgentSubagentJobPrompts.scout))
        #expect(prompt.contains(profile.soul.promptSection))
        #expect(trade.effectiveToolNames() == AgentSubagentProfileCatalog.scout.effectiveToolNames())
    }

    @Test("local prompt model guidance is translated in all supported locales")
    func localizedModelGuidance() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Xedit/WorkerModelPrompts.xcstrings")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        for key in ["agent-profiles.local-prompt-model-recommended", "agent-profiles.local-prompt-model-overridden"] {
            let localizations = try #require(strings[key]?["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == ["en", "es", "fr", "ja", "zh-Hans"])
        }
    }

    @Test("the seven known aliases migrate without changing transport or context",
          arguments: ["scout", "reader", "editor", "test-fixer", "build-fixer", "log-inspector", "git-detective"])
    func migrateKnownAliases(suffix: String) {
        var original = AgentConfiguration.default
        original.providerID = AgentProviderPreset.someIMID
        original.model = "someim-32b-\(suffix)"
        var expected = original
        expected.model = "someim-32b"
        let migrated = AgentSubagentModelCompatibility.configuration(original)
        #expect(migrated == expected)
        #expect(AgentSubagentModelCompatibility.configuration(migrated) == migrated)
    }

    @Test("same-named private models are never rewritten")
    func privateProviderRemainsPrivate() {
        var configuration = AgentConfiguration.default
        configuration.providerID = "private-provider"
        configuration.model = "someim-32b-reader"
        #expect(AgentSubagentModelCompatibility.configuration(configuration) == configuration)
        #expect(AgentSubagentModelCompatibility.recommendedModel(
            for: "reader", providerID: configuration.providerID
        ) == nil)
    }

    @Test("explicit models, unknown aliases and helper models remain untouched", arguments: [
        "glm-5", "deepseek-v4-flash", "someim-32b", "someim-32b-compressor",
        "someim-security-guard", "someim-judge", "someim-32b-custom", "someim-32b-judge",
    ])
    func otherModelsRemainUntouched(model: String) {
        var configuration = AgentConfiguration.default
        configuration.providerID = AgentProviderPreset.someIMID
        configuration.model = model
        #expect(AgentSubagentModelCompatibility.configuration(configuration) == configuration)
    }

    @Test("formerly hosted trades recommend one prompt-free entry; others keep their models")
    func recommendationsDoNotCreateNewAliases() {
        #expect(AgentSubagentModelCompatibility.legacyTradeIDs == [
            "scout", "reader", "editor", "test_fixer", "build_fixer", "log_inspector", "git_detective",
        ])
        for profile in AgentSubagentProfileCatalog.builtIn {
            let expected: String? = AgentSubagentModelCompatibility.legacyTradeIDs.contains(profile.id)
                ? "someim-32b" : nil
            #expect(AgentSubagentModelCompatibility.recommendedModel(
                for: profile.id, providerID: AgentProviderPreset.someIMID
            ) == expected)
        }
        #expect(SomeIMManagedModel.securityGuard == "someim-security-guard")
    }
}
