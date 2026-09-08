import Foundation
import Testing
@testable import WillDeep

/// agent-profile.v2: one store behind both subagent trades and dispatch
/// execution profiles, plus the soul (prompt / skills) attached to each.
@Suite
@MainActor
struct AgentProfileUnificationTests {
    @Test("恢复内置指令只清除附加指令，保留默认职责与挂载技能")
    func restoreDefaultInstructionsPreservesOtherFields() {
        var soul = AgentProfileSoul(purpose: "Investigate", basePromptSection: "Built-in rules",
                                    promptSection: "User additions", skillIdentifiers: ["skill-a"])
        soul.restoreDefaultInstructions()
        #expect(soul.promptSection.isEmpty)
        #expect(soul.basePromptSection == "Built-in rules")
        #expect(soul.purpose == "Investigate")
        #expect(soul.skillIdentifiers == ["skill-a"])
    }
    private func sandboxDefaults() -> (UserDefaults, String)? {
        let suiteName = "willdeep-profiles-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    // MARK: Migration

    @Test("v1 trade bindings and dispatch profiles migrate into one v2 record set")
    func migratesBothLegacyStores() throws {
        let (defaults, suiteName) = try #require(sandboxDefaults())
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }

        let binding = AgentSubagentProfile.ModelBinding(
            preferredProviderID: "some-im",
            model: "glm-5-air",
            contextWindowTokens: 96_000
        )
        defaults.set(
            try JSONEncoder().encode(["scout": binding]),
            forKey: AgentProfileStore.legacySubagentBindingsKey
        )
        let managedDispatch = AgentExecutionProfile(
            id: "managed:legacy-worker",
            name: "Legacy Worker",
            executor: .codexCLI,
            nativeProfileName: "work",
            origin: .managed
        )
        let editedBuiltIn = AgentExecutionProfile(
            id: AgentExecutionProfile.recommendedPlannerID,
            name: "DeepSeek V4 Pro Planner",
            executor: .willDeep,
            modelID: "custom-planner",
            providerID: "some-im",
            origin: .builtIn
        )
        defaults.set(
            try JSONEncoder().encode([managedDispatch, editedBuiltIn]),
            forKey: AgentProfileStore.legacyExecutionProfilesKey
        )

        let store = AgentProfileStore(defaults: defaults)
        let profiles = store.profiles()

        let scout = try #require(profiles.first { $0.id == "scout" })
        #expect(scout.runtime.modelBinding.model == "glm-5-air")
        #expect(scout.usages == [.subagent])

        let legacyWorker = try #require(profiles.first { $0.id == "managed:legacy-worker" })
        #expect(legacyWorker.usages == [.dispatch])
        #expect(legacyWorker.runtime.executor == .codexCLI)
        #expect(legacyWorker.runtime.nativeProfileName == "work")

        let planner = try #require(profiles.first { $0.id == AgentExecutionProfile.recommendedPlannerID })
        #expect(planner.runtime.modelBinding.model == "custom-planner")

        // v1 keys stay readable so a downgrade still finds its own data.
        #expect(defaults.data(forKey: AgentProfileStore.legacySubagentBindingsKey) != nil)
        #expect(defaults.data(forKey: AgentProfileStore.legacyExecutionProfilesKey) != nil)
        #expect(defaults.bool(forKey: AgentProfileStore.migrationFlagKey))
    }

    @Test("migration runs once; a user who then clears everything is not re-migrated")
    func migrationIsOneShot() throws {
        let (defaults, suiteName) = try #require(sandboxDefaults())
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }

        let binding = AgentSubagentProfile.ModelBinding(preferredProviderID: "some-im", model: "glm-5-air")
        defaults.set(
            try JSONEncoder().encode(["scout": binding]),
            forKey: AgentProfileStore.legacySubagentBindingsKey
        )
        let store = AgentProfileStore(defaults: defaults)
        _ = store.profiles()

        // The user resets their customizations: v2 goes back to empty.
        store.save(records: AgentProfileRecords())
        defaults.removeObject(forKey: AgentProfileStore.defaultsKey)

        let scout = try #require(store.profiles().first { $0.id == "scout" })
        #expect(scout.runtime.modelBinding.model == AgentSubagentProfileCatalog.scout.modelBinding.model)
    }

    @Test("built-ins persist as overrides, so later code changes still reach the user")
    func builtInsStoreOverridesNotCopies() throws {
        let (defaults, suiteName) = try #require(sandboxDefaults())
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }

        let store = AgentProfileStore(defaults: defaults)
        var profiles = store.profiles()
        let index = try #require(profiles.firstIndex { $0.id == "reader" })
        profiles[index].runtime.modelBinding.model = "my-model"
        store.save(profiles: profiles)

        let override = try #require(store.loadRecords().overrides["reader"])
        #expect(override.modelBinding?.model == "my-model")
        // Tool sets and budgets are code — they must not be frozen into
        // storage alongside the model edit.
        #expect(override.promptSection == nil)
        #expect(store.loadRecords().managed.isEmpty)

        let reloaded = try #require(store.profiles().first { $0.id == "reader" })
        #expect(reloaded.capability?.toolNames == AgentSubagentProfileCatalog.reader.toolNames)
        #expect(reloaded.capability?.maxRounds == AgentSubagentProfileCatalog.reader.maxRounds)
    }

    // MARK: Soul

    @Test("a user prompt section is appended after the trade's code-owned half")
    func soulPromptIsAppendedNotReplaced() throws {
        var profile = AgentProfile.from(trade: AgentSubagentProfileCatalog.scout)
        profile.soul.promptSection = "Always report paths relative to the repo root."

        let combined = profile.combinedPromptSection
        // Anchor on the contract (code half first, user half appended) rather
        // than on the job prompt's wording, which is mirrored from
        // docs/SOMEIM_WORKER_VIRTUAL_MODELS.md §3 and gets retuned there.
        #expect(combined.hasPrefix(AgentSubagentProfileCatalog.scout.capabilityPromptSection))
        #expect(combined.hasSuffix("Always report paths relative to the repo root."))

        let trade = try #require(profile.asSubagentProfile())
        #expect(trade.capabilityPromptSection == combined)
    }

    @Test("a soul-edited deep trade still ships its section, unlike the untouched default")
    func deepShipsUserSectionOnly() throws {
        let untouched = AgentProfile.from(trade: AgentSubagentProfileCatalog.deep)
        let untouchedPrompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: try #require(untouched.asSubagentProfile())
        )
        #expect(untouchedPrompt.contains("Your trade is INVESTIGATION."))

        var edited = untouched
        edited.soul.promptSection = "Prefer git history over guessing."
        let editedPrompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: try #require(edited.asSubagentProfile())
        )
        #expect(editedPrompt.contains("Prefer git history over guessing."))
    }

    @Test("skills configured on a soul reach the trade that runs")
    func soulSkillsReachTheTrade() throws {
        var profile = AgentProfile.from(trade: AgentSubagentProfileCatalog.reader)
        profile.soul.skillIdentifiers = ["pdf", "docx"]

        #expect(try #require(profile.asSubagentProfile()).skillIdentifiers == ["pdf", "docx"])

        // Unknown identifiers are skipped rather than failing the spawn.
        var unknown = profile
        unknown.soul.skillIdentifiers = ["no-such-skill-\(UUID().uuidString)"]
        let trade = try #require(unknown.asSubagentProfile())
        #expect(AgentSubagentRunner.skillPromptSection(for: trade) == nil)
    }

    @Test("an external CLI profile never claims the soul applies to it")
    func externalCLIProfilesIgnoreSoul() {
        var profile = AgentProfile.from(execution: AgentExecutionProfile(
            id: "managed:cli",
            name: "Codex worker",
            executor: .codexCLI,
            origin: .managed
        ))
        profile.soul.promptSection = "You are a haiku poet."
        profile.usages = [.dispatch, .subagent]

        #expect(!profile.soulApplies)
        // It is also not offered to spawn_agent: the in-process runner is the
        // only thing that can honour a tool whitelist and a prompt.
        #expect(profile.asSubagentProfile() == nil)
    }

    // MARK: Safety invariants

    @Test("a user-created profile cannot grant itself write access")
    func managedProfilesCannotGrantWriteAccess() throws {
        let profile = AgentProfile(
            id: "managed:sneaky",
            name: "Sneaky",
            origin: .managed,
            usages: [.subagent],
            soul: .empty,
            runtime: AgentProfileRuntime(
                executor: .willDeep,
                nativeProfileName: nil,
                modelBinding: .inheritsParent
            ),
            capability: AgentProfileCapability(
                toolNames: ["read_file", "apply_patch"],
                requiresWriteAccess: true,
                maxRounds: 6,
                toolPayloadCharacterLimit: 8_000,
                escalation: .none
            )
        )

        let trade = try #require(profile.asSubagentProfile())
        #expect(!trade.requiresWriteAccess)
        // apply_patch is outside the read-only whitelist, so the intersection
        // drops it even when write access is requested.
        #expect(!trade.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
    }

    @Test("the built-in editor trade keeps its narrow write door")
    func editorTradeKeepsWriteAccess() throws {
        let editor = try #require(
            AgentProfile.from(trade: AgentSubagentProfileCatalog.editor).asSubagentProfile()
        )

        #expect(editor.requiresWriteAccess)
        #expect(editor.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
        #expect(!editor.effectiveToolNames().contains("apply_patch"))
    }

    // MARK: Dispatch façade

    @Test("saving from the dispatch editor preserves soul and subagent usage")
    func dispatchSavePreservesSubagentSide() throws {
        let (defaults, suiteName) = try #require(sandboxDefaults())
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }

        let profileStore = AgentProfileStore(defaults: defaults)
        let shared = AgentProfile(
            id: "managed:shared",
            name: "Shared worker",
            origin: .managed,
            usages: [.subagent, .dispatch],
            soul: AgentProfileSoul(
                purpose: "Shared",
                basePromptSection: "",
                promptSection: "Be terse.",
                skillIdentifiers: ["pdf"]
            ),
            runtime: AgentProfileRuntime(
                executor: .willDeep,
                nativeProfileName: nil,
                modelBinding: AgentSubagentProfile.ModelBinding(preferredProviderID: "some-im", model: "glm-5")
            ),
            capability: .managedDefault
        )
        profileStore.save(profiles: profileStore.profiles() + [shared])

        let executionStore = AgentExecutionProfileStore(defaults: defaults)
        var dispatchProfiles = executionStore.loadManaged()
        let index = try #require(dispatchProfiles.firstIndex { $0.id == "managed:shared" })
        dispatchProfiles[index].modelID = "glm-5-pro"
        executionStore.saveManaged(dispatchProfiles)

        let reloaded = try #require(profileStore.profiles().first { $0.id == "managed:shared" })
        #expect(reloaded.runtime.modelBinding.model == "glm-5-pro")
        #expect(reloaded.soul.promptSection == "Be terse.")
        #expect(reloaded.soul.skillIdentifiers == ["pdf"])
        #expect(reloaded.usages == [.subagent, .dispatch])
    }

    @Test("dispatch profiles and subagent trades come from the same store but stay filtered")
    func usageFiltering() throws {
        let (defaults, suiteName) = try #require(sandboxDefaults())
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }

        let store = AgentProfileStore(defaults: defaults)
        let subagentIDs = Set(store.profiles(usage: .subagent).map(\.id))
        let dispatchIDs = Set(store.profiles(usage: .dispatch).map(\.id))

        #expect(subagentIDs.isSuperset(of: ["scout", "reader", "deep", "editor"]))
        #expect(dispatchIDs.contains(AgentExecutionProfile.recommendedPlannerID))
        #expect(subagentIDs.isDisjoint(with: dispatchIDs))
    }
}
