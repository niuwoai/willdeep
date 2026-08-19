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

    /// Catalog lookup still resolves to deep — it is a lookup, not a policy.
    /// The spawn path refuses unknown names outright (see
    /// `AppState.executeSpawnAgentToolCall`), so a typo no longer buys the 1M
    /// tier for free; `isKnown` is what that check reads.
    @Test("catalog lookup resolves unknown names to deep, but reports them as unknown")
    func unknownProfileIsReportedAsUnknown() {
        #expect(AgentSubagentProfileCatalog.profile(id: "librarian").id == "deep")
        #expect(!AgentSubagentProfileCatalog.isKnown(id: "librarian"))
    }

    @Test("trade names resolve case-insensitively")
    func profileLookupIsCaseInsensitive() {
        #expect(AgentSubagentProfileCatalog.profile(id: "SCOUT").id == "scout")
        #expect(AgentSubagentProfileCatalog.profile(id: " Reader ").id == "reader")
    }

    @Test("deep preserves the full investigation budget and is pinned to the L tier")
    func deepIsPinnedToTheDeepTier() {
        let deep = AgentSubagentProfileCatalog.deep

        #expect(deep.effectiveToolNames() == AgentSubagentRunner.allowedToolNames)
        #expect(deep.maxRounds == AgentSubagentRunner.maxRounds)
        #expect(deep.modelBinding.preferredProviderID == AgentProviderPreset.someIMID)
        // Previously nil, i.e. "whatever the provider's primary model is".
        // That made the 1M tier the default rather than the exception, so
        // there was nothing for an escalation to escalate to.
        #expect(deep.modelBinding.model == "deepseek-v4-flash")
        #expect(deep.modelBinding.contextWindowTokens
            == AgentSubagentProfileCatalog.deepContextWindowTokens)
        #expect(deep.escalation == .none)
    }

    @Test("a new session opens on the standard tier, not the scarce one")
    func newSessionsDefaultToTheStandardTier() {
        // The whole admission mechanism is theatre if the session already
        // starts on the model `deep` would escalate to.
        #expect(SomeIMIntegrationSettings.defaultTextModel == "glm-5")
        #expect(SomeIMIntegrationSettings.defaultTextModel
            != AgentSubagentProfileCatalog.deep.modelBinding.model)

        let preset = AgentProviderPreset.preset(id: AgentProviderPreset.someIMID)
        #expect(preset?.defaultModel == "glm-5")
        // Vision must not follow the text default down: some.im has its own
        // multimodal model and the picker reads it through the preset.
        #expect(preset?.defaultVisionModel == SomeIMIntegrationSettings.defaultVisionModel)
        #expect(preset?.defaultVisionModel == "qwen3-vl-plus")
    }

    @Test("implicit some.im worker defaults follow a private parent provider")
    func implicitHostedDefaultDoesNotEscapePrivateProvider() {
        let binding = AgentSubagentProfileCatalog.scout.modelBinding
        #expect(AppState.implicitSomeIMBindingFollowsParent(
            binding: binding,
            parentProviderID: "private-openai-compatible"
        ))
        #expect(!AppState.implicitSomeIMBindingFollowsParent(
            binding: binding,
            parentProviderID: AgentProviderPreset.someIMID
        ))

        var explicit = binding
        explicit.preferredProviderEntryID = UUID()
        #expect(!AppState.implicitSomeIMBindingFollowsParent(
            binding: explicit,
            parentProviderID: "private-openai-compatible"
        ))
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

    @Test("only built-in writing trades can reach their scoped write tools")
    func writeToolsOnlyForWritingTrades() {
        // Even with the grant flag set, a read-only trade gets nothing extra.
        let scout = AgentSubagentProfileCatalog.scout.effectiveToolNames(writeAccessGranted: true)
        #expect(!scout.contains("apply_patch"))

        let editorUngranted = AgentSubagentProfileCatalog.editor.effectiveToolNames()
        #expect(!editorUngranted.contains("apply_patch"))

        let editorGranted = AgentSubagentProfileCatalog.editor.effectiveToolNames(writeAccessGranted: true)
        #expect(editorGranted.contains("apply_patch"))

        let implementer = AgentSubagentProfileCatalog.implementer
            .effectiveToolNames(writeAccessGranted: true)
        #expect(implementer.contains("apply_patch"))
        #expect(implementer.contains("create_file"))
    }

    @Test("writing trades remain write-tier for policy and audit")
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

    @Test("deployable trades use 32K 48K 64K and 256K windows with no 16K tier")
    func deployableContextTiersAreExplicit() {
        #expect(AgentSubagentProfileCatalog.scout.modelBinding.contextWindowTokens == 32_768)
        #expect(AgentSubagentProfileCatalog.logInspector.modelBinding.contextWindowTokens == 32_768)
        #expect(AgentSubagentProfileCatalog.reader.modelBinding.contextWindowTokens == 49_152)
        #expect(AgentSubagentProfileCatalog.editor.modelBinding.contextWindowTokens == 49_152)
        #expect(AgentSubagentProfileCatalog.buildFixer.modelBinding.contextWindowTokens == 49_152)
        #expect(AgentSubagentProfileCatalog.testFixer.modelBinding.contextWindowTokens == 65_536)
        #expect(AgentSubagentProfileCatalog.implementer.modelBinding.contextWindowTokens == 262_144)
        #expect(!AgentSubagentProfileCatalog.builtIn.contains {
            $0.modelBinding.contextWindowTokens == 16_384
        })
    }

    @Test("smart and workspace access inherit bounded subagent writes while strict still asks")
    func boundedWriterApprovalFollowsParentWorkspacePolicy() async {
        let appState = AppState()
        let arguments: [String: AgentJSONValue] = [
            "profile": .string("implementer"),
            "target_files": .array([.string("Sources/A.swift"), .string("Sources/New.swift")]),
        ]

        let smart = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: arguments,
            risk: .write,
            rootDirectory: nil,
            approvalMode: .smart
        )
        let workspace = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: arguments,
            risk: .write,
            rootDirectory: nil,
            approvalMode: .workspaceAccess
        )
        let strict = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: arguments,
            risk: .write,
            rootDirectory: nil,
            approvalMode: .requestEveryTime
        )

        #expect(smart == .staticAllowlist)
        #expect(workspace == .workspaceAccess)
        #expect(strict == nil)

        let taskFallback = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: [
                "profile": .string("implementer"),
                "task": .object([
                    "goal": .string("Implement the feature"),
                    "relevant_files": .array([
                        .string("Sources/A.swift"),
                        .string("Sources/New.swift"),
                    ]),
                ]),
            ],
            risk: .write,
            rootDirectory: nil,
            approvalMode: .smart
        )
        #expect(taskFallback == .staticAllowlist)
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

    @Test("结构化输出兼容纯 JSON 与 JSON 代码块")
    func structuredOutputFallbackAcceptsValidatedJSONText() throws {
        let schema = AgentStructuredSchema(
            type: .object,
            properties: ["result": .init(type: .string)],
            required: ["result"],
            additionalProperties: false
        )
        let raw = #"{"result":"ok"}"#
        let fenced = """
        兼容模式：
        ```json
        {"result":"ok"}
        ```
        """

        #expect(AgentSubagentRunner.validatedStructuredOutputFallback(in: raw, schema: schema) == raw)
        let fencedResult = try #require(
            AgentSubagentRunner.validatedStructuredOutputFallback(in: fenced, schema: schema)
        )
        #expect(fencedResult == raw)
        #expect(AgentSubagentRunner.validatedStructuredOutputFallback(
            in: #"{"result":"ok","extra":true}"#,
            schema: schema
        ) == nil)
        #expect(AgentSubagentRunner.validatedStructuredOutputFallback(
            in: "只有解释，没有 JSON",
            schema: schema
        ) == nil)
    }

    // MARK: Prompt composition

    @Test("narrow trades add their capability section to the prompt")
    func promptCarriesCapabilitySection() {
        let scoutPrompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: AgentSubagentProfileCatalog.scout
        )

        // Assert the section is present by its own text rather than a keyword
        // that happens to be in it — the job prompts are mirrored from
        // docs/SOMEIM_WORKER_VIRTUAL_MODELS.md §3 and their wording moves.
        #expect(scoutPrompt.contains(AgentSubagentJobPrompts.scout))
        // The invariants stay regardless of trade.
        #expect(scoutPrompt.contains("READ-ONLY"))
        #expect(scoutPrompt.contains("cannot ask the user"))
    }

    @Test("a relay-hosted trade sends no local job section, only the invariants")
    func hostedTradeOmitsLocalJobSection() {
        let hosted = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            profile: AgentSubagentProfileCatalog.scout,
            jobPromptIsHosted: true
        )

        // Sending our copy too would stack two sets of the same instructions
        // on top of the relay's and pay for both.
        #expect(!hosted.contains(AgentSubagentJobPrompts.scout))
        // Safety rules are never hosted: they ship from the client always.
        #expect(hosted.contains("READ-ONLY"))
        #expect(hosted.contains("cannot ask the user"))
    }

    @Test("only the managed worker trades carry a hosted model")
    func hostedModelsCoverExactlyTheManagedTrades() {
        let hosted = AgentSubagentProfileCatalog.builtIn
            .filter { $0.hostedVirtualModel != nil }
            .map(\.id)

        #expect(Set(hosted) == AgentSubagentJobPrompts.hostedTradeIDs)
        // deep / tester / reviewer stay user-configurable in every login
        // state — locking deep to a cheap tier would delete the trade whose
        // whole job is to run at the parent's capability.
        #expect(AgentSubagentProfileCatalog.deep.hostedVirtualModel == nil)
        #expect(AgentSubagentProfileCatalog.tester.hostedVirtualModel == nil)
        #expect(AgentSubagentProfileCatalog.reviewer.hostedVirtualModel == nil)
        #expect(AgentSubagentProfileCatalog.implementer.hostedVirtualModel == nil)
    }

    @Test("hosted model ids hyphenate snake_case trade ids")
    func hostedModelIDsMatchRelayNaming() {
        #expect(AgentSubagentProfileCatalog.testFixer.hostedVirtualModel == "someim-32b-test-fixer")
        #expect(AgentSubagentProfileCatalog.scout.hostedVirtualModel == "someim-32b-scout")
        #expect(AgentSubagentJobPrompts.hostedModel(for: "deep") == nil)
    }

    @Test("a trade is only hosted while signed in to some.im")
    func hostedResolutionFollowsLoginState() {
        let scout = AgentSubagentProfileCatalog.scout

        #expect(scout.usesHostedJobPrompt(someIMAuthenticated: true))
        // Signed out the user's own binding applies and the client supplies
        // the job prompt, so the same trade still behaves the same way.
        #expect(!scout.usesHostedJobPrompt(someIMAuthenticated: false))
        #expect(!AgentSubagentProfileCatalog.deep.usesHostedJobPrompt(someIMAuthenticated: true))
    }

    @Test("结构化提示为不支持工具调用的 Provider 提供 JSON 兼容路径")
    func structuredPromptCarriesProviderCompatibilityPath() {
        let prompt = AgentSubagentRunner.systemPrompt(
            workspaceURL: nil,
            outputSchema: AgentStructuredSchema(type: .string)
        )

        #expect(prompt.contains("provider cannot call"))
        #expect(prompt.contains("raw JSON value"))
        #expect(prompt.contains("same schema validation"))
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

    @Test("the legacy some.im default can still locate its provider entry")
    func legacyDefaultCanLocateSomeIM() throws {
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

    @Test("provider lookup falls back to the active entry when some.im is absent")
    func providerLookupFallsBackToActive() throws {
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
