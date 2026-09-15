//
//  AgentJudgeRedactionScopeTests.swift
//  WillDeepTests
//
//  裸选项脱敏的语境门控。`-u` 只有在 curl / wget 手里才是凭据选项。
//

import Foundation
import Testing

@testable import WillDeep

@Suite("送裁判前的脱敏范围")
nonisolated struct AgentJudgeRedactionScopeTests {
    /// 2026-09-14 那批 ssh 人工确认的根因：`journalctl -u sslcat` 的 `-u`
    /// 是 unit（服务名），被当成 curl 的用户名选项抹掉，命令随即被当成
    /// 「带凭据」，而「脱敏后仍可送裁判」的豁免只认 curl/wget——于是一条
    /// 查日志的命令既进不了裁判，也解释不清自己为什么可疑。
    @Test("journalctl 的 -u 是服务名，不该被抹")
    func journalctlUnitIsNotRedacted() {
        let command = "journalctl -u sslcat --since \"24 hours ago\" | tail -50"
        #expect(AgentInjectionDefense.redactedCommandForSafetyJudge(command) == command)
    }

    @Test("ssh 里包着的 journalctl 同样不该被抹")
    func remoteJournalctlUnitIsNotRedacted() {
        let command = "ssh root@h1.niuwoai.com 'journalctl -u niuwo --since \"1 hour ago\"'"
        #expect(AgentInjectionDefense.redactedCommandForSafetyJudge(command) == command)
    }

    /// 其它把 `-u` 当别的意思用的常见命令，一并守住。
    @Test("其它命令的 -u 不受影响")
    func unrelatedShortOptionsSurvive() {
        let sort = "sort -u /tmp/hosts.txt"
        #expect(AgentInjectionDefense.redactedCommandForSafetyJudge(sort) == sort)
        let systemctl = "systemctl --user -u niuwo status"
        #expect(AgentInjectionDefense.redactedCommandForSafetyJudge(systemctl) == systemctl)
    }

    // MARK: - 该抹的照抹

    /// curl 在场时 `-u` 恢复凭据语义，必须抹掉。
    @Test("curl 的 -u 照旧抹掉")
    func curlCredentialOptionIsRedacted() {
        let command = "curl -u admin:hunter2 https://api.internal/health"
        let redacted = AgentInjectionDefense.redactedCommandForSafetyJudge(command)
        #expect(redacted.contains("[REDACTED]"))
        #expect(!redacted.contains("hunter2"))
    }

    @Test("wget 的 -b 照旧抹掉")
    func wgetShortOptionIsRedacted() {
        let command = "wget -b secretcookie https://example.internal/file"
        #expect(AgentInjectionDefense.redactedCommandForSafetyJudge(command).contains("[REDACTED]"))
    }

    /// 长选项与键名形状的凭据不依赖 curl 语境，任何命令里都要抹。
    @Test("长选项与键名形状的凭据始终抹掉")
    func credentialShapesAlwaysRedacted() {
        let token = "deploy.sh --token=ghp_abcdefghijklmnopqrstuvwxyz012345"
        #expect(!AgentInjectionDefense.redactedCommandForSafetyJudge(token).contains("ghp_abcdefghij"))

        let password = "mysql --password=hunter2 -e 'select 1'"
        #expect(!AgentInjectionDefense.redactedCommandForSafetyJudge(password).contains("hunter2"))

        let proxy = "curl --proxy-user bob:secret https://example.internal"
        #expect(!AgentInjectionDefense.redactedCommandForSafetyJudge(proxy).contains("secret"))

        let apiKey = "export API_KEY=sk-abcdefghijklmnopqrstuvwxyz"
        #expect(!AgentInjectionDefense.redactedCommandForSafetyJudge(apiKey).contains("sk-abcdefghij"))
    }
}
