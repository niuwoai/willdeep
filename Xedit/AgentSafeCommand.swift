//
//  AgentSafeCommand.swift
//  WillDeep
//
//  Static classifier that decides whether a shell command can be
//  auto-approved without bothering the user. Used as a first pass
//  before falling back to an LLM judge for ambiguous commands.
//
//  Three outcomes:
//    .alwaysSafe     — read-only, well-known, just run it
//    .alwaysDangerous — destructive pattern, never auto-approve
//    .needsJudgment  — unknown, ask the LLM (or default to user gate)
//

import Foundation

nonisolated enum CommandSafety: Equatable, Sendable {
    case alwaysSafe
    case alwaysDangerous
    case needsJudgment
}

nonisolated enum SafeCommand {
    // MARK: - Public API

    /// Classify a shell command line. The shell line is split on `|`,
    /// `&&`, `||`, `;` first; each segment is judged independently and
    /// the strictest verdict wins (any dangerous segment → dangerous;
    /// otherwise any needs-judgment segment → needsJudgment; otherwise
    /// all-safe → safe). Empty input is dangerous (we don't auto-run
    /// nothing).
    static func classify(command: String) -> CommandSafety {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .alwaysDangerous }
        let policyCommand = commandByReplacingSafeShellExpansions(trimmed)

        // Shell metacharacters inside quotes are inert data (`printf '>'`,
        // `printf 'rm'`). Executable substitutions remain gated, including
        // those inside double quotes.
        if AgentShellCommandParser.containsExecutableSubstitution(policyCommand) {
            return .alwaysDangerous
        }
        guard let unquotedPolicyCommand = AgentShellCommandParser.unquotedText(policyCommand) else {
            return .needsJudgment
        }

        // Strict: active redirections are too easy to weaponize. Allow only
        // the small stderr/dev-null family already handled below.
        if containsAny(of: [">", "<"], in: unquotedPolicyCommand) {
            // Allow `2>&1`, `2>/dev/null` patterns through only as part
            // of an otherwise-safe-segment check by stripping known
            // benign stderr redirections before scanning. Conservative
            // baseline: refuse anything with `>`/`>>` to a file.
            if !onlyContainsHarmlessRedirections(in: unquotedPolicyCommand) {
                return .alwaysDangerous
            }
        }

        // Fork bomb (`:(){:|:&};:`) and similar "spans the whole line"
        // shapes carry their own `|` / `;` separators inside the
        // pattern — splitPipeline would shred them into harmless-looking
        // fragments. Scan dangerousSubstrings against the un-split
        // command FIRST so those shapes can't sneak through.
        let lowerTrimmed = unquotedPolicyCommand.lowercased()
        for needle in dangerousSubstrings where lowerTrimmed.contains(needle) {
            return .alwaysDangerous
        }

        guard let chain = AgentShellCommandParser.parse(policyCommand),
              !chain.segments.isEmpty else {
            return .needsJudgment
        }

        var hasJudgmentSegment = chain.requiresBackgroundJudgment
        for segment in chain.segments {
            switch classifySegment(segment.text) {
            case .alwaysDangerous:
                return .alwaysDangerous
            case .needsJudgment:
                hasJudgmentSegment = true
            case .alwaysSafe:
                continue
            }
        }
        return hasJudgmentSegment ? .needsJudgment : .alwaysSafe
    }

    // MARK: - Allowlists

    /// Commands whose entire output is read-only and side-effect free.
    /// Matched on the first token of a segment.
    static let alwaysSafeFirstTokens: Set<String> = [
        // directory navigation — only changes shell state, no FS writes.
        // Command-substitution forms like `cd $(...)` are already blocked
        // upstream by the `$(` needle check, so we don't need to filter
        // args here.
        "cd", "pushd", "popd",
        // file inspection
        "cat", "head", "tail", "less", "more", "wc", "nl",
        "file", "stat", "du", "df",
        "od", "hexdump", "strings",
        // path helpers (resolve / split — no FS mutation)
        "realpath", "readlink", "dirname", "basename",
        // compare (read both sides; writes only via shell redirection,
        // which is rejected upstream)
        "diff", "cmp",
        // directory listing
        "ls", "tree", "pwd",
        // search
        "rg", "ripgrep", "grep", "egrep", "fgrep", "ag",
        // sorting / dedup / cut etc — pure stdin transforms
        "uniq", "cut", "tr",
        "column", "paste", "join", "comm",
        "fold", "fmt", "expand", "unexpand", "rev", "tac",
        // hashing / encoding
        "md5", "shasum", "sha256sum", "sha512sum",
        "cksum", "sum",
        // structured data filters (stdout only; file writes need `>` which
        // is already refused as alwaysDangerous)
        "jq",
        // env / introspection
        "echo", "printf", "which", "whereis", "type",
        "printenv", "uname", "whoami", "id", "date", "uptime",
        "sw_vers", "arch", "hostname", "getconf", "locale",
        "groups", "logname", "man",
        // terminal display reset; changes only the current terminal screen.
        "clear",
        // process / memory snapshot (no signals)
        "ps", "top", "lsof", "vm_stat",
        // Spotlight metadata read (not mdutil — that mutates indexing)
        "mdfind", "mdls",
        // tiny calculators
        "cal", "bc",
        // network read-only. whois 和 dig/host 同族——往查询端口发一个
        // 域名字符串、读回注册信息，无写语义。漏掉它的代价是整条命令
        // 落到 LLM judge，而 judge 提示词对"开网络 socket"判得很严，
        // 实际等于每次都要用户手点（用户实测反馈，1.58.0-rc11 补上）。
        // Seatbelt skip still keeps curl/ssh under profile via networkHeads;
        // these DNS/ICMP probes are intentionally allowlisted.
        "ping", "host", "dig", "nslookup", "traceroute", "whois",
        // shell 循环/条件的无副作用胶水：read 只写 shell 变量，test/[
        // 只算真值，seq/true/false/sleep/expr 纯计算或干等。
        "read", "test", "[", "[[", "seq", "true", "false", "sleep", "expr"
    ]

    /// Low-risk *write* commands that only create things inside the
    /// workspace — make a directory, touch an empty/temp file. They mutate
    /// the filesystem (so they're not in `alwaysSafeFirstTokens`), but carry
    /// no delete / escalate / network semantics, so we auto-approve them to
    /// stop the agent stalling on a confirm card for `mkdir -p build/`.
    /// Sensitive paths (`~/.ssh`, `.env`, …) and out-of-workspace targets are
    /// still gated by AgentSandboxPolicy's path checks, which escalate
    /// independently of this classifier. NOTE: every token here must also be
    /// in AgentSandboxPolicy.lowRiskWriteHeads, otherwise the sandbox treats
    /// the command as read-only and blocks the write. (Added 1.78.0-rc15.)
    static let safeWorkspaceCreateTokens: Set<String> = [
        "mkdir", "touch", "mktemp"
    ]

    /// Commands that COULD be safe but whose argument shape matters.
    /// `git`, `find`, `xargs`, etc.: dispatched to a per-tool checker.
    static let conditionalFirstTokens: Set<String> = [
        "git", "find", "xargs", "ssh", "scp", "rsync", "kubectl",
        "curl", "wget",
        "npm", "yarn", "pnpm", "cargo", "swift", "make", "python", "python3",
        "node", "ruby", "go", "rake",
        "sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh",
        "env", "/usr/bin/env", "command",
        // list/inspect only — extract/write forms stay needsJudgment
        "defaults", "unzip", "sed", "tee", "sort", "awk", "yq",
        "base64", "iconv", "xxd"
    ]

    /// Token-level dangerous words. classifySegment walks EVERY token
    /// in the segment (not just the head) and rejects on any hit. This
    /// is the rc3 hardening: the pre-rc3 code did substring matching on
    /// strings like `"rm "` which produced false positives (`"perm "`
    /// contains `"rm "`) AND false negatives (`"foo|rm"` without space
    /// after the pipe wasn't recognized as rm in a pipeline). Token
    /// matching kills both directions.
    ///
    /// Pipelines are split upstream by `splitPipeline`, so the second
    /// half of `find . | xargs rm` is its own segment whose tokens are
    /// `["xargs", "rm"]` — the `rm` token here triggers .alwaysDangerous,
    /// closing the `xargs rm` hole the previous needle list missed.
    static let dangerousTokens: Set<String> = [
        // file removal — all forms (was: "rm ", "rm\t", "rmdir")
        "rm", "rmdir",
        // privilege escalation
        "sudo", "doas", "su",
        // filesystem formatting / partition mgmt
        "mkfs", "shutdown", "reboot", "halt", "poweroff",
        // permission / ownership change
        "chmod", "chown", "chgrp",
        // process signals (kill: now token, no longer requires trailing
        // space; catches `kill -9 pid` and `... | kill` alike)
        "kill", "killall", "pkill",
        // file move (destructive)
        "mv",
        // disk / volume management
        "diskutil", "fdisk", "format",
        // launchd manipulation
        "launchctl"
    ]

    /// Substring patterns that don't tokenize cleanly — fork bomb has
    /// no whitespace at all, `dd if=` embeds an `=` inside the first
    /// "token", `mkfs.` is a prefix that `mkfs.ext4` / `mkfs.hfs` etc.
    /// share. Kept short on purpose — every entry is a known one-off.
    static let dangerousSubstrings: [String] = [
        ":(){:|:&};:",
        "dd if=",
        "mkfs."
    ]

    /// `cp` and `ln` with ANY flag are dangerous (the pre-rc3 needles
    /// were `"cp -"` / `"ln -"` — substring match for "first arg is a
    /// flag"). Plain `cp src dst` falls back to .needsJudgment. The
    /// flagged forms (`cp -r`, `cp -R`, `ln -s`, `ln -f`) are the
    /// destructive shapes (recursive overwrite, replace symlinks).
    static let dangerousHeadsWithFlag: Set<String> = ["cp", "ln"]

    /// Shell 控制流关键字，自身带一个真正的命令负载：`do echo hi`、
    /// `then git status`、`if grep -q x f`、`while read line`。剥掉
    /// 关键字后递归分类剩余部分，让段的判定继承真实命令的判定。
    /// `!`（取反）同理。
    private static let prefixControlKeywords: Set<String> = [
        "do", "then", "else", "elif", "if", "while", "until", "time", "!"
    ]

    /// 纯块闭合/无负载关键字——出现即整段，没东西可执行。
    private static let bareControlKeywords: Set<String> = [
        "done", "fi", "esac", "{", "}"
    ]

    // MARK: - Internals

    /// Split a shell line on pipeline / sequence operators, ignoring
    /// occurrences inside single or double quotes. This is intentionally
    /// not a full shell parser — anything fancier than literal quoting
    /// (heredocs, escape continuations) falls back to .needsJudgment by
    /// way of the dangerous-needle scan.
    static func splitPipeline(_ command: String) -> [String] {
        AgentShellCommandParser.parse(command)?.segments.map(\.text) ?? []
    }

    private static func classifySegment(_ segment: String) -> CommandSafety {
        let lowercased = segment.lowercased()
        for needle in dangerousSubstrings where lowercased.contains(needle) {
            return .alwaysDangerous
        }

        let tokens = commandTokensSkippingEnvironmentAssignments(tokenize(segment))
        guard let head = tokens.first else { return .alwaysSafe }

        let firstToken = head.lowercased()

        // Only the executable position is authority. Arguments are inert
        // data unless a command-specific classifier says otherwise, so
        // `printf 'rm'` and `grep sudo file` stay read-only. Wrapper commands
        // (`xargs`, `env`, shell -c) recursively inspect their payload.
        if dangerousTokens.contains(firstToken) {
            return .alwaysDangerous
        }

        // `cp -r ...` / `ln -s ...` — head + any `-`-prefixed token.
        // Plain `cp src dst` falls through to .needsJudgment.
        if dangerousHeadsWithFlag.contains(firstToken),
           tokens.dropFirst().contains(where: { $0.hasPrefix("-") }) {
            return .alwaysDangerous
        }

        // Shell 控制流（用户实测：`for ext in io ai …; do echo …; whois …`
        // 这种纯只读循环此前因为 for/do 段头不被认识而落到 LLM judge，
        // judge 对网络命令又判得严，结果次次要人工点。处理规则：
        //   - `for VAR in words…` 是纯循环头，words 是惰性字符串
        //     （`$(…)` 形式在整行检查就被拦了），本身不执行任何东西；
        //   - do/then/if/while… 剥掉关键字递归分类真实负载，
        //     `do rm -rf /` 照样会被上面的 dangerous-token 走查毙掉；
        //   - done/fi/esac 纯闭合，无负载。
        if firstToken == "for" {
            return .alwaysSafe
        }
        if prefixControlKeywords.contains(firstToken) {
            let rest = tokens.dropFirst().joined(separator: " ")
            return rest.isEmpty ? .alwaysSafe : classifySegment(rest)
        }
        if bareControlKeywords.contains(firstToken) {
            return .alwaysSafe
        }

        if alwaysSafeFirstTokens.contains(firstToken) {
            return .alwaysSafe
        }
        if safeWorkspaceCreateTokens.contains(firstToken) {
            return .alwaysSafe
        }
        if conditionalFirstTokens.contains(firstToken) {
            return classifyConditional(firstToken: firstToken, tokens: tokens)
        }
        return .needsJudgment
    }

    /// Per-tool checker for commands like `git` or `find` whose safety
    /// depends on the subcommand. Conservative — anything unrecognized
    /// goes to .needsJudgment so the LLM (or user) decides.
    private static func classifyConditional(firstToken: String, tokens: [String]) -> CommandSafety {
        switch firstToken {
        case "git":
            return classifyGit(tokens: tokens)
        case "find":
            return classifyFind(tokens: tokens)
        case "go":
            return classifyGo(tokens: tokens)
        case "kubectl":
            return classifyKubectl(tokens: tokens)
        case "curl", "wget":
            return classifyNetworkFetcher(firstToken: firstToken, tokens: tokens)
        case "sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh":
            return classifyShellWrapper(tokens: tokens)
        case "env", "/usr/bin/env":
            return classifyEnv(tokens: tokens)
        case "command":
            return classifyCommandBuiltin(tokens: tokens)
        case "npm", "pnpm", "yarn":
            return AgentPackageCommandPolicy.classify(firstToken: firstToken, tokens: tokens)
        case "defaults":
            return classifyDefaults(tokens: tokens)
        case "unzip":
            return classifyUnzip(tokens: tokens)
        case "xargs":
            return classifyXargs(tokens: tokens)
        case "sed", "tee", "sort", "awk", "yq", "base64", "iconv", "xxd":
            return classifyStreamTransformer(firstToken: firstToken, tokens: tokens)
        default:
            return .needsJudgment
        }
    }

    /// `defaults read …` is inspection; write/delete/import stay gated.
    private static func classifyDefaults(tokens: [String]) -> CommandSafety {
        guard tokens.count >= 2 else { return .needsJudgment }
        return tokens[1].lowercased() == "read" ? .alwaysSafe : .needsJudgment
    }

    /// Archive listing only (`-l` / `-Z` / bare `-v`). Extract forms
    /// (`unzip archive.zip`, `unzip -o …`, `unzip -ov …`) stay gated —
    /// do not treat a lone `v` inside combined flags as list intent.
    private static func classifyUnzip(tokens: [String]) -> CommandSafety {
        let flags = tokens.dropFirst().filter { $0.hasPrefix("-") }.map { $0.lowercased() }
        guard !flags.isEmpty else { return .needsJudgment }
        let looksLikeList = flags.contains("-l")
            || flags.contains("-z")
            || flags == ["-v"]
            || flags.contains(where: { flag in
                guard flag.hasPrefix("-"), !flag.hasPrefix("--"), flag.count > 1 else { return false }
                return flag.dropFirst().contains("l")
            })
        return looksLikeList ? .alwaysSafe : .needsJudgment
    }

    private static let safeGitSubcommands: Set<String> = [
        "diff", "log", "status", "show", "branch", "remote",
        "blame", "config", "describe", "tag", "shortlog",
        "rev-parse", "rev-list", "ls-files", "ls-tree", "ls-remote",
        "reflog", "stash", "name-rev", "cat-file", "for-each-ref",
        "symbolic-ref", "var", "help",
        // more read-only inspectors agents hit constantly
        "grep", "version", "merge-base", "check-ignore", "check-attr",
        "count-objects", "whatchanged"
    ]

    private static func classifyGit(tokens: [String]) -> CommandSafety {
        guard tokens.count >= 2 else { return .alwaysSafe } // bare `git` → safe (usage)
        guard let subcommandIndex = gitSubcommandIndex(tokens: tokens) else {
            return .needsJudgment
        }
        let sub = tokens[subcommandIndex].lowercased()
        if safeGitSubcommands.contains(sub) {
            if ["branch", "tag", "remote", "reflog", "symbolic-ref"].contains(sub) {
                return classifyMutableGitInspector(
                    subcommand: sub,
                    arguments: Array(tokens.dropFirst(subcommandIndex + 1))
                )
            }
            // git config --global SOMETHING value would write, but
            // detecting that needs full arg parsing. `git config X` to
            // READ is fine; `git config -l/--list/--get` clearly read.
            // Reject git config arguments that look like writes.
            if sub == "config" {
                let writeFlags: Set<String> = ["--add", "--set", "--unset", "--unset-all",
                                                "--replace-all", "--remove-section",
                                                "--rename-section", "--edit"]
                if tokens.dropFirst(subcommandIndex + 1).contains(where: { writeFlags.contains($0.lowercased()) }) {
                    return .needsJudgment
                }
                // `git config user.email rocky@...` (no flag, three args)
                // is a write. Be strict: only allow --get / --list / no
                // value form.
                let nonFlagArgs = tokens.dropFirst(subcommandIndex + 1).filter { !$0.hasPrefix("-") }
                if nonFlagArgs.count >= 2 { return .needsJudgment }
            }
            if sub == "stash" {
                // git stash (without args) saves; git stash list/show are reads.
                let nextIndex = subcommandIndex + 1
                let next = tokens.count > nextIndex ? tokens[nextIndex].lowercased() : ""
                let readOnlyStash: Set<String> = ["list", "show"]
                return readOnlyStash.contains(next) ? .alwaysSafe : .needsJudgment
            }
            if ["diff", "log", "show"].contains(sub),
               gitArgumentsWriteOutput(Array(tokens.dropFirst(subcommandIndex + 1))) {
                return .needsJudgment
            }
            if sub == "grep",
               tokens.dropFirst(subcommandIndex + 1).contains(where: {
                   $0.lowercased() == "--open-files-in-pager"
                       || $0.lowercased().hasPrefix("--open-files-in-pager=")
               }) {
                return .needsJudgment
            }
            return .alwaysSafe
        }
        return .needsJudgment
    }

    private static func classifyShellWrapper(tokens: [String]) -> CommandSafety {
        guard let commandIndex = shellCommandArgumentIndex(tokens: tokens) else {
            return .needsJudgment
        }
        let innerCommand = tokens[commandIndex]
        let innerSafety = classify(command: innerCommand)
        guard innerSafety != .alwaysDangerous else {
            return .alwaysDangerous
        }
        guard shellWrappedCommandIsPathNeutral(innerCommand) else {
            return .needsJudgment
        }
        return innerSafety
    }

    private static func classifyEnv(tokens: [String]) -> CommandSafety {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            if token.contains("="), !token.hasPrefix("=") {
                index += 1
                continue
            }
            break
        }

        guard index < tokens.count else {
            return .alwaysSafe
        }
        let executable = tokens[index].lowercased()
        if ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh"].contains(executable) {
            return classifyShellWrapper(tokens: Array(tokens[index...]))
        }
        return classifySegment(Array(tokens[index...]).joined(separator: " "))
    }

    private static func classifyXargs(tokens: [String]) -> CommandSafety {
        guard let commandIndex = xargsCommandIndex(tokens: tokens) else {
            // Bare xargs invokes echo. Options without an explicit command
            // only change how stdin is grouped for that built-in default.
            return .alwaysSafe
        }
        return classifySegment(Array(tokens[commandIndex...]).joined(separator: " "))
    }

    private static func xargsCommandIndex(tokens: [String]) -> Int? {
        let optionsWithSeparateValue: Set<String> = [
            "-E", "-I", "-L", "-n", "-P", "-s", "-a", "-d",
            "--arg-file", "--delimiter", "--eof", "--replace",
            "--max-lines", "--max-args", "--max-procs", "--max-chars",
            "--process-slot-var"
        ]
        let shortOptionsWithAttachedValue: Set<Character> = ["E", "I", "L", "n", "P", "s", "a", "d"]
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                let commandIndex = index + 1
                return commandIndex < tokens.count ? commandIndex : nil
            }
            guard token.hasPrefix("-") else { return index }
            if optionsWithSeparateValue.contains(token) {
                index += 2
            } else if token.hasPrefix("--"), token.contains("=") {
                index += 1
            } else if token.count > 2,
                      token.first == "-",
                      token.dropFirst().first.map(shortOptionsWithAttachedValue.contains) == true {
                index += 1
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func classifyStreamTransformer(
        firstToken: String,
        tokens: [String]
    ) -> CommandSafety {
        let arguments = tokens.dropFirst().map { $0.lowercased() }
        switch firstToken {
        case "tee":
            let valueFlags: Set<String> = ["-i", "--ignore-interrupts", "-p"]
            let fileArguments = arguments.filter { !$0.hasPrefix("-") }
            return fileArguments.isEmpty && arguments.allSatisfy({ valueFlags.contains($0) })
                ? .alwaysSafe
                : .needsJudgment
        case "sed":
            return arguments.contains(where: {
                $0 == "--in-place"
                    || $0.hasPrefix("--in-place=")
                    || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("i"))
            })
                ? .needsJudgment
                : .alwaysSafe
        case "sort":
            return arguments.contains(where: {
                $0 == "--output" || $0.hasPrefix("--output=")
                    || ($0.hasPrefix("-o") && !$0.hasPrefix("--"))
            })
                ? .needsJudgment
                : .alwaysSafe
        case "yq":
            return arguments.contains(where: { $0 == "-i" || $0 == "--inplace" || $0 == "--in-place" })
                ? .needsJudgment
                : .alwaysSafe
        case "awk":
            let compactProgram = arguments.joined().filter { !$0.isWhitespace }
            return compactProgram.contains("system(")
                    || compactProgram.contains(">")
                    || compactProgram.contains("|")
                ? .needsJudgment
                : .alwaysSafe
        case "base64", "iconv":
            return arguments.contains(where: {
                $0 == "-o" || $0 == "--output" || $0.hasPrefix("--output=")
                    || ($0.hasPrefix("-o") && !$0.hasPrefix("--") && $0.count > 2)
            })
                ? .needsJudgment
                : .alwaysSafe
        case "xxd":
            return xxdHasOutputFile(Array(tokens.dropFirst()))
                ? .needsJudgment
                : .alwaysSafe
        default:
            return .needsJudgment
        }
    }

    private static func xxdHasOutputFile(_ arguments: [String]) -> Bool {
        let optionsWithSeparateValue: Set<String> = [
            "-c", "-cols", "-g", "-groupsize", "-l", "-len", "-n", "-name",
            "-o", "-offset", "-s", "-seek"
        ]
        var positionals = 0
        var index = 0
        while index < arguments.count {
            let argument = arguments[index].lowercased()
            if argument == "--" {
                positionals += arguments.count - index - 1
                break
            }
            if optionsWithSeparateValue.contains(argument) {
                index += 2
                continue
            }
            if !argument.hasPrefix("-") {
                positionals += 1
            }
            index += 1
        }
        return positionals >= 2
    }

    private static func classifyMutableGitInspector(
        subcommand: String,
        arguments: [String]
    ) -> CommandSafety {
        let lowered = arguments.map { $0.lowercased() }
        switch subcommand {
        case "branch":
            let writeFlags: Set<String> = [
                "-d", "-m", "-c", "-f", "--delete", "--move",
                "--copy", "--force", "--edit-description", "--set-upstream-to", "--unset-upstream"
            ]
            if lowered.contains(where: { matchesMutationFlag($0, flags: writeFlags) }) {
                return .needsJudgment
            }
            let listFlags = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
            if lowered.contains(where: { argument in
                listFlags.contains(where: { argument == $0 || argument.hasPrefix($0 + "=") })
            }) {
                return .alwaysSafe
            }
            let positional = lowered.filter { !$0.hasPrefix("-") }
            return positional.isEmpty ? .alwaysSafe : .needsJudgment
        case "tag":
            let writeFlags: Set<String> = [
                "-a", "-s", "-u", "-f", "-d", "--annotate", "--sign", "--local-user",
                "--force", "--delete", "--edit"
            ]
            if lowered.contains(where: { matchesMutationFlag($0, flags: writeFlags) }) {
                return .needsJudgment
            }
            let listFlags = [
                "-l", "--list", "--contains", "--no-contains", "--merged",
                "--no-merged", "--points-at", "--sort", "--format", "--column"
            ]
            if lowered.contains(where: { argument in
                listFlags.contains(where: { argument == $0 || argument.hasPrefix($0 + "=") })
            }) {
                return .alwaysSafe
            }
            let positional = lowered.filter { !$0.hasPrefix("-") }
            return positional.isEmpty ? .alwaysSafe : .needsJudgment
        case "remote":
            guard let action = lowered.first(where: { !$0.hasPrefix("-") }) else {
                return .alwaysSafe
            }
            return ["get-url", "show"].contains(action) ? .alwaysSafe : .needsJudgment
        case "reflog":
            guard let action = lowered.first(where: { !$0.hasPrefix("-") }) else {
                return .alwaysSafe
            }
            return ["show", "exists"].contains(action) ? .alwaysSafe : .needsJudgment
        case "symbolic-ref":
            if lowered.contains("--delete") { return .needsJudgment }
            let positional = lowered.filter { !$0.hasPrefix("-") }
            return positional.count <= 1 ? .alwaysSafe : .needsJudgment
        default:
            return .needsJudgment
        }
    }

    private static func matchesMutationFlag(_ argument: String, flags: Set<String>) -> Bool {
        if flags.contains(argument) { return true }
        if let equals = argument.firstIndex(of: "="),
           flags.contains(String(argument[..<equals])) {
            return true
        }
        return flags.contains(where: { flag in
            flag.hasPrefix("-")
                && !flag.hasPrefix("--")
                && flag.count == 2
                && argument.hasPrefix(flag)
                && argument.count > flag.count
        })
    }

    private static func gitArgumentsWriteOutput(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            let lowered = argument.lowercased()
            return lowered == "--output" || lowered.hasPrefix("--output=")
        }
    }

    private static func classifyCommandBuiltin(tokens: [String]) -> CommandSafety {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            if token == "-v" || token == "-V" {
                return .alwaysSafe
            }
            guard token.hasPrefix("-") else { break }
            index += 1
        }
        guard index < tokens.count else { return .alwaysSafe }
        return classifySegment(Array(tokens[index...]).joined(separator: " "))
    }

    private static func shellCommandArgumentIndex(tokens: [String]) -> Int? {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                continue
            }
            guard token.hasPrefix("-") else {
                return nil
            }
            if token.dropFirst().contains("c") {
                let commandIndex = index + 1
                return commandIndex < tokens.count ? commandIndex : nil
            }
            index += 1
        }
        return nil
    }

    private static func shellWrappedCommandIsPathNeutral(_ command: String) -> Bool {
        let sensitiveFragments = ["/.ssh", "/.gnupg", "/.aws", ".env", "id_rsa", "id_ed25519", "token", "secret"]
        let segments = splitPipeline(command)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            for token in tokenize(segment) {
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let lower = cleaned.lowercased()
                if cleaned.hasPrefix("/") || cleaned.hasPrefix("./") || cleaned.hasPrefix("../") || cleaned == ".." || cleaned.hasPrefix("~") {
                    return false
                }
                if sensitiveFragments.contains(where: { lower.contains($0) }) {
                    return false
                }
            }
        }
        return true
    }

    private static func gitSubcommandIndex(tokens: [String]) -> Int? {
        var index = 1
        while index < tokens.count {
            let token = tokens[index].lowercased()
            if token == "-c" {
                index += 2
                continue
            }
            if token.hasPrefix("--git-dir=") || token.hasPrefix("--work-tree=") || token.hasPrefix("-c=") {
                index += 1
                continue
            }
            if token == "--git-dir" || token == "--work-tree" {
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return index
        }
        return nil
    }

    private static func classifyFind(tokens: [String]) -> CommandSafety {
        let lowered = tokens.map { $0.lowercased() }
        let dangerousActions: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf"]
        if lowered.contains(where: { dangerousActions.contains($0) }) {
            return .alwaysDangerous
        }
        return .alwaysSafe
    }

    private static func classifyGo(tokens: [String]) -> CommandSafety {
        guard tokens.count >= 2 else { return .alwaysSafe } // bare `go` prints help
        let subcommand = tokens[1].lowercased()
        let safeWorkspaceCommands: Set<String> = [
            "build", "test", "run", "list", "vet", "fmt", "generate",
            "version", "env", "help", "doc"
        ]
        guard safeWorkspaceCommands.contains(subcommand) else {
            return .needsJudgment
        }
        if subcommand == "env" {
            let writeFlags: Set<String> = ["-w", "-u"]
            if tokens.dropFirst(2).contains(where: { writeFlags.contains($0.lowercased()) }) {
                return .needsJudgment
            }
        }
        return .alwaysSafe
    }

    /// Kubernetes inspection commands are among the most frequent visible-
    /// terminal operations. Keeping the read-only verbs deterministic avoids
    /// a network judge round trip (and a manual approval when that judge is
    /// unavailable), while mutations such as apply/delete/exec/port-forward
    /// still fall through to intelligent review.
    private static func classifyKubectl(tokens: [String]) -> CommandSafety {
        guard tokens.count >= 2 else { return .alwaysSafe }

        let lowered = tokens.map { $0.lowercased() }
        let credentialFlags: Set<String> = [
            "--token", "--client-key", "--client-certificate",
            "--certificate-authority", "--password", "--username"
        ]
        if lowered.dropFirst().contains(where: { argument in
            credentialFlags.contains(argument)
                || credentialFlags.contains(where: { argument.hasPrefix($0 + "=") })
        }) {
            return .alwaysDangerous
        }

        guard let commandIndex = kubectlCommandIndex(tokens: lowered) else {
            return .alwaysSafe
        }
        let command = lowered[commandIndex]
        let sensitiveReadMarkers: Set<String> = ["secret", "secrets"]
        if lowered.dropFirst(commandIndex + 1).contains(where: { argument in
            sensitiveReadMarkers.contains(argument)
                || sensitiveReadMarkers.contains(where: {
                    argument.contains("/\($0)") || argument.hasPrefix("\($0)/")
                })
        }) {
            return .alwaysDangerous
        }
        if command == "config",
           lowered.dropFirst(commandIndex + 1).contains(where: {
               $0 == "--raw" || $0.hasPrefix("--raw=")
           }) {
            return .alwaysDangerous
        }
        let readOnlyCommands: Set<String> = [
            "api-resources", "api-versions", "cluster-info", "describe",
            "events", "explain", "get", "help", "logs", "options",
            "top", "version", "wait"
        ]
        if readOnlyCommands.contains(command) {
            return .alwaysSafe
        }

        let arguments = Array(lowered.dropFirst(commandIndex + 1))
        switch command {
        case "auth":
            return ["can-i", "whoami"].contains(arguments.first ?? "")
                ? .alwaysSafe
                : .needsJudgment
        case "config":
            return ["current-context", "get-contexts", "view"].contains(arguments.first ?? "")
                ? .alwaysSafe
                : .needsJudgment
        case "rollout":
            return ["history", "status"].contains(arguments.first ?? "")
                ? .alwaysSafe
                : .needsJudgment
        default:
            return .needsJudgment
        }
    }

    /// Network fetchers never receive a static allow: even a GET can follow a
    /// redirect into a private service or disclose data through its URL. A
    /// plain read therefore goes to the short-lived AI judge, while request
    /// bodies, credentials, explicit local output and transport overrides
    /// stay behind a human decision.
    private static func classifyNetworkFetcher(
        firstToken: String,
        tokens: [String]
    ) -> CommandSafety {
        let arguments = Array(tokens.dropFirst())
        let lowered = arguments.map { $0.lowercased() }
        let unsafeURLSchemes = ["file:", "data:", "dict:", "gopher:", "ldap:", "ldaps:", "smb:"]
        if arguments.contains(where: { argument in
            unsafeURLSchemes.contains(where: argument.lowercased().hasPrefix)
                || URL(string: argument).map { $0.user != nil || $0.password != nil } == true
        }) {
            return .alwaysDangerous
        }

        if firstToken == "curl" {
            let dangerousLongFlags: Set<String> = [
                "--data", "--data-raw", "--data-binary", "--data-ascii",
                "--data-urlencode", "--form", "--form-string", "--json",
                "--upload-file", "--header", "--user",
                "--cookie", "--cookie-jar", "--config",
                "--netrc", "--netrc-file", "--proxy-user", "--oauth2-bearer",
                "--aws-sigv4", "--cert", "--key", "--pass", "--output",
                "--remote-name", "--remote-header-name", "--dump-header",
                "--resolve", "--connect-to", "--unix-socket", "--proxy",
                "--location-trusted"
            ]
            let dangerousShortFlags = Set("dFTHubcKoOx")
            if arguments.contains(where: { argument in
                let lower = argument.lowercased()
                if argument.hasPrefix("--") {
                    return dangerousLongFlags.contains(lower)
                        || dangerousLongFlags.contains(where: { lower.hasPrefix($0 + "=") })
                }
                guard argument.hasPrefix("-"), argument.count > 1 else { return false }
                return argument.dropFirst().contains(where: dangerousShortFlags.contains)
            }) {
                return .alwaysDangerous
            }
            if let method = explicitHTTPMethod(in: arguments),
               method != "GET", method != "HEAD" {
                return .alwaysDangerous
            }
            return .needsJudgment
        }

        let dangerousWgetFlags: Set<String> = [
            "--post-data", "--post-file", "--body-data", "--body-file",
            "--header", "--user", "--password", "--http-user", "--http-password",
            "--proxy-user", "--proxy-password", "--load-cookies", "--save-cookies",
            "--certificate", "--private-key", "--config"
        ]
        if lowered.contains(where: { argument in
            dangerousWgetFlags.contains(argument)
                || dangerousWgetFlags.contains(where: { argument.hasPrefix($0 + "=") })
        }) {
            return .alwaysDangerous
        }
        if let method = explicitWgetMethod(in: arguments),
           method != "GET", method != "HEAD" {
            return .alwaysDangerous
        }
        return .needsJudgment
    }

    private static func explicitHTTPMethod(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let lower = argument.lowercased()
            if argument == "-X" || lower == "--request" {
                guard index + 1 < arguments.count else { return "" }
                return arguments[index + 1].uppercased()
            }
            if argument.hasPrefix("-X"), argument.count > 2 {
                return String(argument.dropFirst(2)).uppercased()
            }
            if lower.hasPrefix("--request=") {
                return String(argument.dropFirst("--request=".count)).uppercased()
            }
        }
        return nil
    }

    private static func explicitWgetMethod(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let lower = argument.lowercased()
            if lower == "--method" {
                guard index + 1 < arguments.count else { return "" }
                return arguments[index + 1].uppercased()
            }
            if lower.hasPrefix("--method=") {
                return String(argument.dropFirst("--method=".count)).uppercased()
            }
        }
        return nil
    }

    private static func kubectlCommandIndex(tokens: [String]) -> Int? {
        let optionsWithSeparateValue: Set<String> = [
            "-n", "-s", "--as", "--as-group", "--cache-dir", "--cluster",
            "--context", "--kubeconfig", "--namespace", "--profile",
            "--profile-output", "--request-timeout", "--server", "--user"
        ]
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-") else { return index }
            if optionsWithSeparateValue.contains(token) {
                index += 2
            } else {
                index += 1
            }
        }
        return index < tokens.count ? index : nil
    }

    /// Minimal POSIX-ish tokenizer: splits on whitespace outside quotes.
    /// Quote bodies are kept as a single token with quotes stripped so
    /// downstream checks see the literal text.
    static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in segment {
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch.isWhitespace, !inSingle, !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func containsAny(of needles: [String], in haystack: String) -> Bool {
        for needle in needles where haystack.contains(needle) {
            return true
        }
        return false
    }

    private static func commandTokensSkippingEnvironmentAssignments(_ tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            index += 1
        }
        return Array(tokens.suffix(from: index))
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="),
              equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        guard let first = name.first,
              first == "_" || first.isLetter else {
            return false
        }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func commandByReplacingSafeShellExpansions(_ command: String) -> String {
        command.replacingOccurrences(of: "$(pwd)", with: ".")
    }

    /// Strip `2>&1`, `2>/dev/null`, and `1>/dev/null` from the line and
    /// see whether any redirection is left. Used to allow stderr/stdout
    /// being silenced without flagging the whole command as dangerous.
    private static func onlyContainsHarmlessRedirections(in command: String) -> Bool {
        var stripped = command
        let harmless = [
            "2>&1",
            "2>/dev/null",
            "1>/dev/null",
            ">/dev/null"
        ]
        for token in harmless {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        // After stripping the harmless forms, no `>` or `<(` / `$(` /
        // backticks may remain.
        if stripped.contains(">") { return false }
        if stripped.contains("<(") { return false }
        if stripped.contains("$(") { return false }
        if stripped.contains("`") { return false }
        return true
    }
}
