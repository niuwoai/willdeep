//
//  SomeIMManagedRoutingTests.swift
//  WillDeepTests
//
//  Phase 1 data-model coverage for some.im "省心托管" managed routing:
//  the (domain, tier) → model mapping and its inverse, allowlist /
//  canonicalize, the only-goes-up session floor, and additive decode of
//  the new AgentSession.managedRouting field. All pure/local — no network.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct SomeIMManagedModelMappingTests {

    @Test
    func resolvesEveryDomainAndTierWithoutPlan() {
        #expect(SomeIMManagedModel.resolve(domain: .coding, tier: .low, hasCodingPlan: false) == "someim-code-low")
        #expect(SomeIMManagedModel.resolve(domain: .coding, tier: .high, hasCodingPlan: false) == "someim-code-high")
        #expect(SomeIMManagedModel.resolve(domain: .coding, tier: .premium, hasCodingPlan: false) == "someim-code-premium")
        #expect(SomeIMManagedModel.resolve(domain: .general, tier: .low, hasCodingPlan: false) == "someim-auto-flash")
        #expect(SomeIMManagedModel.resolve(domain: .general, tier: .high, hasCodingPlan: false) == "someim-auto-pro")
        #expect(SomeIMManagedModel.resolve(domain: .general, tier: .premium, hasCodingPlan: false) == "someim-auto-premium")
    }

    @Test
    func resolvesEveryTierToCodingPlanWhenPlanIsActive() {
        #expect(SomeIMManagedModel.resolve(domain: .coding, tier: .low, hasCodingPlan: true) == "someim-coding-plan-low")
        #expect(SomeIMManagedModel.resolve(domain: .coding, tier: .high, hasCodingPlan: true) == "someim-coding-plan-high")
        #expect(SomeIMManagedModel.resolve(domain: .coding, tier: .premium, hasCodingPlan: true) == "someim-coding-plan-premium")
        #expect(SomeIMManagedModel.resolve(domain: .general, tier: .low, hasCodingPlan: true) == "someim-coding-plan-low")
        #expect(SomeIMManagedModel.resolve(domain: .general, tier: .high, hasCodingPlan: true) == "someim-coding-plan-high")
        #expect(SomeIMManagedModel.resolve(domain: .general, tier: .premium, hasCodingPlan: true) == "someim-coding-plan-premium")
    }

    @Test
    func tierInverseMapsKnownModels() {
        #expect(SomeIMManagedModel.tier(of: "someim-coding-plan-low") == .low)
        #expect(SomeIMManagedModel.tier(of: "someim-code-low") == .low)
        #expect(SomeIMManagedModel.tier(of: "someim-auto-flash") == .low)
        #expect(SomeIMManagedModel.tier(of: "someim-coding-plan-high") == .high)
        #expect(SomeIMManagedModel.tier(of: "someim-code-high") == .high)
        #expect(SomeIMManagedModel.tier(of: "someim-auto-pro") == .high)
        #expect(SomeIMManagedModel.tier(of: "someim-coding-plan-premium") == .premium)
        #expect(SomeIMManagedModel.tier(of: "someim-code-premium") == .premium)
        #expect(SomeIMManagedModel.tier(of: "someim-auto-premium") == .premium)
        #expect(SomeIMManagedModel.tier(of: "gpt-4.1") == nil)
    }

    @Test
    func allowlistCoversMainModelsButNotJudge() {
        #expect(SomeIMManagedModel.allowlist.contains("someim-coding-plan-low"))
        #expect(SomeIMManagedModel.allowlist.contains("someim-code-high"))
        #expect(SomeIMManagedModel.allowlist.contains("someim-auto-premium"))
        // The judge is never a turn's main model.
        #expect(!SomeIMManagedModel.allowlist.contains(SomeIMManagedModel.judge))
    }

    @Test
    func capabilityTierIsOrdered() {
        #expect(AgentManagedCapabilityTier.low < .high)
        #expect(AgentManagedCapabilityTier.high < .premium)
        #expect(max(AgentManagedCapabilityTier.high, .low) == .high)
    }
}

@Suite
@MainActor
struct SomeIMManagedFloorTests {

    private func managedRuntime() -> AgentRuntime {
        var session = AgentSession(title: "t")
        session.managedRouting = AgentManagedRoutingState()
        return AgentRuntime(session: session)
    }

    @Test
    func floorOnlyRises() {
        let rt = managedRuntime()
        #expect(rt.managedRouting?.minimumTier == .low)

        #expect(rt.raiseManagedFloor(to: .high, reason: "quality") == true)
        #expect(rt.managedRouting?.minimumTier == .high)

        // A lower/equal tier is ignored — the floor never drops.
        #expect(rt.raiseManagedFloor(to: .low, reason: nil) == false)
        #expect(rt.managedRouting?.minimumTier == .high)
        #expect(rt.raiseManagedFloor(to: .high, reason: nil) == false)
        #expect(rt.managedRouting?.minimumTier == .high)

        #expect(rt.raiseManagedFloor(to: .premium, reason: nil) == true)
        #expect(rt.managedRouting?.minimumTier == .premium)
    }

    @Test
    func resetReturnsToLow() {
        let rt = managedRuntime()
        _ = rt.raiseManagedFloor(to: .premium, reason: "x")
        #expect(rt.managedRouting?.minimumTier == .premium)
        rt.resetManagedFloor()
        #expect(rt.managedRouting?.minimumTier == .low)
        #expect(rt.managedRouting?.lastEscalationReason == nil)
    }

    @Test
    func raiseIsNoopOnNonManagedSession() {
        let rt = AgentRuntime(session: AgentSession(title: "plain"))
        #expect(rt.managedRouting == nil)
        #expect(rt.raiseManagedFloor(to: .high, reason: nil) == false)
        #expect(rt.managedRouting == nil)
    }
}

@Suite
struct AgentSessionManagedRoutingDecodeTests {

    @Test
    func roundTripsManagedRouting() throws {
        var session = AgentSession(title: "t")
        session.managedRouting = AgentManagedRoutingState(
            minimumTier: .high,
            lastSelectedModel: "someim-coding-plan-high"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(decoded.managedRouting?.minimumTier == .high)
        #expect(decoded.managedRouting?.lastSelectedModel == "someim-coding-plan-high")
    }

    @Test
    func legacySessionWithoutFieldDecodesToNil() throws {
        let session = AgentSession(title: "legacy")
        let data = try JSONEncoder().encode(session)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "managedRouting")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: stripped)
        #expect(decoded.managedRouting == nil)
    }
}

@Suite
struct SomeIMRouteJudgeParsingTests {

    @Test
    func parsesCleanJSON() {
        let raw = #"{"domain":"coding","complexity":"high","target_model":null,"confidence":0.9,"reason":"multi-file"}"#
        let verdict = SomeIMManagedRouting.decodeVerdict(fromRaw: raw)
        #expect(verdict?.domain == .coding)
        #expect(verdict?.complexity == .high)
        #expect(verdict?.confidence == 0.9)
    }

    @Test
    func parsesJSONWrappedInMarkdownFence() {
        let raw = "```json\n{\"domain\":\"general\",\"complexity\":\"low\",\"confidence\":0.7}\n```"
        let verdict = SomeIMManagedRouting.decodeVerdict(fromRaw: raw)
        #expect(verdict?.domain == .general)
        #expect(verdict?.complexity == .low)
        // Missing target_model / reason are tolerated.
        #expect(verdict?.targetModel == nil)
    }

    @Test
    func dropsNonAllowlistedTargetModel() {
        let raw = #"{"domain":"coding","complexity":"low","target_model":"gpt-5.5","confidence":0.8}"#
        let verdict = SomeIMManagedRouting.decodeVerdict(fromRaw: raw)
        #expect(verdict?.targetModel == nil)
    }

    @Test
    func rejectsGarbage() {
        #expect(SomeIMManagedRouting.decodeVerdict(fromRaw: "not json at all") == nil)
        #expect(SomeIMManagedRouting.decodeVerdict(fromRaw: "") == nil)
        // Unknown enum value → nil.
        #expect(SomeIMManagedRouting.decodeVerdict(fromRaw: #"{"domain":"math","complexity":"low","confidence":1}"#) == nil)
    }
}

@Suite
struct SomeIMRouteResolutionTests {

    @Test
    func mergesVerdictWithFloorOnlyUp() {
        // Judge says coding-low, but the session floor is high → code-high.
        let verdict = SomeIMRouteJudgeVerdict(domain: .coding, complexity: .low, confidence: 0.9)
        let res = SomeIMManagedRouting.resolution(
            for: verdict,
            floor: .high,
            usedFallback: false,
            hasCodingPlan: false
        )
        #expect(res.effectiveTier == .high)
        #expect(res.model == "someim-code-high")
    }

    @Test
    func lowConfidenceEscalatesOneStep() {
        let verdict = SomeIMRouteJudgeVerdict(domain: .coding, complexity: .low, confidence: 0.2)
        let res = SomeIMManagedRouting.resolution(
            for: verdict,
            floor: .low,
            usedFallback: false,
            hasCodingPlan: false
        )
        #expect(res.effectiveTier == .high)
        #expect(res.model == "someim-code-high")
    }

    @Test
    func generalLowUsesAutoFlashWithoutPlan() {
        let verdict = SomeIMRouteJudgeVerdict(domain: .general, complexity: .low, confidence: 0.9)
        let res = SomeIMManagedRouting.resolution(
            for: verdict,
            floor: .low,
            usedFallback: false,
            hasCodingPlan: false
        )
        #expect(res.model == "someim-auto-flash")
    }

    @Test
    func planUsesCodingPlanEvenForGeneralDomain() {
        let verdict = SomeIMRouteJudgeVerdict(domain: .general, complexity: .low, confidence: 0.9)
        let res = SomeIMManagedRouting.resolution(
            for: verdict,
            floor: .high,
            usedFallback: false,
            hasCodingPlan: true
        )
        #expect(res.model == "someim-coding-plan-high")
    }

    @Test
    func fallbackHeuristicPrefersCodingHighForCodeContext() {
        let input = SomeIMRouteJudgeInput(latestUserMessage: "帮我重构这个函数", workspaceAvailable: true)
        let verdict = SomeIMManagedRouting.fallbackVerdict(for: input)
        #expect(verdict.domain == .coding)
        #expect(verdict.complexity == .high)
    }

    @Test
    func fallbackHeuristicGeneralForChitchat() {
        let input = SomeIMRouteJudgeInput(latestUserMessage: "今天天气不错")
        let verdict = SomeIMManagedRouting.fallbackVerdict(for: input)
        #expect(verdict.domain == .general)
        #expect(verdict.complexity == .low)
    }
}

@Suite
struct SomeIMRouteOrchestrationTests {

    @Test
    func usesJudgeVerdictWhenParseable() async {
        let input = SomeIMRouteJudgeInput(latestUserMessage: "hi")
        let res = await SomeIMManagedRouting.route(input: input, floor: .low, hasCodingPlan: false) { _, _, _ in
            #"{"domain":"coding","complexity":"high","confidence":0.9}"#
        }
        #expect(res.usedFallback == false)
        #expect(res.model == "someim-code-high")
    }

    @Test
    func activePlanRoutesJudgeVerdictToCodingPlanFamily() async {
        let input = SomeIMRouteJudgeInput(latestUserMessage: "hi")
        let res = await SomeIMManagedRouting.route(input: input, floor: .low, hasCodingPlan: true) { _, _, _ in
            #"{"domain":"general","complexity":"high","confidence":0.9}"#
        }
        #expect(res.usedFallback == false)
        #expect(res.model == "someim-coding-plan-high")
    }

    @Test
    func fallsBackWhenJudgeReturnsNil() async {
        let input = SomeIMRouteJudgeInput(latestUserMessage: "写代码 fix bug", workspaceAvailable: true)
        let res = await SomeIMManagedRouting.route(input: input, floor: .low, hasCodingPlan: false) { _, _, _ in nil }
        #expect(res.usedFallback == true)
        #expect(res.model == "someim-code-high")
    }

    @Test
    func fallbackDoesNotDropBelowFloor() async {
        // Even a general fallback must respect an existing premium floor.
        let input = SomeIMRouteJudgeInput(latestUserMessage: "hello")
        let res = await SomeIMManagedRouting.route(input: input, floor: .premium, hasCodingPlan: false) { _, _, _ in nil }
        #expect(res.usedFallback == true)
        #expect(res.effectiveTier == .premium)
        #expect(res.model == "someim-auto-premium")
    }
}

@Suite(.serialized)
struct AgentWorkspaceIdentityStoreTests {

    private func freshStore() {
        let suite = UserDefaults(suiteName: "test.workspace.identity.\(UUID().uuidString)")!
        AgentWorkspaceIdentityStore.defaults = suite
    }

    @Test
    func stableForSameKeyDistinctForDifferent() {
        freshStore()
        let a1 = AgentWorkspaceIdentityStore.workspaceID(forWorkspaceKey: "/Users/x/proj-a")
        let a2 = AgentWorkspaceIdentityStore.workspaceID(forWorkspaceKey: "/Users/x/proj-a")
        let b = AgentWorkspaceIdentityStore.workspaceID(forWorkspaceKey: "/Users/x/proj-b")
        #expect(a1 != nil)
        #expect(a1 == a2)
        #expect(a1 != b)
        // Sent value is a UUID, never a path.
        #expect(a1.flatMap { UUID(uuidString: $0) } != nil)
        #expect(a1?.contains("/") == false)
    }

    @Test
    func nilForNoWorkspace() {
        freshStore()
        #expect(AgentWorkspaceIdentityStore.workspaceID(forWorkspaceKey: "") == nil)
        #expect(AgentWorkspaceIdentityStore.workspaceID(forWorkspaceKey: AgentSession.noWorkspaceSidebarGroupKey) == nil)
    }
}

@Suite
struct SomeIMEscalationTests {

    @Test
    func escalationLadder() {
        #expect(SomeIMManagedModel.escalated(from: "someim-coding-plan-low") == "someim-coding-plan-high")
        #expect(SomeIMManagedModel.escalated(from: "someim-coding-plan-high") == "someim-coding-plan-premium")
        #expect(SomeIMManagedModel.escalated(from: "someim-coding-plan-premium") == nil)
        #expect(SomeIMManagedModel.escalated(from: "someim-code-low") == "someim-code-high")
        #expect(SomeIMManagedModel.escalated(from: "someim-code-high") == "someim-code-premium")
        #expect(SomeIMManagedModel.escalated(from: "someim-code-premium") == nil)
        #expect(SomeIMManagedModel.escalated(from: "someim-auto-flash") == "someim-auto-pro")
        #expect(SomeIMManagedModel.escalated(from: "someim-auto-pro") == "someim-auto-premium")
        #expect(SomeIMManagedModel.escalated(from: "someim-auto-premium") == nil)
    }
}

@Suite
struct SomeIMOutputQualityTests {

    private func repeatedText() -> String {
        let line = "重复内容重复内容重复内容重复内容"
        return Array(repeating: line, count: 8).joined(separator: "\n")
    }

    @Test
    func detectsEmpty() {
        #expect(SomeIMManagedRouting.detectDeterministicFailure(assistantText: "   \n  ") == "empty_output")
    }

    @Test
    func detectsRepetitionLoop() {
        #expect(SomeIMManagedRouting.detectDeterministicFailure(assistantText: repeatedText()) == "repetition_loop")
    }

    @Test
    func ignoresNormalText() {
        #expect(SomeIMManagedRouting.detectDeterministicFailure(assistantText: "这是一段正常的回答，没有异常重复内容。") == nil)
    }

    @Test
    func judgeFailTriggersRetry() async {
        let decision = await SomeIMManagedRouting.outputQuality(
            assistantText: "some answer text that is long enough to look real",
            reasoningText: nil,
            latestUserMessage: "q",
            model: "someim-coding-plan-low",
            finishReason: "stop"
        ) { _, _, _ in
            #"{"verdict":"fail","failure_type":"garbled_output","confidence":0.9,"should_retry":true}"#
        }
        #expect(decision.shouldRetry == true)
        #expect(decision.failureType == "garbled_output")
    }

    @Test
    func judgePassNoRetry() async {
        let decision = await SomeIMManagedRouting.outputQuality(
            assistantText: "clean answer",
            reasoningText: nil,
            latestUserMessage: "q",
            model: "someim-coding-plan-low",
            finishReason: "stop"
        ) { _, _, _ in
            #"{"verdict":"pass","failure_type":"none","confidence":0.9,"should_retry":false}"#
        }
        #expect(decision.shouldRetry == false)
    }

    @Test
    func localRepetitionOverridesJudgePass() async {
        let decision = await SomeIMManagedRouting.outputQuality(
            assistantText: repeatedText(),
            reasoningText: nil,
            latestUserMessage: "q",
            model: "someim-coding-plan-low",
            finishReason: "stop"
        ) { _, _, _ in
            #"{"verdict":"pass","should_retry":false}"#
        }
        #expect(decision.shouldRetry == true)
        #expect(decision.failureType == "repetition_loop")
    }

    @Test
    func judgeUnavailableRetriesOnStrongLocalSignal() async {
        let decision = await SomeIMManagedRouting.outputQuality(
            assistantText: repeatedText(),
            reasoningText: nil,
            latestUserMessage: "q",
            model: "someim-coding-plan-low",
            finishReason: "stop"
        ) { _, _, _ in nil }
        #expect(decision.shouldRetry == true)
    }

    @Test
    func judgeUnavailableNoRetryOnCleanOutput() async {
        let decision = await SomeIMManagedRouting.outputQuality(
            assistantText: "clean normal answer text",
            reasoningText: nil,
            latestUserMessage: "q",
            model: "someim-coding-plan-low",
            finishReason: "stop"
        ) { _, _, _ in nil }
        #expect(decision.shouldRetry == false)
    }
}

@Suite
struct AgentManagedRouteDecisionTests {

    @Test
    func tierMarkers() {
        let base = AgentManagedRouteDecision(
            selectedModel: "someim-coding-plan-high", tier: .high,
            domain: .coding, complexity: .high, didFallback: false
        )
        #expect(base.tierMarkers == "High")

        var escalated = base
        escalated.didEscalate = true
        #expect(escalated.tierMarkers == "High↑")

        let fallback = AgentManagedRouteDecision(
            selectedModel: "someim-auto-flash", tier: .low,
            domain: .general, complexity: .low, didFallback: true
        )
        #expect(fallback.tierMarkers == "Low~")
    }

    @Test
    func decodesOnAssistantMessage() throws {
        var message = AgentMessage(role: .assistant, content: "hi")
        message.managedRoute = AgentManagedRouteDecision(
            selectedModel: "someim-coding-plan-high", tier: .high,
            domain: .coding, complexity: .high, didFallback: false,
            didEscalate: true, failureType: "repetition_loop"
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        #expect(decoded.managedRoute?.selectedModel == "someim-coding-plan-high")
        #expect(decoded.managedRoute?.tier == .high)
        #expect(decoded.managedRoute?.didEscalate == true)
        #expect(decoded.managedRoute?.failureType == "repetition_loop")
    }

    @Test
    func legacyMessageDecodesToNilManagedRoute() throws {
        let message = AgentMessage(role: .assistant, content: "hi")
        let data = try JSONEncoder().encode(message)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "managedRoute")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: stripped)
        #expect(decoded.managedRoute == nil)
    }
}
