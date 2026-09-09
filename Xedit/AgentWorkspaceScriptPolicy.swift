import Foundation

/// Recognizes actual workspace programs: a script file that lives inside the
/// project, run directly, through a shell, or through an interpreter.
///
/// This selects an execution environment; it never grants tool approval.
///
/// The scripts a project keeps in its own tree are the project's own code —
/// the same code the agent is already allowed to read and edit. Confining
/// them to the workspace seatbelt bought nothing and cost a great deal: they
/// ran with a synthetic `HOME` and, below the credentialed tier, no network
/// at all, so a deploy script could not read `~/.ssh`, a build script could
/// not reach its registry, and the failure surfaced as a DNS error rather
/// than as a denial. See `AgentSandboxPolicy.commandDecision` for what the
/// match now buys.
///
/// The trust is positional, not semantic: nothing here reads the script. A
/// file the agent itself wrote into the workspace matches exactly like one
/// the user committed, so the guards below are what keep the match narrow —
/// the path must be literal (no `$`, no `~`, no `-c` payload), it is
/// resolved through symlinks, and it must land strictly inside a workspace
/// root.
nonisolated enum AgentWorkspaceScriptPolicy {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh"]

    /// Interpreters whose first non-option argument is a script file. Matched
    /// on the last path component so `/opt/homebrew/bin/ruby` counts too.
    /// Deliberately excludes anything whose first argument is not a path
    /// (`-c`, `-m`, `-e` payloads are rejected below).
    private static let interpreters: Set<String> = [
        "ruby", "python", "python2", "python3", "node", "deno", "bun",
        "perl", "php", "tsx", "ts-node", "osascript",
    ]

    /// How the script was invoked. The three forms need different file
    /// checks: only a bare `./script` has to carry the executable bit.
    private enum Invocation {
        case direct
        case shellWrapped
        case interpreted
    }

    static func matches(tokens: [String], workingDirectory: URL?, roots: [URL]) -> Bool {
        resolvedScriptURL(tokens: tokens, workingDirectory: workingDirectory, roots: roots) != nil
    }

    /// The script file this command runs, resolved through symlinks, or nil
    /// when the command is not a workspace script invocation. Callers that
    /// need to ask something about the file itself — such as whether the user
    /// has trusted the folder it lives in — use this rather than re-deriving
    /// the path from the tokens.
    static func resolvedScriptURL(tokens: [String], workingDirectory: URL?, roots: [URL]) -> URL? {
        guard let head = tokens.first, !roots.isEmpty else { return nil }
        let invocation: Invocation
        if shells.contains(head) {
            invocation = .shellWrapped
        } else if interpreters.contains((head as NSString).lastPathComponent) {
            invocation = .interpreted
        } else if head.contains("/") {
            invocation = .direct
        } else {
            return nil
        }

        let candidate: String
        switch invocation {
        case .direct:
            candidate = head
        case .shellWrapped, .interpreted:
            // Do not interpret -c/-m/-e payloads, options, or expansions.
            guard tokens.count > 1, !tokens[1].hasPrefix("-") else { return nil }
            candidate = tokens[1]
        }
        guard !candidate.contains("$"), !candidate.contains("~") else { return nil }
        let base = workingDirectory ?? roots[0]
        let file = (candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate)
            : base.appendingPathComponent(candidate)).standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: {
            let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return file.path.hasPrefix(root + "/")
        }), let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        guard invocation != .direct || FileManager.default.isExecutableFile(atPath: file.path) else { return nil }
        return file
    }

    /// A workspace script the user has confirmed they trust. Only these are
    /// allowed out of the sandbox; an unanswered folder behaves exactly like
    /// one the user declined.
    static func trustedScriptURL(tokens: [String], workingDirectory: URL?, roots: [URL]) -> URL? {
        guard let file = resolvedScriptURL(tokens: tokens, workingDirectory: workingDirectory, roots: roots),
              AgentWorkspaceTrustStore.isTrusted(file) else { return nil }
        return file
    }
}
