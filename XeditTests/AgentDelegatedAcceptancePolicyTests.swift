//
//  AgentDelegatedAcceptancePolicyTests.swift
//  WillDeepTests
//
//  哪些消息该带验收合同。
//
//  这组用例来自一个真实故障：委派执行器打开时，一句「hello」被套上四条款
//  的验收合同交给 Claude Code，它去翻工作区，翻完无可奉告，五分半之后
//  验收层报出六条问题（没有证据块 + AC-01..04 缺证据 + 复跑失败）。
//
//  判据的方向性是这组用例的重点：漏判只是多套一次合同，慢一点但结果照旧
//  正确；误判是把一次真改动放过了验收。所以「拿不准算任务」那几条比
//  「问候算闲聊」那几条更要紧。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentDelegatedAcceptancePolicyTests {
    private func requiresAcceptance(_ text: String, attachments: Bool = false) -> Bool {
        AgentDelegatedAcceptancePolicy.requiresAcceptance(userText: text, hasAttachments: attachments)
    }

    @Test
    func greetingsAndPleasantriesSkipTheContract() {
        for text in [
            "hello", "Hello!", "hi", "Hey", "yo",
            "你好", "你好啊", "您好", "嗨", "哈喽", "在吗", "早上好", "晚上好",
            "谢谢", "谢谢你", "多谢", "thanks", "Thank you", "thx",
            "再见", "拜拜", "bye", "晚安",
            "厉害", "牛", "干得好", "nice", "Perfect!",
        ] {
            #expect(!requiresAcceptance(text), "「\(text)」不该带验收合同")
        }
    }

    /// 审批词一律算任务。
    ///
    /// 在这个产品里「好的」「可以」几乎总是「照你刚才说的做」，把它们
    /// 当闲聊放过去，等于把一次真正的交付漏掉验收——那是这道闸唯一
    /// 承受不起的错误方向。
    @Test
    func approvalsAreTreatedAsTasks() {
        for text in ["好的", "好", "可以", "嗯", "收到", "明白", "行", "ok", "okay", "go ahead", "继续", "接着做"] {
            #expect(requiresAcceptance(text), "「\(text)」是审批，必须按任务处理")
        }
    }

    /// 「测试」可能是让你跑测试，不是寒暄。
    @Test
    func ambiguousShortWordsStayTasks() {
        for text in ["测试", "试试", "test", "跑一下", "看看", "查一下", "改一下"] {
            #expect(requiresAcceptance(text), "「\(text)」含义不明，必须按任务处理")
        }
    }

    @Test
    func anythingPointingAtTheWorkspaceIsATask() {
        for text in [
            "Xedit/AppState.swift",
            "看 @tools",
            "```swift",
            "https://example.com",
            "修 #123",
        ] {
            #expect(requiresAcceptance(text), "「\(text)」指向工作区，必须按任务处理")
        }
    }

    @Test
    func lengthAndShapeFallBackToTask() {
        // 多行几乎总是贴了日志、代码或一串要求
        #expect(requiresAcceptance("你好\n顺便把测试跑一下"))
        // 超过上限就不再当寒暄，白名单不必去穷举加长写法
        #expect(requiresAcceptance("你好你好你好你好你好你好你好你好你好"))
        // 空输入按任务处理：这不是正常路径，宁可多跑一遍
        #expect(requiresAcceptance("   "))
    }

    @Test
    func attachmentsAlwaysMeanWork() {
        // 带了图片或技能就是有活要干，哪怕正文只写了「你好」
        #expect(requiresAcceptance("你好", attachments: true))
    }
}

@Suite
struct AgentDelegatedConversationalContractTests {
    private func contract(requiresAcceptance: Bool) -> AgentDelegatedTaskContract {
        AgentDelegatedTaskControl.makeContract(
            objective: "hello",
            executor: .claudeCode,
            goal: nil,
            requiresAcceptanceEvidence: requiresAcceptance
        )
    }

    @Test
    func aConversationalContractIssuesNoCriteriaAndNoRetry() {
        let conversational = contract(requiresAcceptance: false)
        // 留着空壳条款只会让后面每一层都得记得跳过它们
        #expect(conversational.acceptanceCriteria.isEmpty)
        #expect(conversational.verificationCommands.isEmpty)
        // 第一次没交付什么，第二次也不会
        #expect(conversational.maxAttempts == 1)
        #expect(!conversational.requiresFreshSelfReview)
        #expect(!conversational.requiresWillDeepVerification)

        let task = contract(requiresAcceptance: true)
        #expect(task.acceptanceCriteria.count == 4)
        #expect(task.requiresFreshSelfReview)
    }

    @Test
    func theExecutorIsNotAskedForAnEvidenceBlock() {
        let instructions = AgentDelegatedTaskControl.executorInstructions(
            contract: contract(requiresAcceptance: false)
        )
        #expect(!instructions.contains(AgentDelegatedTaskControl.evidenceStartMarker))
        #expect(!instructions.contains("AC-01"))
    }

    /// 这条直接钉住原故障：同样的输入，此前产出六条问题。
    @Test
    func aConversationalTurnIsAcceptedWithoutEvidence() {
        let acceptance = AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract(requiresAcceptance: false),
            evidence: nil,
            changedPaths: [],
            rerunChecks: []
        )
        #expect(acceptance.accepted)
        #expect(acceptance.findings.isEmpty)

        // 对照组：同样没有证据块，但这是一件任务，就该报问题
        let strict = AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract(requiresAcceptance: true),
            evidence: nil,
            changedPaths: [],
            rerunChecks: []
        )
        #expect(!strict.accepted)
        #expect(strict.findings.count >= 5)
    }
}
