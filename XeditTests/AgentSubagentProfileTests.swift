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
        // Previously nil, i.e. "whatever the provider's primary model is".
        // That made the 1M tier the default rather than the exception, so
        // there was nothing for an escalation to escalate to.
        #expect(deep.modelBinding.workerTier == .expert)
        #expect(deep.modelBinding.model == nil)
        #expect(deep.escalation == .none)
    }

    @Test("read-only operations trades keep enough rounds for evidence and synthesis")
    func operationsTradesUseExpandedRoundBudget() {
        #expect(AgentSubagentProfileCatalog.opsRunner.maxRounds == 32)
        #expect(AgentSubagentProfileCatalog.terminalOperator.maxRounds == 32)
    }

    @Test("a new some.im session opens on the automatic Flash route")
    func newSessionsDefaultToAutoFlash() {
        #expect(SomeIMIntegrationSettings.defaultTextModel == SomeIMManagedModel.autoFlash)
        #expect(SomeIMIntegrationSettings.defaultTextModel
            != AgentSubagentProfileCatalog.deep.modelBinding.model)

        let preset = AgentProviderPreset.preset(id: AgentProviderPreset.someIMID)
        #expect(preset?.defaultModel == SomeIMManagedModel.autoFlash)
        // Vision must not follow the text default down: some.im has its own
        // multimodal model and the picker reads it through the preset.
        #expect(preset?.defaultVisionModel == SomeIMIntegrationSettings.defaultVisionModel)
        #expect(preset?.defaultVisionModel == "qwen3-vl-plus")
    }

    @Test("implicit some.im worker defaults follow a private parent provider")
    func implicitHostedDefaultDoesNotEscapePrivateProvider() {
        let binding = AgentSubagentProfile.ModelBinding(preferredProviderID: AgentProviderPreset.someIMID)
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
        // Scout got a shell in 1.303.0-rc1 so that `ls`/`head` stop being
        // laundered through `ops_runner`, but only a read-only one — the gate
        // that enforces that lives in the runner, asserted separately.
        #expect(scout.contains("run_command"))
        #expect(AgentSubagentProfileCatalog.strictReadOnlyShellTradeIDs.contains(
            AgentSubagentProfileCatalog.scoutID
        ))
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
        #expect(!scoutTools.contains { $0.name == "web_fetch" })
    }

    // MARK: Write access

    @Test("dedicated writers and the scoped generalist can reach write tools")
    func writeToolsRequireABoundedWriteCapability() {
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

        let generalist = AgentSubagentProfileCatalog.generalist
        #expect(!generalist.effectiveToolNames().contains("apply_patch"))
        #expect(generalist.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
        #expect(generalist.effectiveToolNames(writeAccessGranted: true).contains("create_file"))
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
        let scopedGeneralistRisk = AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: [
                "profile": .string("generalist"),
                "target_files": .array([.string("Sources/Utility.swift")]),
            ]
        )
        let defaultRisk = AgentToolRegistry.risk(for: "spawn_agent", arguments: [:])

        #expect(editorRisk == .write)
        #expect(scoutRisk == .read)
        #expect(scopedGeneralistRisk == .write)
        #expect(defaultRisk == .read)
    }

    @Test("roles select shared model slots with 128K or 256K budgets")
    func deployableContextTiersAreExplicit() {
        #expect(AgentSubagentProfileCatalog.scout.modelBinding.workerTier == .standard)
        #expect(AgentSubagentProfileCatalog.logInspector.modelBinding.workerTier == .standard)
        #expect(AgentSubagentProfileCatalog.reader.modelBinding.workerTier == .standard)
        #expect(AgentSubagentProfileCatalog.editor.modelBinding.workerTier == .standard)
        #expect(AgentSubagentProfileCatalog.buildFixer.modelBinding.workerTier == .standard)
        #expect(AgentSubagentProfileCatalog.testFixer.modelBinding.workerTier == .standard)
        #expect(AgentSubagentProfileCatalog.implementer.modelBinding.workerTier == .advanced)
        #expect(!AgentSubagentProfileCatalog.builtIn.contains {
            $0.modelBinding.contextWindowTokens == 16_384
        })
    }

    @Test("built-in worker scheduling never asks while exact operations commands still do")
    func workerSchedulingDoesNotCreateApprovalFriction() async {
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
        #expect(strict == .staticAllowlist)

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

        let delegatedCommand: [String: AgentJSONValue] = [
            "profile": .string("ops_runner"),
            "target_command": .string("git push origin main"),
        ]
        let smartCommand = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: delegatedCommand,
            risk: .write,
            rootDirectory: nil,
            approvalMode: .smart
        )
        let strictCommand = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: delegatedCommand,
            risk: .write,
            rootDirectory: nil,
            approvalMode: .requestEveryTime
        )
        let goalCommand = await appState.autoApprovalSource(
            toolName: "spawn_agent",
            arguments: delegatedCommand,
            risk: .write,
            rootDirectory: nil,
            interactionMode: .goal,
            approvalMode: .smart
        )

        #expect(smartCommand == nil)
        #expect(strictCommand == nil)
        #expect(goalCommand == nil)
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
        // that happens to be in it — the profile owns the canonical job text.
        #expect(scoutPrompt.contains(AgentSubagentJobPrompts.scout))
        // The invariants stay regardless of trade.
        #expect(scoutPrompt.contains("READ-ONLY"))
        #expect(scoutPrompt.contains("cannot ask the user"))
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
        let legacyBinding = AgentSubagentProfile.ModelBinding(preferredProviderID: AgentProviderPreset.someIMID)

        let selected = try #require(AgentSubagentProfileCatalog.providerEntry(
            for: legacyBinding,
            in: library
        ))

        #expect(selected.id == active.id)
        #expect(!AgentSubagentProfileCatalog.bindingModelApplies(
            legacyBinding,
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

    // MARK: Generalist utility surface

    @Test("the generalist is a broad catch-all that stays cheaper than deep")
    func generalistFillsTheGapBetweenNarrowTradesAndDeep() {
        let generalist = AgentSubagentProfileCatalog.generalist
        let deep = AgentSubagentProfileCatalog.deep

        // It retains deep's ordinary read surface and adds host integrations.
        #expect(deep.effectiveToolNames().isSubset(of: generalist.effectiveToolNames()))
        // ...on a smaller window, and without deep's 1M ticket.
        #expect(generalist.modelBinding.workerTier == .standard)
        #expect(deep.modelBinding.workerTier == .expert)
        // Pinned, not nil: a nil model resolves to the provider's primary,
        // i.e. the parent's own tier, which would make this no cheaper.
        #expect(AgentWorkerTierModels.defaultBinding(.standard).model == AgentSubagentModelCompatibility.baseModel)
        // A small model that gives up must still have an exit.
        #expect(generalist.escalation == .retryWithParentModel)
        // Writes stay unavailable until the parent supplies an exact file set.
        #expect(!generalist.requiresWriteAccess)
        #expect(generalist.supportsBoundedWrites)
        #expect(AgentSubagentProfileCatalog.writeToolNames.isSubset(
            of: generalist.effectiveToolNames(writeAccessGranted: true)
        ))
        #expect(AgentSubagentProfileCatalog.terminalOperatorToolNames.isSubset(
            of: generalist.effectiveToolNames()
        ))
        #expect(AgentSubagentProfileCatalog.generalistExtraToolNames.isSubset(
            of: generalist.effectiveToolNames()
        ))
    }

    @Test("scout and reader stay strict while the generalist uses parent review")
    func readingTradesCarryAReadOnlyShell() {
        let strict = AgentSubagentProfileCatalog.strictReadOnlyShellTradeIDs

        for profile in [AgentSubagentProfileCatalog.scout, AgentSubagentProfileCatalog.reader] {
            // The shell is why `ls`/`head` no longer need `ops_runner`.
            #expect(profile.effectiveToolNames().contains("run_command"), "\(profile.id) has no shell")
            // And the strict list is what stops the parent's safety judge from
            // widening that shell into a writing one.
            #expect(strict.contains(profile.id), "\(profile.id) missing from the strict list")
            #expect(!profile.requiresWriteAccess)
        }

        let generalist = AgentSubagentProfileCatalog.generalist
        #expect(generalist.effectiveToolNames().contains("run_command"))
        #expect(!strict.contains(generalist.id))

        // The acting trades stay out of it: judged escalation is their job.
        #expect(!strict.contains(AgentSubagentProfileCatalog.opsRunnerID))
        #expect(!strict.contains(AgentSubagentProfileCatalog.deepID))
        #expect(!strict.contains(AgentSubagentProfileCatalog.implementerID))
    }

    @Test("a subagent measures paths against every folder the parent authorized")
    func subagentInheritsTheParentsFolderSet() {
        let primary = URL(fileURLWithPath: "/tmp/willdeep-primary")
        let second = URL(fileURLWithPath: "/tmp/willdeep-second")

        // The bug this guards: the child used to be built with only the
        // primary root, so in a multi-folder project the parent could read the
        // second folder and its own worker could not.
        let inherited = AgentToolContext(
            rootDirectory: primary,
            additionalWorkspaceRoots: [second]
        )
        #expect(inherited.workspaceRoots.contains(second))

        let isolated = AgentToolContext(rootDirectory: primary)
        #expect(!isolated.workspaceRoots.contains(second))
    }

    @Test("a round budget can be tuned but not set to something unrunnable")
    func roundBudgetOverrideIsClamped() {
        let range = AgentProfileCapability.roundBudgetRange
        #expect(AgentProfileCapability.clampRoundBudget(0) == range.lowerBound)
        #expect(AgentProfileCapability.clampRoundBudget(10_000) == range.upperBound)
        #expect(AgentProfileCapability.clampRoundBudget(20) == 20)

        guard let base = AgentProfile.builtIns.first(where: {
            $0.id == AgentSubagentProfileCatalog.generalistID
        }) else {
            Issue.record("generalist is missing from the built-ins")
            return
        }
        // An override reaches the trade the runner actually gets, and an
        // absent one still follows the code default.
        let tuned = AgentProfileOverride(maxRounds: 40).applied(to: base)
        #expect(tuned.capability?.maxRounds == 40)
        #expect(tuned.asSubagentProfile()?.maxRounds == 40)
        #expect(AgentProfileOverride().applied(to: base).capability?.maxRounds
            == base.capability?.maxRounds)

        // The window is an override too, and 1.305 ships the generalist at 256K.
        #expect(base.runtime.modelBinding.workerTier == .standard)
    }

    @Test("agent profiles is a top-level settings group, not a corner of AI")
    func agentProfilesIsAFirstClassSettingsPane() {
        #expect(EditorSettingsTab.subagents.group == .agentProfiles)
        #expect(SettingsGroup.agentProfiles.tabs == [.subagents])
        #expect(SettingsGroup.allCases.contains(.agentProfiles))
        // ...and it left its old home rather than appearing in both.
        #expect(!SettingsGroup.ai.tabs.contains(.subagents))
    }

    @Test("schema exposes six roles while legacy ids still resolve")
    func toolDescriptionListsOnlyPublicTrades() {
        let catalog = AgentSubagentProfileCatalog.toolDescriptionCatalog
        let spawnDescription = AgentToolRegistry.all.first { $0.name == "spawn_agent" }?.description ?? ""
        #expect(spawnDescription.contains("six roles"))
        #expect(spawnDescription.contains("read-only scout"))
        #expect(!spawnDescription.contains("five responsibilities"))

        #expect(AgentSubagentProfileCatalog.publicBuiltIn.map(\.id) == [
            "scout", "generalist", "implementer", "tester", "reviewer", "ops_runner",
        ])
        for profile in AgentSubagentProfileCatalog.publicBuiltIn {
            #expect(catalog.contains("`\(profile.id)`"), "missing \(profile.id)")
        }
        #expect(!catalog.contains("`small_implementer`"))
        #expect(!catalog.contains("`terminal_operator`"))
        #expect(AgentSubagentProfileCatalog.profile(id: "test_fixer").id == "test_fixer")
        #expect(AgentSubagentProfileCatalog.profile(id: "git_detective").id == "git_detective")
        #expect(AgentSubagentProfileCatalog.publicID(for: "test_fixer") == "implementer")
        #expect(AgentSubagentProfileCatalog.publicID(for: "git_detective") == "scout")
    }

    @Test("live profile store advertises public trades but resolves saved specialist ids")
    func profileStoreKeepsLegacyCompatibilityOffCatalog() {
        let advertisedBuiltIns = AgentSubagentProfileStore.resolvedProfiles()
            .filter { AgentSubagentProfileCatalog.isKnown(id: $0.id) }
            .map(\.id)

        #expect(advertisedBuiltIns == AgentSubagentProfileCatalog.publicBuiltIn.map(\.id))
        #expect(AgentSubagentProfileStore.resolvedProfile(id: "small_reviewer").id == "small_reviewer")
        #expect(AgentSubagentProfileStore.resolvedProfile(id: "terminal_operator").id == "terminal_operator")
    }
}
