//
//  AgentWorkerRoutingContractTests.swift
//  XeditTests
//
//  双端路由契约守卫。
//
//  派发判决在 Xedit(Swift) 与 willdeep-rs(Rust) 各实现一遍。阈值、超时、
//  候选清单、模型能改什么这些参数曾经是两边各写一份、谁也不知道对方——
//  实测就漂过：rs 有 8 个候选，Swift 有 12 个，其中两个还是特权目的地。
//
//  `docs/WORKER_ROUTING_CONTRACT.json` 是唯一事实来源，rs 侧镜像同一份。
//  这个 suite 对着它断言 Swift 实现；rs 侧有对应的 Rust 守卫。改代码不改
//  契约、或改契约不改代码，都会在这里红。
//
//  它不能阻止两份 JSON 自己漂开——那需要跨仓库 CI。但它把静默漂移变成
//  至少一侧的红灯，这是单仓库测试能做到的上限。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Worker routing cross-repo contract")
struct AgentWorkerRoutingContractTests {

    // MARK: - 契约加载

    struct Contract: Decodable {
        struct Profile: Decodable {
            let id: String
            let purpose: String
        }
        struct Excluded: Decodable {
            let id: String
            let reason: String
        }
        let schema: String
        let keywordTrustThreshold: Int
        let classifierTimeoutSeconds: Int
        let classifiedPrefixChars: Int
        let confidenceMin: Int
        let confidenceMax: Int
        let noneChoice: String
        let verdictFormatLine: String
        let routableProfiles: [Profile]
        let excludedProfiles: [Excluded]
        let modelMayOverride: [String]
        let modelMustNotOverride: [String]

        enum CodingKeys: String, CodingKey {
            case schema
            case keywordTrustThreshold = "keyword_trust_threshold"
            case classifierTimeoutSeconds = "classifier_timeout_seconds"
            case classifiedPrefixChars = "classified_prefix_chars"
            case confidenceMin = "confidence_min"
            case confidenceMax = "confidence_max"
            case noneChoice = "none_choice"
            case verdictFormatLine = "verdict_format_line"
            case routableProfiles = "routable_profiles"
            case excludedProfiles = "excluded_profiles"
            case modelMayOverride = "model_may_override"
            case modelMustNotOverride = "model_must_not_override"
        }
    }

    /// 从源码位置往上找仓库根，避免依赖测试 bundle 资源打包。
    static func loadContract() throws -> Contract {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("docs")
                .appendingPathComponent("WORKER_ROUTING_CONTRACT.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: candidate))
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ContractError.notFound
    }

    enum ContractError: Error { case notFound }

    // MARK: - 标量参数

    @Test
    func thresholdMatchesContract() throws {
        let contract = try Self.loadContract()
        #expect(contract.schema == "willdeep.worker-routing.v1")
        #expect(AgentWorkerRoutingModel.keywordTrustThreshold == contract.keywordTrustThreshold)
    }

    @Test
    func timeoutAndPrefixMatchContract() throws {
        let contract = try Self.loadContract()
        #expect(Int(AgentWorkerRoutingModel.timeout) == contract.classifierTimeoutSeconds)
        #expect(AgentWorkerRoutingModel.classifiedPrefixLength == contract.classifiedPrefixChars)
    }

    @Test
    func noneChoiceMatchesContract() throws {
        let contract = try Self.loadContract()
        #expect(AgentWorkerRoutingModel.noneChoice == contract.noneChoice)
    }

    // MARK: - 候选清单

    @Test
    func candidateIDsMatchContractExactlyAndInOrder() throws {
        let contract = try Self.loadContract()
        let contractIDs = contract.routableProfiles.map(\.id)
        let codeIDs = AgentWorkerRoutingModel.candidates.map(\.id)
        #expect(codeIDs == contractIDs)
    }

    @Test
    func candidatePurposesMatchContractVerbatim() throws {
        let contract = try Self.loadContract()
        for profile in contract.routableProfiles {
            let match = AgentWorkerRoutingModel.candidates.first { $0.id == profile.id }
            #expect(match?.purpose == profile.purpose, "purpose drift for \(profile.id)")
        }
    }

    /// 特权目的地不得出现在模型菜单里。ops_runner 会部署生产、
    /// terminal_operator 会操作用户终端，两者关键词分支都是 94 分，
    /// 本来就轮不到模型；放进菜单等于开一条「请求含糊 → 小模型猜 →
    /// 生产运维」的路径。
    @Test
    func excludedProfilesAreAbsentFromMenu() throws {
        let contract = try Self.loadContract()
        let codeIDs = Set(AgentWorkerRoutingModel.candidates.map(\.id))
        for excluded in contract.excludedProfiles {
            #expect(!codeIDs.contains(excluded.id), "\(excluded.id) 不该可被模型选中：\(excluded.reason)")
        }
    }

    @Test
    func privilegedDestinationsStayOffTheMenu() {
        let codeIDs = Set(AgentWorkerRoutingModel.candidates.map(\.id))
        #expect(!codeIDs.contains(AgentSubagentProfileCatalog.opsRunnerID))
        #expect(!codeIDs.contains(AgentSubagentProfileCatalog.terminalOperatorID))
    }

    // MARK: - 提示词

    @Test
    func systemPromptCarriesContractFormatLine() throws {
        let contract = try Self.loadContract()
        let prompt = AgentWorkerRoutingModel.systemPrompt()
        // 没有这行，本地模型会改吐 {"category":...}/{"task":...}，解析器
        // 认不出就永远静默回落，功能等于没上线。
        #expect(prompt.contains(contract.verdictFormatLine))
    }

    // MARK: - 合并边界

    @Test
    func confidenceIsClampedToContractRange() throws {
        let contract = try Self.loadContract()
        let high = AgentWorkerRoutingModel.parseVerdict(
            #"{"worker":"scout","confidence":9999}"#
        )
        #expect(high?.confidence == contract.confidenceMax)

        let low = AgentWorkerRoutingModel.parseVerdict(
            #"{"worker":"scout","confidence":-5}"#
        )
        #expect(low?.confidence == contract.confidenceMin)
    }

    /// 契约规定模型只能改 profile_id。逐个字段钉住其余的不变。
    @Test
    func mergeOverridesOnlyProfileID() throws {
        let contract = try Self.loadContract()
        #expect(contract.modelMayOverride == ["profile_id"])

        let keyword = AgentRequestRouter.classify("重构一下这几个文件的结构")
        let verdict = AgentWorkerRoutingModel.Verdict(profileID: "scout", confidence: 95)
        let merged = AgentWorkerRoutingModel.merged(keyword: keyword, verdict: verdict)

        #expect(merged.profileID == "scout")
        for field in contract.modelMustNotOverride {
            switch field {
            case "tier":
                #expect(merged.tier == keyword.tier)
            case "confidence":
                #expect(merged.confidence == keyword.confidence)
            case "auto_dispatch_eligible":
                #expect(merged.autoDispatchEligible == keyword.autoDispatchEligible)
            case "requires_delegated_execution":
                #expect(merged.requiresDelegatedExecution == keyword.requiresDelegatedExecution)
            case "preflight_profile_id":
                #expect(merged.preflightProfileID == keyword.preflightProfileID)
            default:
                Issue.record("契约里出现了守卫没覆盖的字段：\(field)")
            }
        }
    }
}
