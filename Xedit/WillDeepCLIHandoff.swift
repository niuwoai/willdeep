//
//  WillDeepCLIHandoff.swift
//  WillDeep
//
//  `/handoff`: continue a Mac session on another machine running
//  willdeep-cli (willdeep-rs). Design: docs/SESSION_COLLABORATION_AND_HANDOFF.md
//  「交接到 willdeep-cli」.
//
//  Git is the transport. One commit on a fresh `willdeep/handoff/...` branch
//  carries the code (HEAD plus every uncommitted change) and a transport
//  folder with the conversation in willdeep-cli's Session v1 format and a
//  handoff brief. The commit is built with a temporary index, so the user's
//  working tree, index and checked-out branch are never touched. Both
//  machines need their own git credentials for the remote; nothing here
//  stores or forwards credentials.
//

import Foundation

nonisolated enum WillDeepCLIHandoff {
    static let branchPrefix = "willdeep/handoff/"
    static let transportDirectory = ".willdeep/handoff"
    /// willdeep-rs `SESSION_VERSION`.
    static let cliSessionVersion = 1
    static let maximumTranscriptBytes = 400_000
    static let maximumMessageCharacters = 20_000
    static let pushTimeout: TimeInterval = 180

    struct SessionInput {
        var title: String
        var messages: [AgentMessage]
        var plan: AgentPlan?
        var goal: AgentGoal?
        var editedPaths: [String]
    }

    struct GitContext: Equatable {
        var repositoryRoot: URL
        var baseCommit: String
        var baseBranch: String?
        var remoteName: String
        var remoteURL: String
    }

    struct Package: Equatable {
        var cliSessionID: UUID
        var branch: String
        var sessionJSON: Data
        var brief: String

        var sessionPath: String { "\(WillDeepCLIHandoff.transportDirectory)/\(cliSessionID.uuidString.lowercased())/session.json" }
        var briefPath: String { "\(WillDeepCLIHandoff.transportDirectory)/\(cliSessionID.uuidString.lowercased())/brief.md" }
    }

    struct Result: Equatable {
        var branch: String
        var commit: String
        var remoteName: String
        var remoteURL: String
        var cliSessionID: UUID
        var includedUncommittedChanges: Bool
        var resumeScript: String
    }

    enum Failure: LocalizedError, Equatable {
        case notARepository
        case noCommits
        case noRemote
        case sensitiveUntrackedFiles([String])
        case gitFailed(step: String, detail: String)
        case pushFailed(String)

        var errorDescription: String? {
            switch self {
            case .notARepository: return L10n.SessionHandoff.notARepository
            case .noCommits: return L10n.SessionHandoff.noCommits
            case .noRemote: return L10n.SessionHandoff.noRemote
            case .sensitiveUntrackedFiles(let paths): return L10n.SessionHandoff.sensitiveFiles(paths.joined(separator: ", "))
            case .gitFailed(let step, let detail): return L10n.SessionHandoff.gitFailed(step: step, detail: detail)
            case .pushFailed(let detail): return L10n.SessionHandoff.pushFailed(detail)
            }
        }
    }

    typealias GitRunner = (_ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) -> GitCommandResult

    // MARK: Package

    static func branchName(title: String, now: Date) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let ascii = title.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(ascii)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(40)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        return branchPrefix + (slug.isEmpty ? stamp : "\(stamp)-\(slug)")
    }

    static func makePackage(
        session: SessionInput,
        git: GitContext,
        instructions: String,
        now: Date = Date(),
        cliSessionID: UUID = UUID()
    ) throws -> Package {
        let branch = branchName(title: session.title, now: now)
        var package = Package(cliSessionID: cliSessionID, branch: branch, sessionJSON: Data(), brief: "")
        package.brief = brief(session: session, git: git, branch: branch, package: package, instructions: instructions)
        package.sessionJSON = try cliSessionJSON(session: session, id: cliSessionID, now: now)
        return package
    }

    /// willdeep-rs `Session` (version 1). Only the readable conversation is
    /// carried: tool calls and tool results reference Mac paths and handles
    /// that mean nothing on the other machine, and an orphaned tool result is
    /// rejected by providers. The brief restates the state they produced.
    static func cliSessionJSON(session: SessionInput, id: UUID, now: Date) throws -> Data {
        let seconds = Int(now.timeIntervalSince1970)
        var messages: [[String: Any]] = []
        var budget = maximumTranscriptBytes
        for message in session.messages.reversed() {
            guard let entry = cliMessage(message) else { continue }
            let size = ((entry["content"] as? String)?.utf8.count ?? 0)
                + ((entry["reasoning"] as? String)?.utf8.count ?? 0)
            guard size <= budget else { break }
            budget -= size
            messages.append(entry)
        }
        messages.reverse()
        // A transcript cut mid-exchange must not open with an assistant turn.
        while let first = messages.first, first["role"] as? String == "assistant" {
            messages.removeFirst()
        }
        var object: [String: Any] = [
            "version": cliSessionVersion,
            "id": id.uuidString.lowercased(),
            "title": session.title,
            "title_source": "legacy",
            // Replaced by `willdeep -w "$PWD"` in the resume script; the Mac
            // path would not exist on the receiving machine.
            "workspace": ".",
            "profile": NSNull(),
            "created_at": seconds,
            "updated_at": seconds,
            "messages": messages
        ]
        if let plan = session.plan, !plan.steps.isEmpty {
            object["current_plan"] = [
                "summary": plan.summary,
                "steps": plan.steps.map { step -> [String: Any] in
                    var entry: [String: Any] = [
                        "id": step.id.uuidString.lowercased(),
                        "text": step.text,
                        "status": step.status.rawValue
                    ]
                    if let detail = step.detail { entry["detail"] = detail }
                    return entry
                }
            ]
        }
        if let statement = session.goal?.statement.trimmingCharacters(in: .whitespacesAndNewlines),
           !statement.isEmpty {
            object["goal"] = statement
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func cliMessage(_ message: AgentMessage) -> [String: Any]? {
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        default: return nil
        }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        var entry: [String: Any] = ["role": role, "content": String(content.prefix(maximumMessageCharacters))]
        if role == "user", message.source == .hostInstruction {
            entry["source"] = "hostInstruction"
        }
        if role == "assistant",
           let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty {
            entry["reasoning"] = String(reasoning.prefix(maximumMessageCharacters))
        }
        return entry
    }

    /// First prompt of the resumed session. Written for the receiving model.
    static func brief(
        session: SessionInput,
        git: GitContext,
        branch: String,
        package: Package,
        instructions: String
    ) -> String {
        var lines: [String] = [
            "# Handoff from WillDeep for macOS",
            "",
            "You are continuing a task that was started in a WillDeep session on a Mac. The conversation so far is already in this session's history.",
            "",
            "- Session: \(session.title)",
            "- Branch: `\(branch)` — its HEAD holds the Mac's code, including changes that were not committed there.",
            "- Based on: `\(git.baseBranch ?? "detached HEAD")` @ `\(git.baseCommit)`"
        ]
        if let goal = session.goal, !goal.statement.isEmpty {
            lines += ["", "## Goal", goal.statement]
            for item in goal.checklist {
                lines.append("- [\(item.done ? "x" : " ")] \(item.text)")
            }
        }
        if let plan = session.plan, !plan.steps.isEmpty {
            lines += ["", "## Plan"]
            if !plan.summary.isEmpty { lines.append(plan.summary) }
            for (index, step) in plan.steps.enumerated() {
                lines.append("\(index + 1). [\(step.status.rawValue)] \(step.text)")
            }
        }
        let edited = Array(Set(session.editedPaths)).sorted()
        if !edited.isEmpty {
            lines += ["", "## Files the Mac session changed"]
            lines += edited.prefix(60).map { "- `\($0)`" }
            if edited.count > 60 { lines.append("- … \(edited.count - 60) more") }
        }
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines += ["", "## Instructions from the user for this handoff", extra]
        }
        lines += [
            "",
            "## How to continue",
            "1. `\(package.sessionPath)` and `\(package.briefPath)` only transport this handoff. Remove the `\(transportDirectory)` folder in your first commit.",
            "2. Tool results from the Mac are not in the history. Check the real state first (git status, build, tests) instead of trusting earlier claims.",
            "3. Continue with the unfinished plan steps. Commit to this branch and push it; do not force-push or merge into shared branches unless the user asks.",
            "4. Reply in the language the user used in the conversation."
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Shell for the receiving machine, run inside its clone of the same
    /// repository. Every interpolated value is single-quoted.
    static func resumeScript(branch: String, package: Package) -> String {
        let quotedBranch = shellQuote(branch)
        let id = package.cliSessionID.uuidString.lowercased()
        let home = "\"${WILLDEEP_HOME:-$HOME/.willdeep}\""
        return """
        git fetch origin \(shellQuote("refs/heads/\(branch):refs/remotes/origin/\(branch)")) \\
          && (git switch \(quotedBranch) 2>/dev/null && git merge --ff-only \(shellQuote("origin/\(branch)")) || git switch -c \(quotedBranch) --track \(shellQuote("origin/\(branch)"))) \\
          && mkdir -p \(home)/sessions \\
          && cp \(shellQuote(package.sessionPath)) \(home)/sessions/\(id).json \\
          && willdeep -w "$PWD" run --session \(id) --input \(shellQuote(package.briefPath))
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Git

    /// Untracked files that look like secrets are never pushed silently.
    /// Tracked files are already on the remote's history path, so only
    /// untracked additions are checked.
    static func sensitivePaths(in paths: [String]) -> [String] {
        let exactNames: Set<String> = [".env", ".npmrc", ".pypirc", ".netrc", "id_rsa", "id_ed25519", "id_ecdsa", "credentials", "credentials.json", "secrets.json", "service-account.json"]
        let suffixes = [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".mobileprovision"]
        return paths.filter { path in
            let name = (path as NSString).lastPathComponent.lowercased()
            if exactNames.contains(name) { return true }
            if name.hasPrefix(".env.") && name != ".env.example" && name != ".env.sample" { return true }
            return suffixes.contains { name.hasSuffix($0) }
        }
    }

    static func resolveGitContext(run: GitRunner) throws -> GitContext {
        let root = run(["rev-parse", "--show-toplevel"], [:], 30)
        guard root.status == 0, !root.stdout.handoffTrimmed.isEmpty else { throw Failure.notARepository }
        let head = run(["rev-parse", "--verify", "HEAD"], [:], 30)
        guard head.status == 0, !head.stdout.handoffTrimmed.isEmpty else { throw Failure.noCommits }
        let branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"], [:], 30)
        let remotes = run(["remote"], [:], 30).stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else { throw Failure.noRemote }
        let url = run(["remote", "get-url", remote], [:], 30)
        return GitContext(
            repositoryRoot: URL(fileURLWithPath: root.stdout.handoffTrimmed),
            baseCommit: head.stdout.handoffTrimmed,
            baseBranch: branch.status == 0 && !branch.stdout.handoffTrimmed.isEmpty ? branch.stdout.handoffTrimmed : nil,
            remoteName: remote,
            remoteURL: url.stdout.handoffTrimmed
        )
    }

    /// Builds and pushes the handoff commit. `run` executes git in the
    /// repository root; `temporaryDirectory` receives the scratch index and
    /// package files and is the caller's to clean up.
    static func perform(
        session: SessionInput,
        instructions: String,
        temporaryDirectory: URL,
        now: Date = Date(),
        run: GitRunner
    ) throws -> Result {
        let git = try resolveGitContext(run: run)

        let untracked = run(["ls-files", "--others", "--exclude-standard", "-z"], [:], 60)
        guard untracked.status == 0 else { throw Failure.gitFailed(step: "ls-files", detail: untracked.stderr.handoffTrimmed) }
        let untrackedPaths = untracked.stdout.split(separator: "\0").map(String.init)
        let sensitive = sensitivePaths(in: untrackedPaths)
        guard sensitive.isEmpty else { throw Failure.sensitiveUntrackedFiles(sensitive) }

        let package = try makePackage(session: session, git: git, instructions: instructions, now: now)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        // Scratch copy of the real index, so staged-but-uncommitted state is
        // kept and the real index is never written.
        let indexURL = temporaryDirectory.appendingPathComponent("index")
        let realIndex = run(["rev-parse", "--path-format=absolute", "--git-path", "index"], [:], 30)
        if realIndex.status == 0, FileManager.default.fileExists(atPath: realIndex.stdout.handoffTrimmed) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: realIndex.stdout.handoffTrimmed), to: indexURL)
        }
        let indexEnvironment = ["GIT_INDEX_FILE": indexURL.path]

        try check(run(["add", "-A"], indexEnvironment, 120), step: "add")
        let changes = run(["diff", "--cached", "--quiet", git.baseCommit], indexEnvironment, 60)
        let includedUncommittedChanges = changes.status == 1

        for (path, data) in [(package.sessionPath, package.sessionJSON), (package.briefPath, Data(package.brief.utf8))] {
            let fileURL = temporaryDirectory.appendingPathComponent((path as NSString).lastPathComponent)
            try data.write(to: fileURL)
            let blob = try check(run(["hash-object", "-w", fileURL.path], [:], 30), step: "hash-object").stdout.handoffTrimmed
            try check(run(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(path)"], indexEnvironment, 30), step: "update-index")
        }
        let tree = try check(run(["write-tree"], indexEnvironment, 60), step: "write-tree").stdout.handoffTrimmed
        let message = "chore(handoff): \(session.title)\n\nWillDeep handoff to willdeep-cli. Transport files live under \(transportDirectory)/ and should be removed after import."
        let commit = try check(run(["commit-tree", tree, "-p", git.baseCommit, "-m", message], [:], 60), step: "commit-tree").stdout.handoffTrimmed

        let push = run(["push", git.remoteName, "\(commit):refs/heads/\(package.branch)"], [:], pushTimeout)
        guard push.status == 0 else {
            throw Failure.pushFailed(push.timedOut ? "timed out" : push.stderr.handoffTrimmed)
        }
        return Result(
            branch: package.branch,
            commit: commit,
            remoteName: git.remoteName,
            remoteURL: git.remoteURL,
            cliSessionID: package.cliSessionID,
            includedUncommittedChanges: includedUncommittedChanges,
            resumeScript: resumeScript(branch: package.branch, package: package)
        )
    }

    @discardableResult
    private static func check(_ result: GitCommandResult, step: String) throws -> GitCommandResult {
        guard result.status == 0 else {
            throw Failure.gitFailed(step: step, detail: result.timedOut ? "timed out" : result.stderr.handoffTrimmed)
        }
        return result
    }
}

private extension String {
    nonisolated var handoffTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
