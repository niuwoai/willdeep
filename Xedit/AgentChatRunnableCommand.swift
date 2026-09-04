//
//  AgentChatRunnableCommand.swift
//  WillDeep
//
//  决定 transcript 里某个 shell 代码块该不该长出「运行」与「送进终端」
//  两个按钮。
//
//  门槛刻意定得很高——**只有确定安全、单条、立刻能跑完的本机命令**才给
//  按钮，其余一律只留复制图标：
//   · 要审批的（`SafeCommand` 判不出 `.alwaysSafe`）不给。点一下就跑掉
//     一条本来该由用户过目的命令，等于把审批档位从侧门绕过去了；
//   · 复杂的不给。管道、`&&`、重定向、子 shell、多行——这些是脚本不是
//     命令，出了事说不清是哪一段干的，也没法在一行提示里让用户看明白；
//   · 耗时或交互式的不给。`top` / `less` / `tail -f` / `yarn build` 这类在
//     `.alwaysSafe` 里（前三个确实只读，最后一个确实是正常开发脚本），但
//     点下去要么半天不返回、要么等一个没人能给的按键，聊天区那条结果消息
//     会一直悬着，最后还会被超时掐成一条假失败；
//   · 远程会话不给。工作区在服务器上时，本机跑出来的结果是另一台机器的
//     答案，比没有更糟。
//
//  漏判的代价只是少一个按钮（复制永远在），误判的代价是替用户执行了他
//  没打算执行的东西——所以这里一律往严里判。
//

import Foundation

nonisolated enum AgentChatRunnableCommand {
    /// 认这些围栏语言标签。`console` / `shellsession` 刻意不收：那类块按
    /// 惯例是「提示符 + 命令 + 输出」的抄本，整块拿去执行必然是错的。
    static let shellLanguages: Set<String> = ["bash", "sh", "shell", "zsh"]

    /// 单条命令的长度上限。超过这个长度的多半是拼了一长串参数的脚本行，
    /// 用户在一行按钮旁边根本读不完，让他复制到终端里看。
    static let maximumLength = 200

    /// 允许上按钮的头部命令：`SafeCommand` 的只读白名单，去掉下面那些
    /// 不痛快返回的，再加上 `git`（读类子命令由 SafeCommand 自己判，
    /// `git push` / `git clone` 到不了 `.alwaysSafe`）。
    ///
    /// 为什么不直接信 `.alwaysSafe`：那个判据回答的是「要不要拦一道审批」，
    /// 不是「点一下几秒钟能回来吗」。`yarn build` 在它眼里是安全的开发脚本
    /// （确实是），但一跑好几分钟，会被这里 15 秒的超时拦腰砍断，用户看到
    /// 的是一条「没跑完就被掐了」的假失败。这类耗时命令一律只给复制。
    static var eligibleHeads: Set<String> {
        SafeCommand.alwaysSafeFirstTokens.subtracting(interactiveHeads).union(["git"])
    }

    /// 只读但不会痛快返回的命令：分页器、跟随输出、交互式编辑器、
    /// 无限探测。`SafeCommand` 认为它们安全（确实不写东西），但它们
    /// 不适合「点一下、等一条结果消息」这种一次性执行。
    static let interactiveHeads: Set<String> = [
        "top", "htop", "btop", "watch",
        "less", "more", "man", "info",
        "vi", "vim", "nvim", "nano", "emacs", "pico",
        "ssh", "scp", "sftp", "telnet", "nc", "ncat", "ftp",
        "read", "sleep", "screen", "tmux",
        "python", "python3", "node", "irb", "ruby", "bc", "sqlite3",
        "tail", "ping", "traceroute", "dmesg",
    ]

    /// 让一行命令变成「一段脚本」的字符。出现任何一个就只给复制。
    /// 注意 `$` 单独出现（`$HOME`）是允许的，被拦的是 `$(` 命令替换。
    private static let scriptingNeedles: [String] = [
        "|", "&", ";", ">", "<", "`", "$(", "\n", "\r",
    ]

    /// 从围栏块的语言标签与正文里取出可执行的那一条命令；不满足任何一条
    /// 门槛就返回 nil，调用方据此决定只渲染复制按钮。
    ///
    /// - Parameters:
    ///   - language: 围栏的 info string（```bash 的 "bash"），大小写不敏感。
    ///   - body: 围栏正文。允许带零宽断点，这里会先净化再判断。
    ///   - isRemoteWorkspace: 当前会话的工作区是否在远端。远端一律不给。
    static func command(
        language: String?,
        body: String,
        isRemoteWorkspace: Bool
    ) -> String? {
        guard !isRemoteWorkspace else { return nil }
        let tag = (language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard shellLanguages.contains(tag) else { return nil }

        // 渲染用的正文里插过 U+200B 断点，直接拿去执行会得到一串查无此
        // 因的报错——与复制按钮同一套净化。
        let sanitized = AgentCopyTextSanitizer.sanitize(body)
        let lines = sanitized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, let command = lines.first else { return nil }
        guard isRunnable(command) else { return nil }
        return command
    }

    /// 单条命令本身够不够格。与 `command(language:body:isRemoteWorkspace:)`
    /// 分开，是为了执行前能再判一次——按钮上挂的载荷不该是唯一的把关点。
    static func isRunnable(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return false }
        // 抄本里的提示符（`$ ls`、`% ls`、`# ls`）不是命令的一部分，
        // 带着它跑必然报错，也说明这块是抄本不是可执行命令。
        guard !trimmed.hasPrefix("$ "), !trimmed.hasPrefix("% "), !trimmed.hasPrefix("# ") else {
            return false
        }
        for needle in scriptingNeedles where trimmed.contains(needle) {
            return false
        }
        guard let head = trimmed.split(separator: " ").first.map(String.init) else { return false }
        let headName = (head as NSString).lastPathComponent.lowercased()
        guard eligibleHeads.contains(headName) else { return false }
        guard AgentMaliciousCommandDenylist.match(command: trimmed) == nil else { return false }
        return SafeCommand.classify(command: trimmed) == .alwaysSafe
    }
}
