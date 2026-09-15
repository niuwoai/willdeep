import Foundation
import Testing
import WillDeepCore
@testable import WillDeep

@Suite("SSH Agent 只读诊断审批")
struct AgentSSHDiagnosticApprovalTests {
    private let root = URL(fileURLWithPath: "/tmp/willdeep-ssh-diagnostic-tests")

    @Test("截图中的诊断命令可进入智能审核")
    func screenshotCommandReachesJudge() {
        let command = #"echo "AUTH_SOCK=$SSH_AUTH_SOCK"; ls -la ~/.ssh/agent ~/.ssh/sockets 2>&1; ssh-add -l 2>&1; echo "EXIT=$?""#
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
        #expect(!decision.requiresTypedConfirmation)
        #expect(!decision.credentialSensitive)
        #expect(decision.risk == .write)
        #expect(SafeCommand.classify(command: command) == .needsJudgment)
    }

    @Test("SSH 目录元数据不等于读取凭据", arguments: [
        "ls -la ~/.ssh", "ls -ld $HOME/.ssh/agent/", "/bin/ls -lah ${HOME}/.ssh/sockets",
        "ls -la ~/.ssh/agent ~/.ssh/sockets 2>&1", "ssh-add -l"
    ])
    func metadataCanBeReviewed(command: String) {
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
        #expect(!decision.requiresTypedConfirmation)
        #expect(!decision.credentialSensitive)
    }

    /// `head ~/.ssh/config` 曾在这张清单里。1.375.0-rc11 起它降级为「送裁判」
    /// （凭据标记保留，只免打字确认）——依据是审批日志：2026-07 以来 63 次
    /// 涉及 .ssh 的人工确认中，53 次只读了 config / known_hosts，一次私钥都
    /// 没碰。降级后的边界由 AgentSSHConfigReviewTests 覆盖。这是有意调整，
    /// 不是遗漏。
    @Test("凭据内容、未知参数和危险命令链不继承目录豁免", arguments: [
        "cat ~/.ssh/id_ed25519", "ls -la ~/.ssh/id_rsa",
        "ls -R ~/.ssh", "ls -la ~/.ssh/*", "ls -la ~/.ssh/agent/../id_rsa",
        "ls -la ~/.ssh ~/.aws", "ls -la ~/.ssh > ~/.ssh/config",
        "ls -la ~/.ssh/agent; cat ~/.ssh/id_ed25519",
        "ls -la ~/.ssh/agent; rm ~/.ssh/id_ed25519",
        "ssh-add ~/.ssh/id_ed25519", "KEY_SECRET=value ls -la ~/.ssh/agent"
    ])
    func sensitiveOperationsStillRequireUser(command: String) {
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
        #expect(decision.requiresTypedConfirmation)
    }
}
