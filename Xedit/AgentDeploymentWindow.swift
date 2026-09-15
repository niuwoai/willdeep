//
//  AgentDeploymentWindow.swift
//  WillDeep
//
//  「部署窗口」信任声明的命令族判定。
//

import Foundation
import WillDeepCore

/// 一次发布里 kubectl / helm / docker / systemctl 要跑几十条，其中大半在
/// 风险分级上是写操作。逐条确认的结果是人盯着屏幕点了半小时确认——而人
/// 一旦进入连点模式，这些卡片就不再是保护，只是仪式。
///
/// 部署窗口把这件事换成一次声明：用户说「接下来是部署」，Agent 调
/// `declare_environment_trust` 并由用户人工确认一次，此后本会话内**属于
/// 部署命令族**的命令直接放行。
///
/// 这里的地基是白名单而不是裁判，理由和静默档位那次一样：裁判会掉线、会
/// 被提示词带偏，而一张列得出来的命令族清单不会。清单之外的一切——`rm -rf`、
/// `dd`、`mkfs`、删 namespace、读 secret——在窗口内和窗口外待遇完全相同。
///
/// 三条刻意不放宽：
/// 1. 凭据敏感命令（由 `AgentSandboxPolicy` 判定）永不因声明放行。凭据外读
///    是注入攻击的终点站，这道门不接受来自模型侧的说服。
/// 2. 带管道或重定向的命令一律不放行。`kubectl get -o json | sh` 前半段
///    再干净也没用，放行的单位必须是整条命令。
/// 3. 建立声明的工具本身永不自动通过（见 `AgentEnvironmentTrust`）。
nonisolated enum AgentDeploymentWindow {
    /// 声明可以覆盖的工具。跟 testDatabase 一致：本机沙箱命令和可见终端
    /// 都算，Computer Use、文件写入等其它面不受影响。
    static let scopedToolNames: Set<String> = ["run_command", "terminal_send_command"]

    /// target 子串的最短长度。太短的标识（"k8"）会把声明泛化到不相干的
    /// 命令上，和 testDatabase 同一个理由。
    static let minimumTargetLength = 3

    /// 这条命令是否属于部署命令族。
    ///
    /// 多段命令（`&&` / `||` / `;`）要求**每一段**都在族内：一段部署加一段
    /// `rm -rf /` 不是部署命令。
    static func isDeploymentCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !containsPipeOrRedirection(trimmed) else { return false }

        let segments = segments(of: trimmed)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy(isDeploymentSegment)
    }

    /// 声明是否覆盖这条命令。
    ///
    /// `target` 是可选的收窄条件：填了集群名 / namespace / 主机名，命令就
    /// 必须包含它才算命中——用户想把窗口钉在一个 namespace 上时用这个。
    /// 留空则覆盖整个命令族；审批卡会把这个区别原样写给用户看。
    static func covers(toolName: String, command: String, target: String) -> Bool {
        guard scopedToolNames.contains(toolName) else { return false }
        guard isDeploymentCommand(command) else { return false }
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return true }
        guard trimmedTarget.count >= minimumTargetLength else { return false }
        return command.lowercased().contains(trimmedTarget.lowercased())
    }

    // MARK: - 命令族

    /// kubectl 的部署类子命令。
    ///
    /// `delete` 不在这里：它既能删一个 pod，也能删掉整个 namespace 或 pvc，
    /// 而这两件事的后果差着一场事故。要删就单独确认一次，一次发布里也就
    /// 那么一两条。读取类子命令（get / describe / logs）本来就自动放行，
    /// 不需要窗口，也就不必列。
    static let kubectlDeploymentSubcommands: Set<String> = [
        "annotate", "apply", "autoscale", "cordon", "create", "expose",
        "label", "patch", "replace", "rollout", "scale", "set", "uncordon",
    ]

    /// helm。`uninstall` / `delete` 同样不列——卸载一个 release 和升级它
    /// 不是一个量级的操作。
    static let helmDeploymentSubcommands: Set<String> = [
        "dependency", "install", "lint", "list", "repo", "rollback",
        "status", "template", "upgrade",
    ]

    /// docker。`system` / `volume` / `network` 整族不列：`system prune`
    /// 和 `volume rm` 能在一条命令里清掉别人的数据。
    static let dockerDeploymentSubcommands: Set<String> = [
        "build", "compose", "images", "logs", "ps", "pull", "push",
        "restart", "start", "stop", "tag",
    ]

    /// systemctl。`mask` 不列（会让服务再也起不来且不易察觉）。
    static let systemctlDeploymentSubcommands: Set<String> = [
        "daemon-reload", "disable", "enable", "is-active", "is-enabled",
        "reload", "restart", "start", "status", "stop",
    ]

    // MARK: - 单段判定

    private static func isDeploymentSegment(_ segment: String) -> Bool {
        guard let rawTokens = AgentShellCommandParser.shellTokens(from: segment) else {
            return false
        }
        let tokens = rawTokens.drop(while: isEnvironmentAssignment).map { $0 }
        guard let head = tokens.first else { return false }
        let executable = URL(fileURLWithPath: head).lastPathComponent.lowercased()
        let arguments = Array(tokens.dropFirst())

        switch executable {
        case "kubectl":
            return matches(arguments, kubectlDeploymentSubcommands)
        case "helm":
            return matches(arguments, helmDeploymentSubcommands)
        case "docker":
            return matches(arguments, dockerDeploymentSubcommands)
        case "systemctl":
            return matches(arguments, systemctlDeploymentSubcommands)
        default:
            return false
        }
    }

    /// 取第一个非选项参数当子命令。`kubectl -n prod apply -f x.yaml` 的
    /// 子命令是 `apply`，不是 `-n`。
    private static func matches(_ arguments: [String], _ allowed: Set<String>) -> Bool {
        guard let subcommand = firstSubcommand(in: arguments) else { return false }
        return allowed.contains(subcommand)
    }

    private static func firstSubcommand(in arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("-") {
                // 带值的短选项（`-n prod`）要连值一起跳过，否则会把
                // namespace 名字当成子命令。长选项一律 `--flag=value`
                // 或独立布尔，跳一个就够。
                if !token.hasPrefix("--"), !token.contains("="), token.count == 2,
                   index + 1 < arguments.count,
                   !arguments[index + 1].hasPrefix("-") {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            return token.lowercased()
        }
        return nil
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="),
              equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func segments(of command: String) -> [String] {
        command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .split { $0 == "\n" || $0 == ";" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 管道和重定向一律拒绝。放行的单位是整条命令，`kubectl get -o json | sh`
    /// 的前半段再干净也不作数。反引号与 `$(...)` 同理：命令替换能把任意
    /// 命令塞进一条看起来很像部署的命令里。
    private static func containsPipeOrRedirection(_ command: String) -> Bool {
        if command.contains("|") || command.contains(">") || command.contains("<") {
            return true
        }
        if command.contains("`") || command.contains("$(") {
            return true
        }
        return false
    }
}
