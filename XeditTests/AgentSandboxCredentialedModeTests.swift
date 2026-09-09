//
//  AgentSandboxCredentialedModeTests.swift
//  WillDeepTests
//
//  不变量：**"能上网"和"有钥匙"是两件事，而"有钥匙"不等于"能乱写"。**
//
//  背景（真实事故）：部署脚本在沙箱里跑 `ssh` 失败，报 `Operation not
//  permitted` 外加"DNS 解析失败"。Agent 顺着这两条线索去查网络策略和备用
//  SSH 端口，查了 26 条命令也没查出来——因为两条线索都是假的：
//
//    1. seatbelt 不会说"网络被拒"，它让域名解析失败（见
//       `looksLikeSandboxDenial` 里 networkDenialMarkers 的注释）。所以
//       "DNS 坏了"是沙箱伪装出来的症状，机器的 DNS 好得很。
//    2. 就算放开网络，`sandboxedEnvironment` 仍会把 HOME 指到临时目录、
//       断掉 ssh-agent，于是 `~/.ssh/config`（那些备用端口就写在里面）、
//       私钥、known_hosts 一个都读不到。Agent 想"去 config 里找备用端口"
//       时，那个文件对它根本不存在。
//
//  修复是新增 `.workspaceWriteNetworkCredentialed`：seatbelt profile 与
//  `.workspaceWriteNetwork` 完全一致（写只限 workspace + temp），唯独保留
//  真实 HOME 与 SSH_AUTH_SOCK。这个 suite 守住"只解开凭证、不解开写入"。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentSandboxCredentialedModeTests {

    private var workspace: URL {
        URL(fileURLWithPath: "/tmp/willdeep-sandbox-credentialed-tests", isDirectory: true)
    }

    // MARK: - 环境：钥匙给了，秘密没给

    @Test("凭证档保留真实 HOME 与 ssh-agent")
    func credentialedModeKeepsHomeAndAgent() {
        let base = [
            "HOME": "/Users/tester",
            "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
            "PATH": "/usr/bin:/bin",
        ]
        let env = AgentSandboxPolicy.sandboxedEnvironment(
            mode: .workspaceWriteNetworkCredentialed,
            rootDirectory: workspace,
            base: base
        )
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["SSH_AUTH_SOCK"] == "/private/tmp/ssh-agent.sock")
    }

    /// 1.358.0-rc1：HOME 不再被换掉（合成 HOME 是假墙，见 `redirectsHome`）。
    /// 区分凭证档的从此是两样真东西：ssh-agent 断不断，以及 seatbelt 对
    /// `~/.ssh` 那一撮下不下读拒绝。
    @Test("普通网络档保留真实 HOME，但断掉 ssh-agent 并拒读凭据")
    func plainNetworkModeStillScrubsCredentials() {
        let base = [
            "HOME": "/Users/tester",
            "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
        ]
        let env = AgentSandboxPolicy.sandboxedEnvironment(
            mode: .workspaceWriteNetwork,
            rootDirectory: workspace,
            base: base
        )
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["SSH_AUTH_SOCK"] == nil)
        #expect(AgentSandboxPolicy.deniesCredentialReads(.workspaceWriteNetwork))
    }

    @Test("凭证档仍然剥掉 token 类环境变量")
    func credentialedModeStillStripsTokens() {
        let base = [
            "HOME": "/Users/tester",
            "GITHUB_TOKEN": "ghp_should_not_survive",
            "GH_TOKEN": "gho_should_not_survive",
            "MY_API_KEY": "sk-should-not-survive",
            "AWS_SECRET_ACCESS_KEY": "should-not-survive",
        ]
        let env = AgentSandboxPolicy.sandboxedEnvironment(
            mode: .workspaceWriteNetworkCredentialed,
            rootDirectory: workspace,
            base: base
        )
        #expect(env["GITHUB_TOKEN"] == nil)
        #expect(env["GH_TOKEN"] == nil)
        #expect(env["MY_API_KEY"] == nil)
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        // 放行的是凭证**文件**（靠真实 HOME 读到），不是环境里的明文 token。
        #expect(env["HOME"] == "/Users/tester")
    }

    // MARK: - seatbelt：写入限制一寸没松

    @Test("凭证档仍然套 sandbox-exec")
    func credentialedModeStillUsesSeatbelt() {
        #expect(!AgentSandboxPolicy.shouldRunWithoutSeatbelt(
            command: "ruby scripts/deploy.rb",
            mode: .workspaceWriteNetworkCredentialed
        ))
        // 对照：escalated 才是完全不套沙箱的那一档。
        #expect(AgentSandboxPolicy.shouldRunWithoutSeatbelt(
            command: "ruby scripts/deploy.rb",
            mode: .escalated
        ))
    }

    /// 沙箱不再拒网络（见 `deniesNetwork` 的说明）。于是"域名解析失败"在
    /// **任何**档位下都只能是真的解析失败，不能再被解释成沙箱拒绝——那条
    /// 解释会把 agent 引去查一堵并不存在的墙。
    @Test("所有档位都放行网络，DNS 失败不再被当成沙箱拒绝")
    func everyModeAllowsNetwork() {
        for mode in [AgentSandboxMode.readOnly, .readOnlyNetwork, .workspaceWrite,
                     .workspaceWriteNetwork, .workspaceWriteNetworkCredentialed, .escalated] {
            #expect(!AgentSandboxPolicy.deniesNetwork(mode), "\(mode.rawValue)")
            #expect(!AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 255,
                output: "ssh: Could not resolve hostname h1.example.com: nodename nor servname provided",
                sandboxMode: mode
            ), "\(mode.rawValue)")
        }
    }

    // MARK: - 路由：无人值守任务不能"有网没钥匙"

    @Test("无人值守调度任务拿到凭证档")
    @MainActor
    func unattendedDispatchTaskGetsCredentials() {
        let appState = AppState(editorSettings: .default)
        let mode = appState.sandboxModeForToolExecution(
            risk: .write,
            approvalSource: .dispatchTask,
            sandboxDecision: AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "",
                prefixRule: nil
            ),
            isUnattendedDispatchTask: true
        )
        // 之前这里是 .workspaceWriteNetwork：给了网络却没给钥匙，而无人值守
        // 场景下又没有 operator 能批准提权，等于什么也干不成。
        #expect(mode == .workspaceWriteNetworkCredentialed)
    }

    @Test("凭证档决策不会在审批后被降级回普通网络档")
    @MainActor
    func approvedCredentialedDecisionSurvivesRouting() {
        let appState = AppState(editorSettings: .default)
        let mode = appState.sandboxModeForToolExecution(
            risk: .write,
            approvalSource: .user,
            sandboxDecision: AgentSandboxDecision(
                mode: .workspaceWriteNetworkCredentialed,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "",
                prefixRule: nil
            )
        )
        #expect(mode == .workspaceWriteNetworkCredentialed)
    }

    // MARK: - 分类：脚本形态的构建命令需要真实 HOME

    @Test("能联网的构建/脚本命令落在凭证档")
    func networkCapableBuildCommandsLandInCredentialedMode() {
        // `ruby scripts/deploy.rb` 正是用户拿来做部署的形态：命令头看着人畜
        // 无害，网络与 ssh 全藏在脚本里，静态分类看不见。
        let decision = AgentSandboxPolicy.commandDecision(
            command: "npm install",
            rootDirectory: workspace
        )
        #expect(decision.mode == .workspaceWriteNetworkCredentialed)
    }

    @Test("不需要网络的写命令不会顺手拿到凭证")
    func plainWorkspaceWriteDoesNotGainCredentials() {
        let decision = AgentSandboxPolicy.commandDecision(
            command: "mkdir -p build/output",
            rootDirectory: workspace
        )
        #expect(decision.mode != .workspaceWriteNetworkCredentialed)
        // 钥匙仍然只给凭证档：主目录读得到，但 `~/.ssh` 这一撮被 seatbelt
        // 内核级拒掉，ssh-agent 也照旧断开。
        #expect(AgentSandboxPolicy.deniesCredentialReads(decision.mode))
    }


    /// 测试拿 profile 的既有路子：从 `shellLaunch` 的 argv 里取 `-p` 后面
    /// 那一项。命令必须是**每一档都会被套沙箱**的那种——`mkdir`、`touch`
    /// 这类在 `.readOnly` 下会整个跳过 seatbelt，拿回来的就不是 profile 而是
    /// 命令本身。网络头永远保留 profile。
    private func seatbeltProfile(for mode: AgentSandboxMode) -> String {
        let launch = AgentSandboxPolicy.shellLaunch(
            command: "curl -sI https://example.com",
            mode: mode,
            rootDirectory: workspace
        )
        #expect(launch.executableURL.lastPathComponent == "sandbox-exec", "\(mode.rawValue)")
        return launch.arguments.dropFirst().first ?? ""
    }

    // MARK: - 真墙：主目录只读 + 凭据内核级拒读（1.358.0-rc1）

    /// 在此之前仓库里**没有任何读限制**：`(allow file-read*)` 无条件放行，
    /// `~/.ssh/id_rsa` 在每一档下都读得到，挡住它的只是一个改写过的 HOME
    /// 环境变量——写绝对路径就绕过去了。这组用例钉的是那条真的规则。
    @Test("非凭证档对凭据路径下内核级读拒绝，凭证档不下")
    func credentialPathsAreDeniedInTheKernel() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for mode in [AgentSandboxMode.readOnly, .readOnlyNetwork, .workspaceWrite, .workspaceWriteNetwork] {
            #expect(AgentSandboxPolicy.deniesCredentialReads(mode), "\(mode.rawValue)")
            let profile = seatbeltProfile(for: mode)
            // SBPL 后匹配优先，deny 必须排在 allow 之后才生效。
            let allowIndex = try? #require(profile.range(of: "(allow file-read*)"))
            let denyIndex = try? #require(profile.range(of: "(deny file-read*"))
            if let allowIndex, let denyIndex {
                #expect(allowIndex.upperBound <= denyIndex.lowerBound, "\(mode.rawValue): deny 必须在 allow 之后")
            }
            #expect(profile.contains("\(home)/.ssh"), "\(mode.rawValue)")
            #expect(profile.contains("\(home)/.aws"), "\(mode.rawValue)")
            #expect(profile.contains("\(home)/.git-credentials"), "\(mode.rawValue)")
        }
        // 凭证档就是"给钥匙"那一档，不能自己把钥匙锁上。
        #expect(!AgentSandboxPolicy.deniesCredentialReads(.workspaceWriteNetworkCredentialed))
        let credentialed = seatbeltProfile(for: .workspaceWriteNetworkCredentialed)
        #expect(!credentialed.contains("(deny file-read*"))
        // 名单只收纯凭据存放点：这几个是用户希望能用起来的配置，不许进名单。
        for keep in [".npmrc", ".kube/config", ".gitconfig"] {
            #expect(!AgentSandboxPolicy.credentialReadDenials.contains(keep), "\(keep)")
        }
    }

    /// 合成 HOME 时代这些写入落在 TMPDIR 里，是成功的。HOME 指回真实主目录
    /// 后不开口子，它们会从"每次都冷"变成 EPERM——那比原来更糟。
    @Test("主目录下的缓存目录每一档都可写，其余部分只读")
    func homeCachesStayWritableInEveryMode() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for mode in [AgentSandboxMode.readOnly, .readOnlyNetwork, .workspaceWrite,
                     .workspaceWriteNetwork, .workspaceWriteNetworkCredentialed] {
            let profile = seatbeltProfile(for: mode)
            let writeRule = profile.split(separator: "\n").first { $0.hasPrefix("(allow file-write*") }
            let rule = String(try! #require(writeRule))
            for cache in [".cache", ".npm", ".cargo", "go/pkg/mod", "Library/Caches"] {
                #expect(rule.contains("\(home)/\(cache)"), "\(mode.rawValue): \(cache)")
            }
            // 主目录整体不可写，凭据目录更不可写。
            #expect(!rule.contains("(subpath \"\(home)\")"), "\(mode.rawValue)")
            #expect(!rule.contains("\(home)/.ssh"), "\(mode.rawValue)")
        }
    }
}
