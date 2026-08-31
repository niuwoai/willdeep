import Foundation

/// Exact public template names, never a prefix exemption for real credentials.
nonisolated enum AgentWorkspaceTemplatePolicy {
    static let names: Set<String> = [".env.example", ".env.sample", ".env.template"]
    private static let credentialDirectories: Set<String> = [
        ".ssh", ".aws", ".gnupg", "secret", "secrets", "credential", "credentials"
    ]

    static func isPublicTemplate(_ token: String, workingDirectory: URL?, roots: [URL]) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("-"), !token.hasPrefix("~"),
              !token.contains(where: { ":=*?$`(){}[]<>|&;\"'".contains($0) }),
              !(token as NSString).pathComponents.contains(".."),
              names.contains((token as NSString).lastPathComponent) else { return false }
        guard let base = workingDirectory ?? roots.first else { return false }
        let path = token.hasPrefix("/")
            ? URL(fileURLWithPath: token)
            : base.appendingPathComponent(token)
        // Foundation may leave a dangling symlink unresolved. Check every
        // component below the declared workspace, including missing-target
        // links, rather than trusting canonicalization alone.
        guard !hasSymlinkBelowRoot(path, roots: roots) else { return false }
        let canonical = path.resolvingSymlinksInPath().standardizedFileURL
        let parentPath = canonical.deletingLastPathComponent().path.lowercased()
        guard names.contains(canonical.lastPathComponent),
              ![".env", "id_rsa", "id_ed25519"].contains(where: { parentPath.contains($0) }),
              !canonical.pathComponents.contains(where: {
                  credentialDirectories.contains($0.lowercased()) || $0.lowercased() == ".env"
              }) else { return false }
        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return canonical.path.hasPrefix(rootPath + "/")
        }
    }

    private static func hasSymlinkBelowRoot(_ url: URL, roots: [URL]) -> Bool {
        let candidate = url.standardizedFileURL
        let rootPaths = roots.flatMap { [$0.standardizedFileURL.path, $0.resolvingSymlinksInPath().standardizedFileURL.path] }
        guard let root = rootPaths.filter({ candidate.path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
            return true
        }
        var current = candidate
        while current.path != root {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}
