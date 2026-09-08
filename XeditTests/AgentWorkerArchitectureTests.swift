import Foundation
import Testing
@testable import WillDeep

@Suite @MainActor
struct AgentWorkerArchitectureTests {
    @Test("档案上下文覆盖共享档位，清空后恢复继承")
    func profileContextOverridesSharedTier() {
        var profile = AgentSubagentProfileCatalog.tester
        var models = AgentWorkerTierModels()
        models[.standard].contextWindowTokens = 262_144
        let configuration = AgentConfiguration(providerID: AgentProviderPreset.someIMID,
            baseURL: "https://example.invalid", model: "deepseek-v4-flash", apiKey: "test")
        profile.modelBinding.contextWindowTokens = 32_768
        let custom = AgentWorkerContextBudget.inputLimit(profile: profile, configuration: configuration, models: models)
        #expect(custom < 32_768)
        profile.modelBinding.contextWindowTokens = nil
        let inherited = AgentWorkerContextBudget.inputLimit(profile: profile, configuration: configuration, models: models)
        #expect(inherited > custom)
    }
    @Test
    func backgroundRequiresIndependentTaskAndOtherParentWork() {
        #expect(!AgentSubagentSchedulingPolicy.runsInBackground([:]))
        #expect(!AgentSubagentSchedulingPolicy.runsInBackground(["run_in_background": .bool(true)]))
        var arguments: [String: AgentJSONValue] = ["run_in_background": .bool(true), "independent_task": .bool(true)]
        #expect(!AgentSubagentSchedulingPolicy.runsInBackground(arguments))
        arguments["parent_parallel_work"] = .string("Review the independent API changes")
        #expect(AgentSubagentSchedulingPolicy.runsInBackground(arguments))
        arguments["independent_task"] = .bool(false)
        #expect(!AgentSubagentSchedulingPolicy.runsInBackground(arguments))
    }

    @Test
    func defaultContextsPreserveExplicitOverrides() throws {
        var models = AgentWorkerTierModels()
        for tier in AgentWorkerTier.allCases {
            #expect(models[tier].contextWindowTokens == 262_144)
        }
        models[.standard].contextWindowTokens = 65_536
        let restored = try JSONDecoder().decode(AgentWorkerTierModels.self, from: JSONEncoder().encode(models))
        #expect(restored[.standard].contextWindowTokens == 65_536)
        #expect(restored[.expert].contextWindowTokens == 262_144)
    }
    private var parent: AgentConfiguration {
        .init(providerID: AgentProviderPreset.someIMID, baseURL: "https://example.invalid/v1", model: "parent-model", apiKey: "test-placeholder")
    }

    @Test("five roles and three model slots are independent")
    func rolesAndTiers() {
        #expect(AgentWorkerTier.allCases.count == 3)
        #expect(AgentSubagentProfileCatalog.publicBuiltIn.map(\.id) == AgentWorkerRole.allCases.map(\.profileID))
        #expect(AgentWorkerTierModels.defaultBinding(.standard).contextWindowTokens == 262_144)
        #expect(AgentWorkerTierModels.defaultBinding(.expert).contextWindowTokens == 262_144)
        #expect(AgentSubagentProfileCatalog.reviewer.modelBinding.workerTier == .expert)
        #expect(AgentSubagentProfileCatalog.tester.modelBinding.workerTier == .standard)
    }

    @Test("context budgets offer four steps from 64K to 1M")
    func contextWindowSteps() {
        #expect(AgentWorkerTierModels.selectableWindows == [65_536, 131_072, 262_144, 1_048_576])
        #expect(AgentWorkerTierModels.selectableWindows == AgentWorkerTierModels.selectableWindows.sorted())
        #expect(AgentWorkerTierModels.selectableWindows.map(AgentWorkerTierModels.windowLabel)
            == ["64K", "128K", "256K", "1M"])
        // 配置文件可以钉任意值,标签不能把它四舍五入成一个和实际预算对不上的档位名。
        #expect(AgentWorkerTierModels.windowLabel(400_000) == "400000")
        #expect(AgentWorkerTierModels.windowLabel(0) == "0")
    }

    @Test("model slots persist separately from role instructions")
    func persistence() throws {
        let suite = "willdeep-profiles-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suite) }
        let store = AgentProfileStore(defaults: defaults)
        var profiles = store.profiles()
        let index = try #require(profiles.firstIndex { $0.id == "generalist" })
        profiles[index].soul.promptSection = "Preserve this custom instruction."
        store.save(profiles: profiles)
        var models = store.workerTierModels()
        models[.standard].model = "private-128k"
        store.save(workerTierModels: models)
        #expect(store.workerTierModels()[.standard].model == "private-128k")
        #expect(store.workerTierModels()[.expert].model == "gpt-5.6-sol")
        #expect(store.profiles().first { $0.id == "generalist" }?.soul.promptSection == profiles[index].soul.promptSection)
    }

    @Test("old bindings decode without selecting an unintended tier")
    func legacyBinding() throws {
        let data = Data(#"{"preferredProviderID":"custom","model":"my-model"}"#.utf8)
        let binding = try JSONDecoder().decode(AgentSubagentProfile.ModelBinding.self, from: data)
        #expect(binding.workerTier == nil)
        #expect(AgentWorkerTierModels.tier(for: binding) == nil)
        #expect(!AgentSubagentProfile.ModelBinding(preferredProviderEntryID: UUID()).inheritsEverything)
    }

    @Test("automatic public tiers cannot redirect private conversations")
    func privateIsolation() {
        var privateParent = parent
        privateParent.providerID = AgentProviderPreset.customID
        privateParent.baseURL = "http://localhost:8000/v1"
        let state = AppState()
        for tier in AgentWorkerTier.allCases {
            #expect(state.workerTierConfiguration(tier, parent: privateParent, models: .init()) == nil)
        }
        var models = AgentWorkerTierModels()
        models[.standard] = .init(model: "local-model", contextWindowTokens: 131_072)
        let resolved = state.workerTierConfiguration(.standard, parent: privateParent, models: models)
        #expect(resolved?.baseURL == privateParent.baseURL)
        #expect(resolved?.model == "local-model")
    }

    @Test("a deleted exact provider binding does not select a different account")
    func missingExactProvider() {
        var models = AgentWorkerTierModels()
        models[.expert].preferredProviderEntryID = UUID()
        #expect(AppState().workerTierConfiguration(.expert, parent: parent, models: models) == nil)
    }

    @Test("escalation uses the next configured slot, never the parent's apparent intelligence")
    func nextTierRoute() throws {
        let state = AppState()
        var models = AgentWorkerTierModels()
        let current = try #require(state.workerTierConfiguration(.standard, parent: parent, models: models))
        let profile = AgentSubagentProfileCatalog.generalist
        let route = state.nextWorkerTierConfiguration(for: profile, current: current, parent: parent, models: models)
        #expect(route?.tier == .advanced)
        #expect(route?.configuration.model == "deepseek-v4-flash")
        models[.advanced].model = current.model
        #expect(state.nextWorkerTierConfiguration(for: profile, current: current, parent: parent, models: models) == nil)
        #expect(state.nextWorkerTierConfiguration(for: profile, current: parent, parent: parent, models: models) == nil)
    }

    @Test("explicit models override a inherited tier marker and retain their endpoint")
    func explicitModelWins() {
        var binding = AgentSubagentProfile.ModelBinding(workerTier: .standard)
        binding.model = "my-explicit-model"
        #expect(AgentWorkerTierModels.tier(for: binding) == nil)
        binding.preferredProviderID = AgentProviderPreset.someIMID
        binding.preferredProviderEntryID = UUID()
        binding.model = "someim-32b-scout"
        #expect(AgentWorkerTierModels.tier(for: binding) == nil)
    }

    @Test("new worker and approval strings cover all five locales")
    func localizationCoverage() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Xedit/WorkerArchitecture.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (_, value) in strings {
            let locales = try #require(value["localizations"] as? [String: Any])
            #expect(Set(locales.keys) == Set(["en", "zh-Hans", "es", "fr", "ja"]))
        }
    }

    @Test(arguments: AgentSubagentProfileCatalog.builtIn)
    func escalationDoesNotChangeAuthority(_ original: AgentSubagentProfile) {
        let retry = AgentSubagentEscalation.escalatedProfile(from: original)
        #expect(retry.id == original.id)
        #expect(retry.toolNames == original.toolNames)
        #expect(retry.requiresWriteAccess == original.requiresWriteAccess)
        #expect(retry.capabilityPromptSection == original.capabilityPromptSection)
        #expect(retry.maxRounds == original.maxRounds)
        #expect(retry.escalation == .none)
    }

    @Test("a concise answer does not cause a paid retry")
    func shortAnswerIsNotFailure() {
        let outcome = AgentSubagentRunner.Outcome(report: "Found: src/main.go:8", usageTokens: 12, roundCount: 1, toolInvocationCount: 1)
        #expect(!AgentSubagentEscalation.shouldEscalate(outcome: outcome, profile: AgentSubagentProfileCatalog.generalist))
        var failed = outcome
        failed.verifierPassed = false
        #expect(AgentSubagentEscalation.shouldEscalate(outcome: failed, profile: AgentSubagentProfileCatalog.generalist))
    }

    @Test("input budgets reserve output and enforce the actual smaller window")
    func contextBudget() throws {
        let profile = AgentSubagentProfileCatalog.generalist
        var configuration = parent
        configuration.model = "fixture-32k"
        let limit = AgentWorkerContextBudget.inputLimit(profile: profile, configuration: configuration, models: .init())
        #expect(limit < 32_768)
        #expect(limit > 0)
        try AgentWorkerContextBudget.validate(messages: [.init(role: .user, content: "short task")], tools: [], limit: limit)
        #expect(throws: AgentWorkerContextBudget.Exceeded.self) {
            try AgentWorkerContextBudget.validate(messages: [.init(role: .user, content: String(repeating: "内容", count: 100_000))], tools: [], limit: limit)
        }
    }
}
