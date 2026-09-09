//
//  AgentTerminalHostStateTests.swift
//  WillDeepTests
//
//  终端 tab 「现在连在哪台机器上」的状态机。
//
//  这件事的要害是：`kind` 只反映 tab 是怎么创建的。用户在一个本地 tab 里
//  手敲 `ssh prod` 之后，它永远还是 `.localShell`，可命令已经落在生产机上。
//  在这种 tab 上套用本机沙箱语义、或者拿上一次测到的身份去批准命令，都是
//  拿错的前提做安全判断，所以每一条不确定都必须收敛成 `unknown`。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Agent terminal host state")
struct AgentTerminalHostStateTests {
    private func identity(_ hostname: String) -> AgentTerminalHostIdentity {
        AgentTerminalHostIdentity(
            hostname: hostname,
            ipAddress: "10.0.0.9",
            operatingSystem: "Ubuntu 24.04",
            capturedAt: Date()
        )
    }

    @Test("未测过的 tab 绝不当成本机")
    func unknownIsNeverLocal() {
        let state = AgentTerminalHostState.unknown
        #expect(state.trustedIdentity == nil)
        #expect(state.lastKnownIdentity == nil)
        #expect(state.needsProbe)
    }

    @Test("换壳与断开都作废结论，但记得上一台是谁")
    func staleStatesDropTrustButKeepHistory() {
        let previous = identity("k8s-master-01")
        for state in [
            AgentTerminalHostState.changed(previous: previous),
            AgentTerminalHostState.disconnected(previous: previous),
        ] {
            // 关键不变量：作废之后不能再给出可信身份，否则调用方会拿着
            // 上一台机器的名字去批准一条已经落在别处的命令。
            #expect(state.trustedIdentity == nil)
            #expect(state.needsProbe)
            #expect(state.lastKnownIdentity == previous)
        }
    }

    @Test("探到之后才有可信身份")
    func probedStatesCarryTrust() {
        let local = AgentTerminalHostState.local(identity("rocky-mbp"))
        let remote = AgentTerminalHostState.remote(identity("k8s-master-01"))
        #expect(local.trustedIdentity?.hostname == "rocky-mbp")
        #expect(remote.trustedIdentity?.hostname == "k8s-master-01")
        #expect(!local.needsProbe)
        #expect(!remote.needsProbe)
    }

    @Test("换壳命令识别：宽一点没坏处，漏判才危险")
    func shellSwitchingCommandsAreRecognised() {
        for command in [
            "ssh yuanli@h1.niuwoai.com",
            "ssh -p 40022 root@1.2.3.4",
            "exit",
            "logout",
            "sudo -i",
            "su - postgres",
            "docker exec -it api sh",
            "kubectl exec -it pod/api -- bash",
            "tmux attach -t work",
            "limactl shell default",
        ] {
            #expect(
                AgentTerminalTab.commandMayChangeHost(command),
                "这条命令可能把 tab 换到别的机器上，必须让身份作废：\(command)"
            )
        }
    }

    @Test("普通命令不该触发重探")
    func ordinaryCommandsKeepTheCachedHost() {
        for command in [
            "git push origin main",
            "ls -la",
            "yarn build",
            "grep -rn ssh docs/",
            "echo exiting",
        ] {
            // `git push` 里有 `sh`、`grep -rn ssh` 里有 ssh 这个词、
            // `echo exiting` 里有 exit 前缀：逐词匹配才不会把它们算进来，
            // 否则几乎每条命令都会触发一次往终端打字的探针。
            #expect(
                !AgentTerminalTab.commandMayChangeHost(command),
                "这条命令不会换机器，不该白探一次：\(command)"
            )
        }
    }

    @Test("断开信号：认各系统通用的那几条")
    func disconnectSignalsAreRecognised() {
        for output in [
            "Connection to h1.niuwoai.com closed.\r\n",
            "Connection closed by 10.0.0.9 port 22\r\n",
            "Shared connection to worker-03 closed.\r\n",
            "client_loop: send disconnect: Broken pipe\r\n",
        ] {
            #expect(
                AgentTerminalTab.outputSignalsDisconnect(output),
                "这段输出说明连接已经断了：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    @Test("普通输出不该被当成断开")
    func ordinaryOutputIsNotADisconnect() {
        for output in [
            "deployment.apps/sso-server image updated\r\n",
            "Waiting for deployment rollout to finish...\r\n",
            "closed 3 stale connections in the pool\r\n",
            "error: connection refused\r\n",
        ] {
            #expect(
                !AgentTerminalTab.outputSignalsDisconnect(output),
                "误判断开会让每次都重探，白往用户终端打字：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    @Test("主机名比对：剥掉本地域后缀，大小写不敏感")
    func localHostnameComparisonIgnoresSuffixAndCase() {
        let local = ProcessInfo.processInfo.hostName
        #expect(AgentTerminalTools.isLocalHostname(local))
        // macOS 的 hostname 常带 .local，Bonjour 改名也会变。
        let bare = local.hasSuffix(".local") ? String(local.dropLast(6)) : local
        #expect(AgentTerminalTools.isLocalHostname(bare))
        #expect(AgentTerminalTools.isLocalHostname(bare.uppercased()))
        // 远端主机名不能被认成本机，空串也不能。
        #expect(!AgentTerminalTools.isLocalHostname("k8s-master-01"))
        #expect(!AgentTerminalTools.isLocalHostname(""))
        #expect(!AgentTerminalTools.isLocalHostname("   "))
    }
}
