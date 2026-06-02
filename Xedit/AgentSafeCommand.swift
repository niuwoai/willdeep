//
//  AgentSafeCommand.swift
//  VeilWriter
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

enum CommandSafety: Equatable {
    case alwaysSafe
    case alwaysDangerous
    case needsJudgment
}

enum SafeCommand {
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

        // Strict: redirections and command substitution are too easy to
        // weaponize. `>`, `>>`, `<(`, `$(`, backticks → not safe.
        if containsAny(of: [">", ">>", "<(", "$(", "`"], in: trimmed) {
            // Allow `2>&1`, `2>/dev/null` patterns through only as part
            // of an otherwise-safe-segment check by stripping known
            // benign stderr redirections before scanning. Conservative
            // baseline: refuse anything with `>`/`>>` to a file.
            if !onlyContainsHarmlessRedirections(in: trimmed) {
                return .alwaysDangerous
            }
        }

        let segments = splitPipeline(trimmed)
        guard !segments.isEmpty else { return .alwaysDangerous }

        var hasJudgmentSegment = false
        for segment in segments {
            switch classifySegment(segment) {
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
        // file inspection
        "cat", "head", "tail", "less", "more", "wc", "nl",
        "file", "stat", "du", "df",
        // directory listing
        "ls", "tree", "pwd",
        // search
        "rg", "ripgrep", "grep", "egrep", "fgrep", "ag",
        // sorting / dedup / cut etc — pure stdin transforms
        "sort", "uniq", "cut", "tr", "awk", "sed", "tee",
        "column", "paste", "join", "comm",
        // hashing / encoding
        "md5", "shasum", "sha256sum", "sha512sum", "base64",
        // env / introspection
        "echo", "printf", "which", "whereis", "type", "command",
        "env", "printenv", "uname", "whoami", "id", "date", "uptime",
        // process snapshot (no signals)
        "ps", "top",
        // network read-only
        "ping", "host", "dig", "nslookup", "traceroute"
    ]

    /// Commands that COULD be safe but whose argument shape matters.
    /// `git`, `find`, `xargs`, etc.: dispatched to a per-tool checker.
    static let conditionalFirstTokens: Set<String> = [
        "git", "find", "xargs", "ssh", "scp", "rsync",
        "npm", "yarn", "pnpm", "cargo", "swift", "make", "python", "python3",
        "node", "ruby", "go", "rake"
    ]

    /// Patterns that, anywhere in a segment, mark it as dangerous and
    /// never auto-approve (already enforced by AgentToolRegistry.risk
    /// at the .danger tier; duplicated here so callers can rely on this
    /// classifier alone).
    static let dangerousNeedles: [String] = [
        "rm ", "rm\t", "rmdir", "sudo ", "doas ",
        ":(){:|:&};:",
        "mkfs", "dd if=", "shutdown", "reboot", "halt", "poweroff",
        "chmod ", "chown ", "chgrp ",
        "kill ", "killall", "pkill",
        "mv ", "cp -", "ln -",
        "curl ", "wget ",
        "diskutil", "fdisk", "format",
        "launchctl"
    ]

    // MARK: - Internals

    /// Split a shell line on pipeline / sequence operators, ignoring
    /// occurrences inside single or double quotes. This is intentionally
    /// not a full shell parser — anything fancier than literal quoting
    /// (heredocs, escape continuations) falls back to .needsJudgment by
    /// way of the dangerous-needle scan.
    static func splitPipeline(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var index = command.startIndex
        while index < command.endIndex {
            let ch = command[index]
            if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); index = command.index(after: index); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); index = command.index(after: index); continue }

            if !inSingle && !inDouble {
                // Check for two-character operators first.
                let next = command.index(after: index)
                if next < command.endIndex {
                    let pair = String(command[index...next])
                    if pair == "&&" || pair == "||" {
                        segments.append(current)
                        current = ""
                        index = command.index(after: next)
                        continue
                    }
                }
                if ch == "|" || ch == ";" || ch == "\n" {
                    segments.append(current)
                    current = ""
                    index = command.index(after: index)
                    continue
                }
                // Background operator `&` (without `&&`) is suspicious —
                // treat as a segment break so downstream judgment kicks in.
                if ch == "&" {
                    segments.append(current)
                    current = ""
                    index = command.index(after: index)
                    continue
                }
            }
            current.append(ch)
            index = command.index(after: index)
        }
        segments.append(current)
        return segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func classifySegment(_ segment: String) -> CommandSafety {
        let lowercased = " " + segment.lowercased() + " "
        for needle in dangerousNeedles where lowercased.contains(needle) {
            return .alwaysDangerous
        }

        let tokens = tokenize(segment)
        guard let head = tokens.first else { return .alwaysDangerous }

        let firstToken = head.lowercased()
        if alwaysSafeFirstTokens.contains(firstToken) {
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
        case "xargs":
            // xargs by itself wraps another command — defer to judgment.
            return .needsJudgment
        default:
            return .needsJudgment
        }
    }

    private static let safeGitSubcommands: Set<String> = [
        "diff", "log", "status", "show", "branch", "remote",
        "blame", "config", "describe", "tag", "shortlog",
        "rev-parse", "rev-list", "ls-files", "ls-tree", "ls-remote",
        "reflog", "stash", "name-rev", "cat-file", "for-each-ref",
        "symbolic-ref", "var", "help"
    ]

    private static func classifyGit(tokens: [String]) -> CommandSafety {
        guard tokens.count >= 2 else { return .alwaysSafe } // bare `git` → safe (usage)
        let sub = tokens[1].lowercased()
        if safeGitSubcommands.contains(sub) {
            // git config --global SOMETHING value would write, but
            // detecting that needs full arg parsing. `git config X` to
            // READ is fine; `git config -l/--list/--get` clearly read.
            // Reject git config arguments that look like writes.
            if sub == "config" {
                let writeFlags: Set<String> = ["--add", "--set", "--unset", "--unset-all",
                                                "--replace-all", "--remove-section",
                                                "--rename-section", "--edit"]
                if tokens.dropFirst(2).contains(where: { writeFlags.contains($0.lowercased()) }) {
                    return .needsJudgment
                }
                // `git config user.email rocky@...` (no flag, three args)
                // is a write. Be strict: only allow --get / --list / no
                // value form.
                let nonFlagArgs = tokens.dropFirst(2).filter { !$0.hasPrefix("-") }
                if nonFlagArgs.count >= 2 { return .needsJudgment }
            }
            if sub == "stash" {
                // git stash (without args) saves; git stash list/show are reads.
                let next = tokens.count >= 3 ? tokens[2].lowercased() : ""
                let readOnlyStash: Set<String> = ["list", "show"]
                return readOnlyStash.contains(next) ? .alwaysSafe : .needsJudgment
            }
            return .alwaysSafe
        }
        return .needsJudgment
    }

    private static func classifyFind(tokens: [String]) -> CommandSafety {
        let lowered = tokens.map { $0.lowercased() }
        let dangerousActions: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf"]
        if lowered.contains(where: { dangerousActions.contains($0) }) {
            return .alwaysDangerous
        }
        return .alwaysSafe
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
