import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSharedRuntimeConfigTests {
    /// A config.toml shaped like the one willdeep-rs ships, so the parser is
    /// tested against the real neighbours it has to skip rather than an
    /// idealized three-line file.
    private let realisticConfig = """
    version = 1

    [providers.some-im]
    base_url = "https://some.im/v1"
    model = "glm-5"

    [agent]
    max_turns = 40
    language = "zh-Hans"
    small_model_routing = true
    auto_dispatch_read_only = false
    max_deep_calls_per_harness = 2   # keep the 1M tier rare
    safety_judge = true

    [subagents.scout]
    context_window = 32768

    [notifications]
    webhook_enabled = true
    """

    @Test("the shared [agent] section parses alongside everything else in the file")
    func parsesAgentSectionFromRealisticConfig() {
        let config = AgentSharedRuntimeConfig.parse(realisticConfig)

        #expect(config.smallModelRouting == true)
        #expect(config.autoDispatchReadOnly == false)
        // Trailing inline comment must not become part of the number.
        #expect(config.maxDeepCallsPerHarness == 2)
    }

    @Test("keys from other sections never leak into [agent]")
    func otherSectionsDoNotLeak() {
        // `[subagents.scout]` has a context_window and `[notifications]` a
        // webhook_enabled; a section-blind parser would happily mix them in.
        let config = AgentSharedRuntimeConfig.parse("""
        [subagents.scout]
        max_deep_calls_per_harness = 9

        [notifications]
        small_model_routing = false
        """)

        #expect(config.maxDeepCallsPerHarness == nil)
        #expect(config.smallModelRouting == nil)
    }

    @Test("a sub-table of [agent] is a different table")
    func agentSubTableIsNotTheAgentSection() {
        let config = AgentSharedRuntimeConfig.parse("""
        [agent.experimental]
        small_model_routing = true
        """)

        #expect(config.smallModelRouting == nil)
    }

    @Test("an absent key stays nil rather than inventing a default")
    func absentKeysAreNil() {
        let config = AgentSharedRuntimeConfig.parse("[agent]\nmax_turns = 40\n")

        // nil is what lets the caller fall back to its own configuration;
        // defaulting here would silently override the app's settings with
        // values the user never wrote.
        #expect(config.smallModelRouting == nil)
        #expect(config.autoDispatchReadOnly == nil)
        #expect(config.maxDeepCallsPerHarness == nil)
    }

    @Test("a missing or unreadable config.toml is simply empty")
    func missingFileIsEmpty() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-\(UUID().uuidString)/config.toml")

        #expect(AgentSharedRuntimeConfig.load(from: missing) == AgentSharedRuntimeConfig())
    }

    // MARK: Precedence

    @Test("the shared config wins over the app's own deep budget default")
    func sharedConfigWinsForDeepBudget() {
        var shared = AgentSharedRuntimeConfig()
        shared.maxDeepCallsPerHarness = 1

        #expect(AgentSettingsStore.loadDeepAdmissionBudget(sharedConfig: shared) == 1)
        // Out-of-range values from a hand-edited file are clamped, not trusted.
        shared.maxDeepCallsPerHarness = 999
        #expect(AgentSettingsStore.loadDeepAdmissionBudget(sharedConfig: shared)
            == AgentDeepAdmission.budgetCeiling)
        shared.maxDeepCallsPerHarness = -4
        #expect(AgentSettingsStore.loadDeepAdmissionBudget(sharedConfig: shared) == 0)
    }

    @Test("without a shared value the app falls back to its own default")
    func appDefaultAppliesWhenSharedConfigIsSilent() {
        #expect(AgentSettingsStore.loadDeepAdmissionBudget(sharedConfig: AgentSharedRuntimeConfig())
            == AgentDeepAdmission.defaultBudgetPerSession)
    }

    @Test("small_model_routing = false turns steering off for both clients")
    func sharedConfigCanDisableRouting() {
        var shared = AgentSharedRuntimeConfig()
        shared.smallModelRouting = false

        #expect(AgentRequestRouter.steering(
            for: "这个函数在哪个文件",
            delegationPolicy: .automatic,
            sharedConfig: shared
        ) == nil)

        // Absent means on, matching the willdeep-rs default.
        shared.smallModelRouting = nil
        #expect(AgentRequestRouter.steering(
            for: "这个函数在哪个文件",
            delegationPolicy: .automatic,
            sharedConfig: shared
        ) != nil)
    }
}
