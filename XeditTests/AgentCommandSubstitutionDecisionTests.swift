//
//  AgentCommandSubstitutionDecisionTests.swift
//  WillDeepTests
//
//  命令替换里裹着的只读查询不该被打成「不可界定」。用例全部取自真实审批
//  日志：2026-09-14/15 两天的 45 次人工确认里，这一类占了大头。
//

import Foundation
import Testing

@testable import WillDeep

@Suite("命令替换的沙箱判定")
nonisolated struct AgentCommandSubstitutionDecisionTests {
    private static let workspace = URL(fileURLWithPath: "/tmp/willdeep-substitution-tests")

    private func decision(_ command: String) -> AgentSandboxDecision {
        AgentSandboxPolicy.commandDecision(
            command: command,
            rootDirectory: Self.workspace
        )
    }

    // MARK: - 该送裁判的：括号内外都是只读网络查询
    //
    // 分界线是 `requiresTypedConfirmation`：要打字确认的命令一定停在人工
    // 那里，不打字确认的 `.escalated` 会继续走到智能复核（2026-09 裁判
    // 上场 317 次、放行 265 次）。所以这些用例断言的是「别再逼用户打字」，
    // 不是「静态免审」——带命令替换的整条命令仍然要过一次复核。

    /// 取自 2026-09-14 08:10 的真实命令。整条是只读的：`$(...)` 里是
    /// `kubectl get`，外层是 `echo` + `jq`。此前因为子命令判定只接受
    /// `.readOnly`、而 kubectl 必然是 `.readOnlyNetwork`，整条被打成
    /// escalated + 打字确认。
    @Test("kubectl get 裹在命令替换里不再逼人打字确认")
    func kubectlGetInsideSubstitutionReachesJudge() {
        let result = decision(
            "D=$(kubectl --request-timeout=20s -n tokenhub get deploy tokenhub -o json); "
                + "echo \"$D\" | jq -r '.spec.template.spec.containers[0].image'"
        )
        #expect(!result.requiresTypedConfirmation)
        #expect(result.reason.contains("intelligent review"))
    }

    /// 取自 2026-09-11 12:19。
    @Test("单条赋值型命令替换不再逼人打字确认")
    func assignmentOnlySubstitutionReachesJudge() {
        let result = decision(
            "POD=$(kubectl -n tokenhub get pod -l app=tokenhub "
                + "-o jsonpath='{.items[0].metadata.name}')"
        )
        #expect(!result.requiresTypedConfirmation)
    }

    /// 取自 2026-09-14 08:33 的轮询循环。
    @Test("循环里的只读查询不需要打字确认")
    func pollingLoopStaysReadable() {
        let result = decision(
            "for i in $(seq 1 30); do S=$(kubectl -n tokenhub get pod tokenhub-migrate-0240 "
                + "-o jsonpath='{.status.phase}'); echo \"$S\"; sleep 2; done"
        )
        #expect(!result.requiresTypedConfirmation)
    }

    // MARK: - 必须仍然拦住的

    /// 括号里藏一条破坏性命令，整条不能因为外层长得无害就放行。
    @Test("命令替换里的破坏性命令照旧拦截")
    func destructiveSubstitutionStillBlocked() {
        let result = decision("D=$(rm -rf /srv/data); echo \"$D\"")
        #expect(result.requiresUserApproval)
    }

    /// 凭据是红线：括号内外都不例外。
    /// 这条同时守着一个回归：放宽之前，它靠「替换不可界定」这条通用理由
    /// 拦下，外层 decision 的 `credentialSensitive` 一直是 false。凡是按这个
    /// 标记做判断的下游（部署窗口、环境信任的凭据红线）都看不见它。放宽这
    /// 条路的同时必须把标记带上来，否则等于顺手把红线拆了。
    @Test("命令替换里读私钥照旧拦截，且凭据标记要传上来")
    func credentialSubstitutionStillBlocked() {
        let result = decision("K=$(cat ~/.ssh/id_rsa); echo \"$K\"")
        #expect(result.requiresUserApproval)
        #expect(result.credentialSensitive)
    }

    /// 解出 secret 仍然要人确认——这一类在日志里占 37%，且不是误伤。
    @Test("解码 secret 照旧拦截")
    func secretDecodeStillBlocked() {
        let result = decision(
            "PW=$(kubectl -n tokenhub get secret tokenhub-mysql-ha-root "
                + "-o jsonpath='{.data.rootPassword}' | base64 -d)"
        )
        #expect(result.requiresUserApproval)
    }

    /// 外层是写操作时，括号内只读不能把整条洗成只读。
    @Test("外层写操作不因内层只读而降级")
    func writingOuterCommandStaysWrite() {
        let result = decision(
            "kubectl delete pod $(kubectl -n tokenhub get pod -o jsonpath='{.items[0].metadata.name}')"
        )
        #expect(result.mode != .readOnly)
    }
}
