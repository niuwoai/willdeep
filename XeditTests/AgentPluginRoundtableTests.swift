//
//  AgentPluginRoundtableTests.swift
//  WillDeepTests
//
//  插件自带专家席的圆桌(1.412.0-rc1):反向请求 `willdeep/roundtable/run` 的参数校验、
//  席位抽象(内置 / 自带同一条路)、消息与报告对新旧字段的兼容、结论契约提示词。
//  引擎的真实跑法要模型,这里只锁纯函数不变量。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentPluginRoundtableTests {
    private func validParams() -> [String: Any] {
        [
            "title": "第 1 集剧本（专家席）",
            "topic": "【完整剧本】\n许禾：479 只，一只没少。",
            "experts": [
                ["id": "chief", "name": "总策划", "expertise": "弧光与爽点", "persona": "你是总策划。"],
                ["name": "连续性编辑", "role": "设定账本", "persona": "你管前后别打架。"],
            ],
            "chairPersona": "去重、裁决冲突。",
            "verdictInstruction": "只输出一个 ```short_drama_review``` 代码块。",
            "rounds": 2,
            "provider": "dashscope",
            "model": "qwen3.8-max",
        ]
    }

    @Test("合法请求解析出专家席、主持人规则、契约与轮数")
    func validatorAcceptsAFullRequest() throws {
        let request = try AgentPluginRoundtableRequestValidator.request(from: validParams()).get()
        #expect(request.title == "第 1 集剧本（专家席）")
        #expect(request.experts.count == 2)
        #expect(request.experts[0].id == "chief")
        #expect(request.experts[1].id == "expert-2", "没给 id 的专家按序号编")
        #expect(request.experts[1].expertise == "设定账本", "role 也认作职责")
        #expect(request.chairPersona == "去重、裁决冲突。")
        #expect(request.verdictInstruction?.contains("short_drama_review") == true)
        #expect(request.rounds == 2)
        #expect(request.providerID == "dashscope")
        #expect(request.model == "qwen3.8-max")
    }

    @Test("缺标题、缺议题、专家不够、人设过长、轮数越界都当场拒")
    func validatorRejectsBadRequests() {
        var params = validParams()
        params["title"] = " "
        #expect((try? AgentPluginRoundtableRequestValidator.request(from: params).get()) == nil)

        params = validParams()
        params["topic"] = ""
        if case .failure(let error) = AgentPluginRoundtableRequestValidator.request(from: params) {
            #expect(error == .missingTopic)
        } else {
            Issue.record("empty topic accepted")
        }

        params = validParams()
        params["experts"] = [["name": "独苗", "persona": "一个人开不了席。"]]
        if case .failure(let error) = AgentPluginRoundtableRequestValidator.request(from: params) {
            #expect(error == .tooFewExperts)
        } else {
            Issue.record("one expert accepted")
        }

        params = validParams()
        params["experts"] = [
            ["name": "甲", "persona": String(repeating: "长", count: AgentPluginRoundtableRequest.maximumPersonaCharacters + 1)],
            ["name": "乙", "persona": "短"],
        ]
        if case .failure(let error) = AgentPluginRoundtableRequestValidator.request(from: params) {
            #expect(error == .personaTooLong("甲"))
        } else {
            Issue.record("oversized persona accepted")
        }

        params = validParams()
        params["rounds"] = 9
        if case .failure(let error) = AgentPluginRoundtableRequestValidator.request(from: params) {
            #expect(error == .invalidRounds)
        } else {
            Issue.record("rounds 9 accepted")
        }

        params = validParams()
        params["experts"] = [["id": "same", "name": "甲", "persona": "a"], ["id": "same", "name": "乙", "persona": "b"]]
        #expect((try? AgentPluginRoundtableRequestValidator.request(from: params).get()) == nil, "重复 id 要拒")

        params = validParams()
        params.removeValue(forKey: "rounds")
        params.removeValue(forKey: "chairPersona")
        params.removeValue(forKey: "verdictInstruction")
        let minimal = try? AgentPluginRoundtableRequestValidator.request(from: params).get()
        #expect(minimal?.rounds == 1)
        #expect(minimal?.chairPersona == nil)
        #expect(minimal?.verdictInstruction == nil)
    }

    @Test("席位:内置专家按枚举,自带专家带前缀;名字、职责、人设各取各的")
    func seatsCoverBuiltinAndCustom() {
        let custom = RoundtableCustomExpert(id: "chief", name: "总策划", expertise: "弧光与爽点", persona: "你是总策划。")
        let seats: [RoundtableSeat] = [.builtin(.product), .custom(custom)]
        #expect(seats[0].id == AgentRoundtableExpertRole.product.rawValue)
        #expect(seats[1].id == "custom:chief")
        #expect(seats[1].displayName == "总策划")
        #expect(seats[1].roleTitle == "弧光与爽点")
        #expect(seats[1].systemPersona == "你是总策划。")
        #expect(seats[1].avatarInitial == "总")
        #expect(seats[0].systemPersona == AgentRoundtableExpertRole.product.systemPersona)
        #expect(seats[1].builtinRole == nil)
        #expect(seats[0].customExpert == nil)
    }

    @Test("报告的席位表、当前席位与轮数上限")
    func reportSeatsAndLimits() {
        let custom = RoundtableCustomExpert(id: "pace", name: "节奏剪辑师", expertise: "前三秒", persona: "p")
        var report = AgentRoundtableReport(
            topic: "t",
            experts: [.risk],
            customExperts: [custom],
            external: RoundtableExternalRun(pluginID: "willdeep-video-studio", roundLimit: 2)
        )
        #expect(report.seats.map(\.id) == ["risk", "custom:pace"])
        #expect(report.unattended)
        #expect(report.effectiveMaxRounds == 2)
        report.activeCustomExpertID = "pace"
        #expect(report.activeSeatID == "custom:pace")
        #expect(report.activeSeat?.displayName == "节奏剪辑师")
        report.activeCustomExpertID = nil
        report.activeExpert = .risk
        #expect(report.activeSeatID == "risk")

        let plain = AgentRoundtableReport(topic: "t", experts: [.risk, .finance])
        #expect(!plain.unattended)
        #expect(plain.effectiveMaxRounds == AgentRoundtableReport.maxRounds)
        let clamped = AgentRoundtableReport(topic: "t", external: RoundtableExternalRun(pluginID: "p", roundLimit: 99))
        #expect(clamped.effectiveMaxRounds == AgentRoundtableReport.maxRounds)
    }

    @Test("自带专家的消息凭自己就能拼出席位;旧 JSON 没有新字段也照常解码")
    func messagesCarryCustomSeatsAndDecodeOldJSON() throws {
        let message = RoundtableMessage(
            speaker: .expert,
            round: 1,
            content: "第 1 场的 479 只对不上账本。",
            customExpertID: "continuity",
            speakerDisplayName: "连续性编辑",
            speakerRoleTitle: "设定账本"
        )
        #expect(message.seatID == "custom:continuity")
        #expect(message.speakerName == "连续性编辑")
        #expect(message.seat?.roleTitle == "设定账本")
        let report = AgentRoundtableReport(topic: "t", customExperts: [
            RoundtableCustomExpert(id: "continuity", name: "连续性编辑", expertise: "设定账本", persona: "x"),
        ])
        #expect(report.seat(for: message)?.displayName == "连续性编辑")

        let builtin = RoundtableMessage(speaker: .expert, role: .legal, round: 1, content: "x")
        #expect(builtin.seatID == "legal")
        #expect(builtin.seat?.builtinRole == .legal)

        let old = """
        {"id":"8C1A4B7E-0000-4000-8000-000000000001","topic":"旧报告","title":"","phase":"completed","experts":["risk"],
         "messages":[{"id":"8C1A4B7E-0000-4000-8000-000000000002","speaker":"expert","role":"risk","round":1,"content":"旧发言","createdAt":0}],
         "currentRound":1,"converged":true,"createdAt":0,"updatedAt":0}
        """
        let decoded = try JSONDecoder().decode(AgentRoundtableReport.self, from: Data(old.utf8))
        #expect(decoded.customExperts == nil)
        #expect(decoded.external == nil)
        #expect(!decoded.unattended)
        #expect(decoded.seats.map(\.id) == ["risk"])
        #expect(decoded.messages[0].seatID == "risk")

        let encoded = try JSONEncoder().encode(report)
        let roundTripped = try JSONDecoder().decode(AgentRoundtableReport.self, from: encoded)
        #expect(roundTripped.customExperts?.first?.name == "连续性编辑")
    }

    @Test("结论契约提示词带上调用方的主持人规则与契约,议题与记录当惰性数据")
    func verdictPromptCarriesContract() {
        let prompt = AgentRoundtablePromptBuilder.verdict(
            topic: "议题",
            transcript: "[第 1 轮 · 总策划]\n寒暄太长。",
            instruction: "只输出一个 ```short_drama_review``` 代码块。",
            chairPersona: "去重、裁决冲突。"
        )
        #expect(prompt.contains("去重、裁决冲突。"))
        #expect(prompt.contains("short_drama_review"))
        #expect(prompt.contains("<topic>\n议题\n</topic>"))
        #expect(prompt.contains("<transcript>"))
        let opening = AgentRoundtablePromptBuilder.opening(
            topic: "议题",
            seats: [.builtin(.risk), .custom(RoundtableCustomExpert(id: "a", name: "制片", expertise: "镜数与成本", persona: "p"))]
        )
        #expect(opening.contains("制片（镜数与成本）"))
        #expect(opening.contains(AgentRoundtableExpertRole.risk.displayName))
    }

    @Test("宿主对插件宣告圆桌方法,且它的处理上限比别的反向请求长")
    func hostAdvertisesRoundtableWithLongerLimit() {
        #expect(AgentMCPHostRequests.supportedMethods.contains(AgentMCPHostRequests.roundtableRunMethod))
        #expect(AgentMCPHostRequests.handlingLimit(for: ["method": AgentMCPHostRequests.roundtableRunMethod]) == AgentMCPHostRequests.roundtableHandlingSeconds)
        #expect(AgentMCPHostRequests.handlingLimit(for: ["method": AgentMCPHostRequests.aiCompleteMethod]) == AgentMCPHostRequests.maximumHandlingSeconds)
        #expect(AgentMCPHostRequests.roundtableHandlingSeconds > AgentMCPHostRequests.maximumHandlingSeconds)
    }

    @Test("反向请求 willdeep/roundtable/run:参数不合法回 -32602,合法时把结果原样交回")
    func hostRequestRoundTrip() async {
        let server = AgentMCPServerConfig(
            id: "plugin:willdeep-video-studio:video-studio",
            name: "video-studio",
            source: .plugin,
            transport: .stdio,
            command: "/usr/bin/ruby"
        )
        let bad = await AgentMCPHostRequests.respond(
            to: ["jsonrpc": "2.0", "id": "r1", "method": AgentMCPHostRequests.roundtableRunMethod, "params": ["title": "x"]],
            server: server
        )
        #expect((bad["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.invalidParams)

        AgentMCPHostRequests.setRoundtableRunnerForTesting { pluginID, request in
            #expect(pluginID == "willdeep-video-studio")
            #expect(request.experts.count == 2)
            return AgentPluginRoundtableResult(
                reportID: "report-1",
                sessionID: "session-1",
                document: "## 核心结论\n可拍。",
                verdict: "```short_drama_review\n{\"status\":\"pass\",\"issues\":[]}\n```",
                transcript: [AgentPluginRoundtableTranscriptEntry(seatID: "custom:chief", name: "总策划", round: 1, content: "可拍。", stance: "support", isError: false)],
                model: "qwen3.8-max",
                providerID: "dashscope",
                rounds: 1
            )
        }
        defer { AgentMCPHostRequests.setRoundtableRunnerForTesting(nil) }
        let good = await AgentMCPHostRequests.respond(
            to: ["jsonrpc": "2.0", "id": "r2", "method": AgentMCPHostRequests.roundtableRunMethod, "params": validParams()],
            server: server
        )
        let result = good["result"] as? [String: Any]
        #expect(result?["document"] as? String == "## 核心结论\n可拍。")
        #expect((result?["verdict"] as? String)?.contains("short_drama_review") == true)
        #expect((result?["transcript"] as? [[String: Any]])?.first?["name"] as? String == "总策划")
        #expect(result?["model"] as? String == "qwen3.8-max")
    }
}
