//
//  AgentWorkerRoutingVetoTests.swift
//  XeditTests
//
//  独立 @Suite，不挂进 WillDeepTests extension——挂进去 `-only-testing`
//  就选不中，会静默跑 0 个用例还报绿。
//
//  这个 suite 守的不是「否决能用」，而是「否决只能往一个方向用」：模型
//  可以拿走特权，永远不能给出特权。其余用例都在确认各种读不懂的回答都
//  倒向「维持」。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentWorkerRoutingVetoTests {

    // MARK: - 触发条件

    @Test("只有两个特权档值得问模型")
    func onlyPrivilegedRoutesRequestVeto() {
        let ops = AgentRequestRouter.classify("部署到生产环境")
        let terminal = AgentRequestRouter.classify("看看终端里的输出")
        let implementer = AgentRequestRouter.classify("把用户模块重构一下")

        #expect(AgentWorkerRoutingVeto.shouldRequestVeto(for: ops))
        #expect(AgentWorkerRoutingVeto.shouldRequestVeto(for: terminal))
        // implementer 判错只是选了个次优工种，不产生强制后果，不值一次往返。
        #expect(!AgentWorkerRoutingVeto.shouldRequestVeto(for: implementer))
    }

    @Test("操作员点名不可否决")
    func operatorPinIsNotVetoable() {
        let pinned = AgentRequestRouter.pinnedDecision(profileID: "ops_runner")

        #expect(pinned.isOperatorPinned)
        // 用户手点的工种，2B 小模型无权推翻。
        #expect(!AgentWorkerRoutingVeto.shouldRequestVeto(for: pinned))
    }

    // MARK: - 权限只能收缩

    /// 这个 suite 里唯一不能删的用例。
    ///
    /// 否决路径能放宽「特权目的地只能由明确关键词证据抵达」这条契约约束，
    /// 全部理由就是它单向：模型的任何输出都不会让请求获得它在纯关键词路径
    /// 下拿不到的权限。这条断言守的就是那个单向性。
    @Test("降级的结果永远不是特权档")
    func downgradeCanNeverReachAPrivilegedProfile() {
        let privileged: Set<String> = ["ops_runner", "terminal_operator"]
        let requests = [
            "那你把 deployment 里的注解改一下",
            "部署到生产环境",
            "重启服务并看看状态",
            "systemctl 重启一下再修复线上环境的服务",
            "看看终端里的报错",
            "把生产环境的配置改一下",
        ]

        for request in requests {
            let downgraded = AgentWorkerRoutingVeto.downgradedDecision(
                for: request,
                delegationPolicy: .automatic
            )
            if let profileID = downgraded?.profileID {
                #expect(!privileged.contains(profileID), "降级结果落到特权档：\(request) → \(profileID)")
            }
        }
    }

    @Test("降级是确定性的：同一请求两次结果相同")
    func downgradeIsDeterministic() {
        let request = "那你把 deployment 里的注解改一下"
        let first = AgentWorkerRoutingVeto.downgradedDecision(for: request, delegationPolicy: .automatic)
        let second = AgentWorkerRoutingVeto.downgradedDecision(for: request, delegationPolicy: .automatic)

        // 降级目标由关键词表决定，不由模型选——所以必须可复现。
        #expect(first?.profileID == second?.profileID)
        #expect(first?.confidence == second?.confidence)
    }

    @Test("降级后不再强制委派")
    func downgradeReleasesTheEnforcedRoute() throws {
        let keyword = AgentRequestRouter.classify("部署到生产环境")
        #expect(keyword.enforcesDelegatedExecution(for: .automatic))

        let downgraded = try #require(
            AgentWorkerRoutingVeto.downgradedDecision(for: "部署到生产环境", delegationPolicy: .automatic)
        )
        // 这才是用户感知到的差别：guard 不再在工具边界拦住直接执行。
        #expect(!downgraded.enforcesDelegatedExecution(for: .automatic))
    }

    @Test("跳过特权分支不影响普通请求的判决")
    func skippingPrivilegedBranchesLeavesOrdinaryRoutesAlone() {
        let request = "用户权限检查在哪个文件"
        let normal = AgentRequestRouter.classify(request)
        let skipped = AgentRequestRouter.classify(request, skippingPrivilegedBranches: true)

        #expect(normal.profileID == skipped.profileID)
    }

    // MARK: - 读不懂就维持

    @Test("空回复算读不懂")
    func emptyReplyIsUnusable() {
        // 本地 gemma4 思考没关干净时就是返回空串，这是最可能的失效形态。
        #expect(AgentWorkerRoutingVeto.parseVerdict("") == .failure(.emptyContent))
        #expect(AgentWorkerRoutingVeto.parseVerdict("   \n  ") == .failure(.emptyContent))
    }

    @Test("非法 JSON 算读不懂")
    func malformedJSONIsUnusable() {
        #expect(AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":") == .failure(.malformedJSON))
        #expect(AgentWorkerRoutingVeto.parseVerdict("我觉得不是运维") == .failure(.malformedJSON))
    }

    @Test("缺字段或答非所问算读不懂，不算否决")
    func missingFieldIsUpheldNotDowngraded() {
        // gemma4 不被点名键时会改吐 {"category":...}。把这种解释成
        // false，就等于一次答非所问撤掉了特权保护。
        #expect(AgentWorkerRoutingVeto.parseVerdict("{\"category\":\"ops\"}") == .failure(.missingField))
        #expect(AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":\"maybe\"}") == .failure(.missingField))
        #expect(AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":1}") == .failure(.missingField))
        // 这个方向更危险：数字 0 若被当成 false，就是一次凭空的否决。
        // `NSNumber as? Bool` 对 0/1 都会成功，所以解析必须用
        // CFBooleanGetTypeID 区分真布尔与数字。
        #expect(AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":0}") == .failure(.missingField))
    }

    @Test("正常判决解析")
    func wellFormedVerdictsParse() throws {
        let upheld = try #require(try? AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":true,\"confidence\":91}").get())
        #expect(upheld.upheld)
        #expect(upheld.confidence == 91)

        let vetoed = try #require(try? AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":false,\"confidence\":88}").get())
        #expect(!vetoed.upheld)
        #expect(vetoed.confidence == 88)
    }

    @Test("字符串布尔与代码围栏都能吃下")
    func toleratesStringBooleansAndFences() throws {
        let fenced = """
        ```json
        {"upheld": false, "confidence": 70}
        ```
        """
        let parsed = try #require(try? AgentWorkerRoutingVeto.parseVerdict(fenced).get())
        #expect(!parsed.upheld)

        let stringly = try #require(try? AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":\"false\"}").get())
        #expect(!stringly.upheld)
    }

    @Test("confidence 钳到 0...100")
    func confidenceIsClamped() throws {
        let high = try #require(try? AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":true,\"confidence\":900}").get())
        #expect(high.confidence == 100)

        let negative = try #require(try? AgentWorkerRoutingVeto.parseVerdict("{\"upheld\":true,\"confidence\":-5}").get())
        #expect(negative.confidence == 0)
    }

    // MARK: - 审计归因

    @Test("命中的关键词可归因")
    func matchedMarkerAttributesTheFalsePositive() {
        #expect(AgentRequestRouter.matchedPrivilegedMarker(in: "部署到生产环境") == "部署")
        #expect(AgentRequestRouter.matchedPrivilegedMarker(in: "deploy 到生产环境") != nil)
        // 词边界修好之后，deployment 不该再被归因到 deploy。
        #expect(AgentRequestRouter.matchedPrivilegedMarker(in: "把 deployment 里的注解改一下") == nil)
        #expect(AgentRequestRouter.matchedPrivilegedMarker(in: "用户权限检查在哪个文件") == nil)
    }

    // MARK: - 提示词契约

    @Test("提示词必须点名 upheld 键")
    func promptNamesTheVerdictKey() {
        // 不点名键，本地 gemma4 会改吐别的键名，解析器认不出就永远静默
        // 维持——功能看着装好了，其实一次没生效。
        #expect(AgentWorkerRoutingVeto.systemPrompt().contains("upheld"))
        #expect(AgentWorkerRoutingVeto.systemPrompt().contains("confidence"))
    }
}
