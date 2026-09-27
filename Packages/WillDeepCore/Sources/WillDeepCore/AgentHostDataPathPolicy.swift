//
//  AgentHostDataPathPolicy.swift
//  WillDeep
//
//  WillDeep 自己的数据目录是**写保护**的：会话历史、例程、审计日志、插件
//  数据都住在这里，而 Agent 的 shell 工具什么都能 `rm`。2026-09 一位用户的
//  `agent-sessions/<UUID>.json` 凭空消失，审计发现宿主自己的 store 从不删
//  非空会话，唯一能删它的是 `run_command`——静默/完全访问档下 `rm -rf` 是
//  自动放行的（那台机器的 sandbox.jsonl 里满是 `approvedBy: silentMode`），
//  而当时没有任何一层把这几个目录当作受保护路径。
//
//  规则只有三条，三个入口共用同一份判据，口径不能各写各的：
//   · shell 命令（`run_command` / `terminal_send_command`）：对这些目录做
//     删除、移动、截断、重定向覆盖的，一律要人打字确认——完全访问的黑
//     名单也拦（`AgentMaliciousCommandDenylist`），裁判见不到它；
//   · 原生文件工具（`create_file` / `edit_file` / `apply_patch` /
//     `write_file`）：直接拒绝，错误信息说清楚；
//   · 读取放行：排障要看 `judge.jsonl`、`sandbox.jsonl` 和会话 JSON。
//
//  路径匹配按**解析后的 token** 比对，不做裸子串匹配：`~`、`$HOME`、
//  `${HOME}`、绝对路径、相对路径（按 cwd）都先落成绝对路径，再连同
//  realpath 一起与受保护根比较。裸子串匹配在这道门上出过 `.env` 撞
//  `.envFrom` 的假阳性，这里不重蹈。
//

import Foundation

nonisolated public enum AgentHostDataPathPolicy {
    /// 一个受保护目录及其保护强度。
    public struct ProtectedDirectory: Equatable, Sendable {
        /// 相对真实主目录的路径。
        public let homeRelativePath: String
        /// 原生文件工具是否拒绝写入。shell 门禁对所有条目生效；文件工具的
        /// 拒绝只给纯宿主数据目录——`~/.willdeep` 里混着用户技能
        /// （`~/.willdeep/skills`），用户会把它当项目打开来编辑。
        public let refusesNativeFileWrites: Bool
    }

    /// 受保护目录清单。改这份名单等于改产品契约，加条目前先想清楚它
    /// 里面有没有用户会正常编辑的东西。
    ///
    ///  · `Library/Application Support/WillDeep`：会话历史（`agent-sessions`）、
    ///    例程、审计日志（`AgentAudit`）、记忆、插件数据。全是宿主自己写的
    ///    状态，Agent 没有任何合法理由改写或删除它们。
    ///  · `.willdeep`：CLI/守护进程目录（`approvals.jsonl`、`always-allow.json`、
    ///    `config.toml`、后台作业）。shell 破坏要确认；文件工具不拒绝，见
    ///    `refusesNativeFileWrites`。
    public static let protectedDirectories: [ProtectedDirectory] = [
        ProtectedDirectory(
            homeRelativePath: "Library/Application Support/WillDeep",
            refusesNativeFileWrites: true
        ),
        ProtectedDirectory(
            homeRelativePath: ".willdeep",
            refusesNativeFileWrites: false
        ),
    ]

    /// 一次命中：哪个 token、落到了哪个绝对路径、撞上了哪个受保护根。
    public struct Hit: Equatable, Sendable {
        public let token: String
        public let resolvedPath: String
        public let protectedRoot: String
        /// 面向用户/模型的一句话解释。
        public var reason: String {
            "Command would modify or delete WillDeep's own data under \(protectedRoot) (\(token)); this always requires explicit confirmation."
        }
    }

    // MARK: - 路径判定

    /// `url` 落在哪个受保护根里。`includingAncestors` 为真时，`url` 是某个
    /// 受保护根的祖先也算命中——`rm -rf ~/Library` 一样会带走会话目录。
    public static func protectedRoot(
        containing url: URL,
        includingAncestors: Bool = false,
        nativeFileWritesOnly: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let candidates = comparableSpellings(of: url)
        for directory in protectedDirectories {
            if nativeFileWritesOnly, !directory.refusesNativeFileWrites { continue }
            let root = home.appendingPathComponent(directory.homeRelativePath, isDirectory: true)
            let roots = comparableSpellings(of: root)
            for candidate in candidates {
                for rootSpelling in roots {
                    if isContained(candidate, by: rootSpelling) { return root.standardizedFileURL }
                    if includingAncestors, isContained(rootSpelling, by: candidate) { return root.standardizedFileURL }
                }
            }
        }
        return nil
    }

    /// 把一个 shell 路径 token 落成绝对路径。`~`、`$HOME`、`${HOME}` 展开
    /// 到真实主目录；相对路径按 `workingDirectory` 解析，没有 cwd 就放弃
    /// （返回 nil，宁可漏判也不猜）。末段是通配符（`dir/*`）时退到父目录，
    /// `rm -rf …/agent-sessions/*` 与删目录本身是同一件事。
    public static func resolvedPath(
        token rawToken: String,
        workingDirectory: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !token.isEmpty else { return nil }
        let homePath = home.standardizedFileURL.path
        for prefix in ["~", "$HOME", "${HOME}"] {
            if token == prefix {
                token = homePath
                break
            }
            if token.hasPrefix(prefix + "/") {
                token = homePath + token.dropFirst(prefix.count)
                break
            }
        }
        let url: URL
        if token.hasPrefix("/") {
            url = URL(fileURLWithPath: token)
        } else if let workingDirectory {
            // `./x`、`../x`、`x` 都按 cwd；`-` 开头的是 flag，不是路径。
            guard !token.hasPrefix("-") else { return nil }
            url = workingDirectory.appendingPathComponent(token)
        } else {
            return nil
        }
        var standardized = url.standardizedFileURL
        let last = standardized.lastPathComponent
        if last.contains("*") || last.contains("?") || last.contains("[") {
            standardized = standardized.deletingLastPathComponent()
        }
        return standardized
    }

    // MARK: - shell 段扫描

    /// 会对目标做破坏或改写的命令头，以及各自要看哪些位置参数。
    private enum TargetSelection {
        /// 所有位置参数；目标是受保护根的祖先也算。
        case allPositionalsIncludingAncestors
        /// 所有位置参数；只看落在受保护根之内的。
        case allPositionals
        /// 只看最后一个位置参数（cp/rsync 的目的地）。
        case lastPositional
    }

    private static let mutatingHeads: [String: TargetSelection] = [
        "rm": .allPositionalsIncludingAncestors,
        "rmdir": .allPositionalsIncludingAncestors,
        "unlink": .allPositionalsIncludingAncestors,
        "shred": .allPositionalsIncludingAncestors,
        "srm": .allPositionalsIncludingAncestors,
        "mv": .allPositionalsIncludingAncestors,
        "chmod": .allPositionalsIncludingAncestors,
        "chown": .allPositionalsIncludingAncestors,
        "chgrp": .allPositionalsIncludingAncestors,
        "truncate": .allPositionals,
        "tee": .allPositionals,
        "cp": .lastPositional,
        "rsync": .lastPositional,
        "ditto": .lastPositional,
        "install": .lastPositional,
    ]

    /// 提权与包装前缀，与 `AgentMaliciousCommandDenylist.wrapperPrefixTokens`
    /// 同一份口径。
    private static let wrapperPrefixTokens: Set<String> = [
        "sudo", "doas", "nohup", "time", "command", "exec", "builtin", "env",
        "nice", "ionice", "stdbuf", "setsid"
    ]

    /// 扫一段已分词的 shell 命令（`|`、`&&`、`;` 之间的一段）。返回第一个
    /// 会破坏或改写受保护目录的目标。看的形态：
    ///  · `rm` / `mv` / `shred` / `chmod` 等破坏性命令头的路径参数；
    ///  · `cp` / `rsync` / `ditto` / `install` 的目的地；
    ///  · `tee`、`truncate` 的目标；`sed -i` / `perl -i` 的原地改写；
    ///  · `find <dir> … -delete` / `-exec rm`；`dd of=`；
    ///  · `>` / `>>` / `&>` / `2>` 重定向的目标。
    /// 刻意不看的：`python -c`、`xargs rm` 之类把路径藏进另一层解释器或
    /// 上游管道的形态——它们留给常规的破坏性命令确认。
    public static func mutationHit(
        tokens rawTokens: [String],
        workingDirectory: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Hit? {
        let tokens = strippingWrapperPrefixes(rawTokens)
        guard let headToken = tokens.first else { return nil }
        let head = URL(fileURLWithPath: headToken).lastPathComponent.lowercased()

        func hit(_ token: String, includingAncestors: Bool) -> Hit? {
            guard let resolved = resolvedPath(token: token, workingDirectory: workingDirectory, home: home),
                  let root = protectedRoot(
                      containing: resolved,
                      includingAncestors: includingAncestors,
                      home: home
                  ) else {
                return nil
            }
            return Hit(token: token, resolvedPath: resolved.path, protectedRoot: root.path)
        }

        // 重定向目标：任何命令头都适用。`2>&1` 这类 fd 复制不是文件。
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let target = redirectionTarget(token: token, next: index + 1 < tokens.count ? tokens[index + 1] : nil) {
                if let found = hit(target, includingAncestors: false) { return found }
            }
            index += 1
        }

        let positionals = tokens.dropFirst().filter { !$0.hasPrefix("-") && !isRedirectionToken($0) }

        if let selection = mutatingHeads[head] {
            switch selection {
            case .allPositionalsIncludingAncestors:
                for token in positionals {
                    if let found = hit(token, includingAncestors: true) { return found }
                }
            case .allPositionals:
                for token in positionals {
                    if let found = hit(token, includingAncestors: false) { return found }
                }
            case .lastPositional:
                if let last = positionals.last, let found = hit(last, includingAncestors: false) { return found }
            }
            return nil
        }

        switch head {
        case "sed", "perl":
            // 只有原地改写才是写：`sed -n 1p file` 是读。
            guard tokens.contains(where: { $0 == "-i" || ($0.hasPrefix("-i") && !$0.hasPrefix("--")) || $0 == "--in-place" }) else {
                return nil
            }
            for token in positionals {
                if let found = hit(token, includingAncestors: false) { return found }
            }
        case "find":
            let lowered = tokens.map { $0.lowercased() }
            let deletes = lowered.contains("-delete")
                || zip(lowered, lowered.dropFirst()).contains { flag, next in
                    (flag == "-exec" || flag == "-execdir") && ["rm", "mv", "shred", "unlink"].contains(next)
                }
            guard deletes else { return nil }
            // 起点目录是第一个 `-` 之前的位置参数。
            for token in tokens.dropFirst().prefix(while: { !$0.hasPrefix("-") && !$0.hasPrefix("(") }) {
                if let found = hit(token, includingAncestors: true) { return found }
            }
        case "dd":
            for token in tokens where token.hasPrefix("of=") {
                if let found = hit(String(token.dropFirst("of=".count)), includingAncestors: false) { return found }
            }
        default:
            break
        }
        return nil
    }

    // MARK: - 小工具

    private static func strippingWrapperPrefixes(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while let head = tokens.first {
            let lowered = head.lowercased()
            if wrapperPrefixTokens.contains(lowered) {
                tokens.removeFirst()
                continue
            }
            // sudo 的 flag（`sudo -u root rm …`）与 env 赋值（`FOO=1 rm …`）。
            if lowered.hasPrefix("-") || (head.contains("=") && !head.hasPrefix("/")) {
                tokens.removeFirst()
                continue
            }
            break
        }
        return tokens
    }

    private static func isRedirectionToken(_ token: String) -> Bool {
        var rest = Substring(token)
        while let first = rest.first, first.isNumber { rest = rest.dropFirst() }
        if rest.hasPrefix("&") { rest = rest.dropFirst() }
        return rest.hasPrefix(">")
    }

    /// `> x` / `>> x` / `2> x` / `&> x` 的目标（可能黏在同一个 token 里）。
    private static func redirectionTarget(token: String, next: String?) -> String? {
        guard isRedirectionToken(token) else { return nil }
        var rest = Substring(token)
        while let first = rest.first, first.isNumber { rest = rest.dropFirst() }
        if rest.hasPrefix("&") { rest = rest.dropFirst() }
        while rest.hasPrefix(">") || rest.hasPrefix("|") { rest = rest.dropFirst() }
        let attached = String(rest)
        let target = attached.isEmpty ? next : attached
        guard let target, !target.hasPrefix("&"), !target.isEmpty else { return nil }
        return target
    }

    /// 标准化拼写 + realpath 两种形态，macOS 默认文件系统不分大小写，比对
    /// 前统一小写。不存在的路径沿最近的存在祖先解析（要创建的文件也能落到
    /// 软链接背后的真实目的地）。
    private static func comparableSpellings(of url: URL) -> [String] {
        let standardized = url.standardizedFileURL
        var spellings = [standardized.path.lowercased()]
        var existingAncestor = standardized
        var trailing: [String] = []
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            trailing.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in trailing {
            resolved.appendPathComponent(component)
        }
        let resolvedPath = resolved.standardizedFileURL.path.lowercased()
        if resolvedPath != spellings[0] {
            spellings.append(resolvedPath)
        }
        return spellings
    }

    private static func isContained(_ candidate: String, by root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}
