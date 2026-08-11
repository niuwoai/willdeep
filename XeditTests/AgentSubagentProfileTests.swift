import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentSubagentProfileTests {
    // MARK: Resolution

    @Test("a missing profile argument resolves to deep, preserving old behaviour")
    func missingProfileResolvesToDeep() {
        #expect(AgentSubagentProfileCatalog.profile(id: nil).id == "deep")
        #expect(AgentSubagentProfileCatalog.profile(id: "").id == "deep")
    }

    @Test("an unknown trade name falls back to deep rather than failing the spawn")
    func unknownProfileFallsBackToDeep() {
        #expect(AgentSubagentProfileCatalog.profile(id: "librarian").id == "deep")
        #expect(!AgentSubagentProfileCatalog.isKnown(id: "librarian"))
    }

    @Test("trade names resolve case-insensitively")
    func profileLookupIsCaseInsensitive() {
        #expect(AgentSubagentProfileCatalog.profile(id: "SCOUT").id == "scout")
        #expect(AgentSubagentProfileCatalog.profile(id: " Reader ").id == "reader")
    }

    @Test("deep preserves the full investigation budget and uses automatic provider routing")
    func deepUsesAutomaticProviderRouting() {
        let deep = AgentSubagentProfileCatalog.deep

        #expect(deep.effectiveToolNames() == AgentSubagentRunner.allowedToolNames)
        #expect(deep.maxRounds == AgentSubagentRunner.maxRounds)
        #expect(deep.modelBinding.preferredProviderID == AgentProviderPreset.someIMID)
        #expect(deep.modelBinding.model == nil)
        #expect(deep.escalation == .none)
    }

    // MARK: Narrowing

    @Test("a trade can only narrow the global whitelist, never widen it")
    func profileToolsAreIntersected() {
        var rogue = AgentSubagentProfileCatalog.scout
        rogue.toolNames = ["read_file", "run_command", "write_file", "spawn_agent"]

        let effective = rogue.effectiveToolNames()

        #expect(effective.contains("read_file"))
        #expect(effective.contains("run_command"))
        // Neither was ever in the read-only set, so neither can be granted.
        #expect(!effective.contains("write_file"))
        #expect(!effective.contains("spawn_agent"))
    }

    @Test("narrow trades really are narrower than deep")
    func narrowTradesCarryFewerTools() {
        let scout = AgentSubagentProfileCatalog.scout.effectiveToolNames()
        let deep = AgentSubagentProfileCatalog.deep.effectiveToolNames()

        #expect(scout.count < deep.count)
        #expect(scout.isSubset(of: deep))
        // Locating code needs no shell.
        #expect(!scout.contains("run_command"))
    }

    @Test("the tool table shrinks with the trade")
    func toolDescriptorsFollowProfile() {
        let scoutTools = AgentSubagentRunner.toolDescriptors(
            profile: AgentSubagentProfileCatalog.scout
        )
        let deepTools = AgentSubagentRunner.toolDescriptors(
            profile: AgentSubagentProfileCatalog.deep
        )

        #expect(scoutTools.count < deepTools.count)
        #expect(!scoutTools.contains { $0.name == "run_command" })
    }

    // MARK: Write access

    @Test("only the editor trade can ever reach a write tool")
    func writeToolsOnlyForEditor() {
        // Even with the grant flag set, a read-only trade gets nothing extra.
        let scout = AgentSubagentProfileCatalog.scout.effectiveToolNames(writeAccessGranted: true)
        #expect(!scout.contains("apply_patch"))

        let editorUngranted = AgentSubagentProfileCatalog.editor.effectiveToolNames()
        #expect(!editorUngranted.contains("apply_patch"))

        let editorGranted = AgentSubagentProfileCatalog.editor.effectiveToolNames(writeAccessGranted: true)
        #expect(editorGranted.contains("apply_patch"))
    }

    @Test("spawning the editor trade is write-tier so it hits the approval card")
    func editorSpawnIsWriteTier() {
        let editorRisk = AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: ["profile": .string("editor")]
        )
        let scoutRisk = AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: ["profile": .string("scout")]
        )
        let defaultRisk = AgentToolRegistry.risk(for: "spawn_agent", arguments: [:])

        #expect(editorRisk == .write)
        #expect(scoutRisk == .read)
        #expect(defaultRisk == .read)
    }

    // MARK: Payload budget

    @Test("tool output is capped to the trade's budget with a legible notice")
    func toolPayloadIsClampedPerTrade() {
        let payload = String(repeating: "x", count: 20_000)

        let clamped = AgentSubagentRunner.clampedToolPayload(payload, limit: 8_000)

        #expect(clamped.count < payload.count)
        #expect(clamped.hasPrefix("xxxx"))
        // The child model has to understand what happened to act on it.
        #expect(clamped.contains("truncated"))
    }

    @Test("output under the budget is passed through untouched")
    func shortPayloadIsUnchanged() {
        #expect(AgentSubagentRunner.clampedToolPayload("small", limit: 8_000) == "small")
    }

    // MARK: Prompt composition

    @Test("narrow trades add their capability section to the prompt")
    func promptCarriesCapabilitySection() {
        let scoutPrompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: AgentSubagentProfileCatalog.scout
        )

        #expect(scoutPrompt.contains("LOCATION"))
        // The invariants stay regardless of trade.
        #expect(scoutPrompt.contains("READ-ONLY"))
        #expect(scoutPrompt.contains("cannot ask the user"))
    }

    @Test("the editor prompt names its one writable file and drops the read-only claim")
    func editorPromptScopesToTargetFile() {
        let prompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: AgentSubagentProfileCatalog.editor,
            writeAccess: AgentSubagentWriteAccess(targetRelativePath: "Sources/Auth.swift")
        )

        #expect(prompt.contains("Sources/Auth.swift"))
        #expect(prompt.contains("apply_patch"))
        // A rule contradicted by the tool set is worse than no rule.
        #expect(!prompt.contains("Write operations are denied"))
    }

    // MARK: Settings overrides

    @Test("user overrides replace only the model binding")
    func overridesReplaceBindingOnly() throws {
        let overrides = [
            "scout": AgentSubagentProfile.ModelBinding(
                preferredProviderID: "deepseek",
                model: "deepseek-v4-flash",
                contextWindowTokens: 128_000
            )
        ]

        let resolved = AgentSubagentProfileCatalog.applyingOverrides(overrides)
        let scout = try #require(resolved.first { $0.id == "scout" })

        #expect(scout.modelBinding.model == "deepseek-v4-flash")
        // Tool sets and budgets are code, not configuration.
        #expect(scout.toolNames == AgentSubagentProfileCatalog.scout.toolNames)
        #expect(scout.maxRounds == AgentSubagentProfileCatalog.scout.maxRounds)
    }

    @Test("subagent provider defaults to some.im even when another provider is active")
    func defaultProviderPrefersSomeIM() throws {
        let deepSeek = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            flashPrimary: "deepseek-chat",
            proPrimary: "deepseek-reasoner"
        )
        let someIM = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            displayName: "some.im",
            baseURL: "https://api.some.im/v1",
            flashPrimary: "glm-5",
            proPrimary: "glm-5"
        )
        let library = AgentProviderLibrary(entries: [deepSeek, someIM], activeID: deepSeek.id)

        let selected = try #require(AgentSubagentProfileCatalog.defaultProviderEntry(in: library))

        #expect(selected.id == someIM.id)
    }

    @Test("subagent provider falls back to the active provider when some.im is absent")
    func defaultProviderFallsBackToActive() throws {
        let first = AgentProviderEntry(
            providerID: AgentProviderPreset.openAIID,
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            flashPrimary: "gpt-5-mini",
            proPrimary: "gpt-5"
        )
        let active = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            flashPrimary: "deepseek-chat",
            proPrimary: "deepseek-reasoner"
        )
        let library = AgentProviderLibrary(entries: [first, active], activeID: active.id)

        let selected = try #require(AgentSubagentProfileCatalog.providerEntry(
            for: AgentSubagentProfileCatalog.scout.modelBinding,
            in: library
        ))

        #expect(selected.id == active.id)
        #expect(!AgentSubagentProfileCatalog.bindingModelApplies(
            AgentSubagentProfileCatalog.scout.modelBinding,
            to: selected
        ))
    }

    @Test("an exact provider entry binding wins over duplicate provider presets")
    func exactProviderEntryBindingWins() throws {
        let first = AgentProviderEntry(
            providerID: AgentProviderPreset.customID,
            displayName: "Gateway A",
            baseURL: "https://a.example/v1",
            flashPrimary: "model-a",
            proPrimary: "model-a"
        )
        let second = AgentProviderEntry(
            providerID: AgentProviderPreset.customID,
            displayName: "Gateway B",
            baseURL: "https://b.example/v1",
            flashPrimary: "model-b",
            proPrimary: "model-b"
        )
        let library = AgentProviderLibrary(entries: [first, second], activeID: first.id)
        let binding = AgentSubagentProfile.ModelBinding(
            preferredProviderEntryID: second.id,
            preferredProviderID: AgentProviderPreset.customID,
            model: "handwritten-model",
            contextWindowTokens: nil
        )

        let selected = try #require(AgentSubagentProfileCatalog.providerEntry(for: binding, in: library))

        #expect(selected.id == second.id)
        #expect(AgentSubagentProfileCatalog.bindingModelApplies(binding, to: selected))
    }

    @Test("every built-in trade appears in the schema catalog line")
    func toolDescriptionListsEveryTrade() {
        let catalog = AgentSubagentProfileCatalog.toolDescriptionCatalog

        for profile in AgentSubagentProfileCatalog.builtIn {
            #expect(catalog.contains("`\(profile.id)`"), "missing \(profile.id)")
        }
    }
}
