//
//  AgentWorkerRoutingModelTests.swift
//  XeditTests
//
//  模型派发判决层：阈值、解析、合并。
//

import Testing
@testable import WillDeep

@Suite("Worker routing model")
struct AgentWorkerRoutingModelTests {

    // MARK: - 何时才问模型

    @Test
    func keywordMatchesAreTrustedWithoutConsultingModel() {
        // 匹配到关键词的分支一律 86 分以上，直接采信，不付模型延迟。
        let terminal = AgentRequestRouter.classify("看一下终端里在跑什么")
        #expect(terminal.confidence >= AgentWorkerRoutingModel.keywordTrustThreshold)
        #expect(!AgentWorkerRoutingModel.shouldConsultModel(for: terminal))

        let deploy = AgentRequestRouter.classify("部署到生产环境")
        #expect(!AgentWorkerRoutingModel.shouldConsultModel(for: deploy))
    }

    @Test
    func fallbackBranchesAreEscalatedToModel() {
        // 兜底只有两档：implementer(78) 与「什么都不匹配」(70)。
        let ambiguous = AgentRequestRouter.classify("这个需求要不要做，你看着办")
        #expect(ambiguous.confidence < AgentWorkerRoutingModel.keywordTrustThreshold)
        #expect(AgentWorkerRoutingModel.shouldConsultModel(for: ambiguous))
    }

    // MARK: - 解析

    @Test
    func parsesPlainVerdict() {
        let verdict = AgentWorkerRoutingModel.parseVerdict(#"{"worker":"build_fixer","confidence":91}"#)
        #expect(verdict?.profileID == "build_fixer")
        #expect(verdict?.confidence == 91)
    }

    @Test
    func parsesFencedVerdict() {
        // 本地模型即便被要求只输出 JSON 也常包一层 ```json 围栏。
        let raw = """
        ```json
        {"worker": "scout", "confidence": 88}
        ```
        """
        #expect(AgentWorkerRoutingModel.parseVerdict(raw)?.profileID == "scout")
    }

    @Test
    func parsesNoneAsNoProfile() {
        let verdict = AgentWorkerRoutingModel.parseVerdict(#"{"worker":"none","confidence":40}"#)
        #expect(verdict != nil)
        #expect(verdict?.profileID == nil)
    }

    @Test
    func rejectsEmptyContent() {
        // gemma4:e4b-it-qat 查不到答案时返回空串（eval_count=1，直接 EOS）。
        #expect(AgentWorkerRoutingModel.parseVerdict("") == nil)
        #expect(AgentWorkerRoutingModel.parseVerdict("   \n  ") == nil)
    }

    @Test
    func rejectsUnknownProfileID() {
        #expect(AgentWorkerRoutingModel.parseVerdict(#"{"worker":"database_admin","confidence":99}"#) == nil)
    }

    @Test
    func rejectsMalformedAndTruncatedBodies() {
        #expect(AgentWorkerRoutingModel.parseVerdict("好的，我认为应该用 build_fixer") == nil)
        #expect(AgentWorkerRoutingModel.parseVerdict(#"{"worker":"build_fixer","confidence":"#) == nil)
        #expect(AgentWorkerRoutingModel.parseVerdict(#"{"confidence":90}"#) == nil)
    }

    @Test
    func toleratesFloatConfidence() {
        let verdict = AgentWorkerRoutingModel.parseVerdict(#"{"worker":"tester","confidence":0.9}"#)
        #expect(verdict?.profileID == "tester")
    }

    // MARK: - 合并

    @Test
    func mergeReplacesProfileButKeepsSafetyFlags() {
        // 模型只换 trade，不得把一个会改文件的请求变成可自动派发。
        let keyword = AgentRequestRouter.classify("重构一下这几个文件的结构")
        let verdict = AgentWorkerRoutingModel.Verdict(profileID: "implementer", confidence: 90)
        let merged = AgentWorkerRoutingModel.merged(keyword: keyword, verdict: verdict)

        #expect(merged.profileID == "implementer")
        #expect(merged.autoDispatchEligible == keyword.autoDispatchEligible)
        #expect(merged.requiresDelegatedExecution == keyword.requiresDelegatedExecution)
        #expect(merged.tier == keyword.tier)
    }

    @Test
    func mergeKeepsKeywordDecisionWhenModelDeclines() {
        let keyword = AgentRequestRouter.classify("这个需求要不要做，你看着办")
        let verdict = AgentWorkerRoutingModel.Verdict(profileID: nil, confidence: 30)
        let merged = AgentWorkerRoutingModel.merged(keyword: keyword, verdict: verdict)
        #expect(merged == keyword)
    }

    // MARK: - 候选表

    @Test
    func candidateIDsAreKnownProfilesAndUnique() {
        let ids = AgentWorkerRoutingModel.candidates.map(\.id)
        #expect(Set(ids).count == ids.count)
        // 升级目标不该出现在候选里——它们由别的机制选中，不是新请求的落点。
        #expect(!ids.contains(AgentSubagentProfileCatalog.judgeID))
        #expect(!ids.contains(AgentSubagentProfileCatalog.securityGuardID))
        #expect(!ids.contains(AgentSubagentProfileCatalog.smallImplementerID))
    }

    @Test
    func systemPromptListsEveryCandidateAndNone() {
        let prompt = AgentWorkerRoutingModel.systemPrompt()
        for candidate in AgentWorkerRoutingModel.candidates {
            #expect(prompt.contains(candidate.id))
        }
        #expect(prompt.contains(AgentWorkerRoutingModel.noneChoice))
    }

    @Test
    func userPromptTruncatesToClassifiedWindow() {
        let long = String(repeating: "字", count: 5_000)
        let prompt = AgentWorkerRoutingModel.userPrompt(for: long)
        #expect(prompt.count < AgentWorkerRoutingModel.classifiedPrefixLength + 32)
    }
}

@Suite("Local model worker routing settings")
struct AgentLocalModelWorkerRoutingSettingsTests {

    @Test
    func routingReusesSummaryModelAndHasNoSeparateField() {
        // 刻意共用一个模型：本机一次只驻留一个，分开填会来回换装。
        var settings = AgentLocalModelSettings.default
        settings.enabled = true
        settings.summaryModel = "gemma4:e4b-it-qat"
        settings.preferForWorkerRouting = true

        let configuration = settings.normalized.configuration(model: settings.normalized.summaryModel)
        #expect(configuration.model == "gemma4:e4b-it-qat")
    }

    @Test
    func workerRoutingPreferenceRoundTripsThroughCoding() throws {
        var settings = AgentLocalModelSettings.default
        settings.preferForWorkerRouting = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentLocalModelSettings.self, from: data)
        #expect(decoded.preferForWorkerRouting == false)
    }

    @Test
    func legacySettingsWithoutTheKeyDefaultToEnabled() throws {
        // 老配置里没有这个字段，应当取默认值（开），而不是解码失败或默认关。
        let json = """
        {"enabled":true,"baseURL":"http://127.0.0.1:11434/v1",
         "visionModel":"gemma4:e2b-it-qat","summaryModel":"gemma4:e2b-it-qat",
         "preferForImageUnderstanding":true,"preferForTitles":true,
         "preferForContextSummaries":false,"exposeAsComposerModel":false,
         "composerDisplayName":"Local Chat (Ollama)"}
        """
        let decoded = try JSONDecoder().decode(
            AgentLocalModelSettings.self,
            from: Data(json.utf8)
        )
        #expect(decoded.preferForWorkerRouting == AgentLocalModelSettings.defaultPreferForWorkerRouting)
    }
}
