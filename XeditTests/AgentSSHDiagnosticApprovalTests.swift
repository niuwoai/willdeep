import Foundation
import Testing
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

    @Test("凭据内容、未知参数和危险命令链不继承目录豁免", arguments: [
        "cat ~/.ssh/id_ed25519", "head ~/.ssh/config", "ls -la ~/.ssh/id_rsa",
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
