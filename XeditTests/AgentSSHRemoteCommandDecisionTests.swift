//
//  AgentSSHRemoteCommandDecisionTests.swift
//  WillDeepTests
//
//  ssh 带多行远程脚本时的判定。用例取自真实审批日志：2026-09 的 74 次人工
//  确认里，ssh 远程只读占 13%，全部是 journalctl / systemctl status 这类
//  查日志的活。
//

import Foundation
import Testing

@testable import WillDeep

@Suite("ssh 远程脚本判定")
nonisolated struct AgentSSHRemoteCommandDecisionTests {
    private static let workspace = URL(fileURLWithPath: "/tmp/willdeep-ssh-tests")

    private func decision(_ command: String) -> AgentSandboxDecision {
        AgentSandboxPolicy.commandDecision(command: command, rootDirectory: Self.workspace)
    }

    /// 单行远程命令一直是能解析的，先把这个基线钉住。
    @Test("单行远程命令解析得出")
    func singleLineRemoteCommandParses() {
        #expect(
            AgentCommandAuthorization.sshRemoteCommand(
                from: "ssh -o BatchMode=yes root@h1.niuwoai.com 'uptime'"
            ) == "uptime"
        )
    }

    /// 取自 2026-09-14 17:14。远程脚本换行写，是运维查日志的常态写法。
    @Test("多行远程脚本解析得出")
    func multilineRemoteScriptParses() {
        let command = """
        ssh -o BatchMode=yes -o ConnectTimeout=10 root@h1.niuwoai.com '
        echo "=== niuwo 日志 ==="
        journalctl -u niuwo --since "24 hours ago" | tail -50
        '
        """
        let remote = AgentCommandAuthorization.sshRemoteCommand(from: command)
        #expect(remote != nil)
        #expect(remote?.contains("journalctl") == true)
    }

    /// 只读的远程脚本不该逼用户打字确认——打字确认是强制人工，不打字确认
    /// 才会继续走到智能复核。
    @Test("只读远程脚本不需要打字确认")
    func readOnlyRemoteScriptSkipsTypedConfirmation() {
        let command = """
        ssh -o BatchMode=yes -o ConnectTimeout=10 root@h1.niuwoai.com '
        echo "=== 服务状态 ==="
        systemctl status niuwo
        journalctl -u niuwo --since "1 hour ago" | tail -20
        '
        """
        #expect(!decision(command).requiresTypedConfirmation)
    }

    /// 远程脚本里藏破坏性命令，照旧拦住。
    @Test("破坏性远程脚本照旧拦截")
    func destructiveRemoteScriptStillBlocked() {
        let command = """
        ssh root@h1.niuwoai.com '
        rm -rf /var/lib/niuwo
        '
        """
        let result = decision(command)
        #expect(result.requiresUserApproval)
    }

    /// 远程读私钥同样是红线。
    @Test("远程读私钥照旧拦截")
    func remoteCredentialReadStillBlocked() {
        let result = decision("ssh root@h1.niuwoai.com 'cat /root/.ssh/id_rsa'")
        #expect(result.requiresUserApproval)
    }
}
