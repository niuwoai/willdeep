import Foundation

/// Recognizes actual workspace programs, including shell-wrapped scripts.
/// This selects an execution environment; it never grants tool approval.
nonisolated enum AgentWorkspaceScriptPolicy {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh"]

    static func matches(tokens: [String], workingDirectory: URL?, roots: [URL]) -> Bool {
        guard let head = tokens.first, !roots.isEmpty else { return false }
        let wrapped = shells.contains(head)
        let candidate: String
        if wrapped {
            // Do not interpret -c payloads, options, or shell expansions.
            guard tokens.count > 1, !tokens[1].hasPrefix("-") else { return false }
            candidate = tokens[1]
        } else {
            guard head.contains("/") else { return false }
            candidate = head
        }
        guard !candidate.contains("$"), !candidate.contains("~") else { return false }
        let base = workingDirectory ?? roots[0]
        let file = (candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate)
            : base.appendingPathComponent(candidate)).standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: {
            let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return file.path.hasPrefix(root + "/")
        }), let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return wrapped || FileManager.default.isExecutableFile(atPath: file.path)
    }
}
