import Foundation

/// Immutable Git-backed artifact manifest. Text reports, screenshots and other
/// ordinary files use the same content-addressed delivery path as source code.
nonisolated struct AgentDispatchArtifactSnapshot: Codable, Equatable, Sendable {
    let taskID: UUID
    let baseRevision: String
    let revision: String
    let tree: String
    let paths: [String]
}

nonisolated struct AgentDispatchIntegrationReceipt: Codable, Equatable, Sendable {
    let snapshot: AgentDispatchArtifactSnapshot
    let previousRevision: String
    let integratedRevision: String
}

/// Preparation is not publication. The host must verify this exact immutable
/// revision before publishing it; a failed verification leaves dependencies
/// consuming the previous integrated revision.
nonisolated struct AgentDispatchIntegrationCandidate: Codable, Equatable, Sendable {
    let goalID: UUID
    let snapshot: AgentDispatchArtifactSnapshot
    let expectedRefRevision: String?
    let previousRevision: String
    let revision: String
}

nonisolated enum AgentDispatchIntegrationError: Error, Equatable {
    case invalidRevision
    case unsafePath(String)
    case unsupportedFile(String)
    case commandFailed(operation: String, status: Int32)
    case outputIncomplete
    case conflict
    case concurrentUpdate
    case unverifiedCandidate
}

/// Host integration never checks out, stages into the user's index, commits on
/// their branch, invokes repository filters/hooks, or pushes. Temporary indexes
/// produce immutable snapshots; compare-and-swap updates only private refs.
nonisolated enum AgentDispatchArtifactIntegrator {
    private static let commandTimeout: TimeInterval = 60
    private static let outputLimit = 256 * 1_024

    static func integratedRef(goalID: UUID) -> String {
        "refs/willdeep/dispatch/\(goalID.uuidString.lowercased())/integrated"
    }

    static func snapshot(
        in workspace: URL,
        goalID: UUID,
        taskID: UUID,
        baseRevision: String,
        paths: [String]
    ) async throws -> AgentDispatchArtifactSnapshot {
        try validateRevision(baseRevision)
        let selected = try Array(Set(paths.map(validatePath))).sorted()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("WillDeep dispatch temporary index cleanup failed: %@", error.localizedDescription) }
        }
        let environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        _ = try await git(["read-tree", baseRevision], in: workspace, environment: environment)
        for path in selected {
            try Task.checkCancellation()
            try await stageFile(path, in: workspace, environment: environment)
        }
        let tree = try await oid(["write-tree"], in: workspace, environment: environment)
        let ref = "refs/willdeep/dispatch/\(goalID.uuidString.lowercased())/tasks/\(taskID.uuidString.lowercased())"
        let existing = try await resolve(ref, in: workspace)
        if let existing,
           try await oid(["rev-parse", "\(existing)^{tree}"], in: workspace) == tree,
           try await oid(["rev-parse", "\(existing)^"], in: workspace) == baseRevision {
            return .init(taskID: taskID, baseRevision: baseRevision, revision: existing, tree: tree, paths: selected)
        }
        let revision = try await oid(
            ["commit-tree", tree, "-p", baseRevision, "-m", "WillDeep task artifact \(taskID.uuidString)"], in: workspace
        )
        try await update(ref, to: revision, expected: existing, in: workspace)
        return .init(taskID: taskID, baseRevision: baseRevision, revision: revision, tree: tree, paths: selected)
    }

    static func prepareIntegration(
        _ snapshot: AgentDispatchArtifactSnapshot,
        in repository: URL,
        goalID: UUID,
        goalBaseRevision: String
    ) async throws -> AgentDispatchIntegrationCandidate {
        try validateRevision(goalBaseRevision)
        try validateRevision(snapshot.revision)
        try validateRevision(snapshot.baseRevision)
        try validateRevision(snapshot.tree)
        guard try await oid(["rev-parse", "\(snapshot.revision)^{tree}"], in: repository) == snapshot.tree,
              try await oid(["rev-parse", "\(snapshot.revision)^"], in: repository) == snapshot.baseRevision else {
            throw AgentDispatchIntegrationError.invalidRevision
        }
        let declaredPaths = Set(try snapshot.paths.map(validatePath))
        let diff = try await git(["diff-tree", "-r", "--no-commit-id", "--name-only", "-z", snapshot.baseRevision, snapshot.revision], in: repository)
        guard Set(diff.stdoutText.split(separator: "\0").map(String.init)).isSubset(of: declaredPaths) else {
            throw AgentDispatchIntegrationError.invalidRevision
        }
        let ref = integratedRef(goalID: goalID)
        let existing = try await resolve(ref, in: repository)
        let previous = existing ?? goalBaseRevision
        let ancestry = try await git(
            ["merge-base", "--is-ancestor", snapshot.revision, previous],
            in: repository, allowedStatuses: [0, 1]
        )
        if ancestry.exitStatus == 0 {
            return .init(goalID: goalID, snapshot: snapshot, expectedRefRevision: existing,
                         previousRevision: previous, revision: previous)
        }
        let drivers = try await git(["config", "--name-only", "--get-regexp", "^merge\\..*\\.driver$"], in: repository, allowedStatuses: [0, 1])
        // Custom merge drivers are arbitrary repository-configured commands.
        // Disable them for host-owned integration; a conflict is recoverable,
        // silently executing a driver outside tool authorization is not.
        let disabledDrivers = drivers.stdoutText.split(separator: "\n").flatMap { ["-c", "\($0)=false"] }
        let merge = try await git(
            disabledDrivers + ["merge-tree", "--write-tree", previous, snapshot.revision],
            in: repository, allowedStatuses: [0, 1]
        )
        guard merge.exitStatus == 0 else { throw AgentDispatchIntegrationError.conflict }
        let tree = merge.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        try validateRevision(tree)
        let revision = try await oid(
            ["commit-tree", tree, "-p", previous, "-p", snapshot.revision,
             "-m", "WillDeep integrate task artifact \(snapshot.taskID.uuidString)"], in: repository
        )
        // Keep a prepared candidate reachable across GC/restarts before its
        // durable journal entry can point to it.
        let candidateRef = "refs/willdeep/dispatch/\(goalID.uuidString.lowercased())/candidates/\(revision)"
        _ = try await git(["update-ref", candidateRef, revision], in: repository)
        return .init(goalID: goalID, snapshot: snapshot, expectedRefRevision: existing,
                     previousRevision: previous, revision: revision)
    }

    /// `verifiedRevision` comes from the host verifier, never the task's prose.
    /// CAS prevents evidence for one candidate from publishing a different
    /// merge after another task completed concurrently. A stale candidate must
    /// be prepared and verified again against the latest integrated revision.
    static func publish(
        _ candidate: AgentDispatchIntegrationCandidate,
        verifiedRevision: String,
        in repository: URL
    ) async throws -> AgentDispatchIntegrationReceipt {
        guard verifiedRevision == candidate.revision else {
            throw AgentDispatchIntegrationError.unverifiedCandidate
        }
        try validateRevision(candidate.revision)
        try validateRevision(candidate.previousRevision)
        try validateRevision(candidate.snapshot.revision)
        if candidate.revision != candidate.previousRevision {
            guard try await oid(["rev-parse", "\(candidate.revision)^1"], in: repository) == candidate.previousRevision,
                  try await oid(["rev-parse", "\(candidate.revision)^2"], in: repository) == candidate.snapshot.revision else {
                throw AgentDispatchIntegrationError.invalidRevision
            }
        }
        let ref = integratedRef(goalID: candidate.goalID)
        let current = try await resolve(ref, in: repository)
        if current != candidate.revision {
            if let current {
                let published = try await git(["merge-base", "--is-ancestor", candidate.revision, current], in: repository, allowedStatuses: [0, 1])
                if published.exitStatus == 0 {
                    return .init(snapshot: candidate.snapshot, previousRevision: candidate.previousRevision, integratedRevision: candidate.revision)
                }
            }
            guard current == candidate.expectedRefRevision else {
                throw AgentDispatchIntegrationError.concurrentUpdate
            }
            try Task.checkCancellation()
            try await update(ref, to: candidate.revision, expected: current, in: repository)
        }
        return .init(snapshot: candidate.snapshot, previousRevision: candidate.previousRevision,
                     integratedRevision: candidate.revision)
    }

    static func repositoryIdentity(in repository: URL) async throws -> URL {
        let output = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repository)
        let path = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw AgentDispatchIntegrationError.invalidRevision }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    static func isAncestor(_ revision: String, of descendant: String, in repository: URL) async throws -> Bool {
        try validateRevision(revision)
        try validateRevision(descendant)
        return try await git(["merge-base", "--is-ancestor", revision, descendant], in: repository,
                             allowedStatuses: [0, 1]).exitStatus == 0
    }

    static func currentRevision(in repository: URL, goalID: UUID, baseRevision: String) async throws -> String {
        try validateRevision(baseRevision)
        return try await resolve(integratedRef(goalID: goalID), in: repository) ?? baseRevision
    }

    static func createVerificationCheckout(for candidate: AgentDispatchIntegrationCandidate, in repository: URL, parent: URL) async throws -> URL {
        try validateRevision(candidate.revision)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent("willdeep-verify-\(UUID().uuidString)")
        _ = try await git(["worktree", "add", "--detach", directory.path, candidate.revision], in: repository)
        return directory
    }

    static func requireUnchangedVerificationCheckout(_ directory: URL, revision: String) async throws {
        try validateRevision(revision)
        guard try await oid(["rev-parse", "HEAD"], in: directory) == revision else {
            throw AgentDispatchIntegrationError.invalidRevision
        }
        _ = try await git(["diff", "--quiet", revision, "--"], in: directory)
    }

    static func removeVerificationCheckout(_ directory: URL, in repository: URL) async throws {
        guard directory.lastPathComponent.hasPrefix("willdeep-verify-") else {
            throw AgentDispatchIntegrationError.unsafePath(directory.path)
        }
        _ = try await git(["worktree", "remove", "--force", directory.path], in: repository)
    }

    private static func stageFile(_ path: String, in workspace: URL, environment: [String: String]) async throws {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.resolvingSymlinksInPath().path == file.path else {
            throw AgentDispatchIntegrationError.unsafePath(path)
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            _ = try await git(["update-index", "--force-remove", "--", path], in: workspace, environment: environment)
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AgentDispatchIntegrationError.unsupportedFile(path)
        }
        // --no-filters avoids arbitrary clean filters and network-enabled LFS
        // helpers. Hash the exact bytes verified in the task's checkout.
        let hash = try await oid(["hash-object", "-w", "--no-filters", "--", path], in: workspace)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let mode = permissions & 0o111 == 0 ? "100644" : "100755"
        _ = try await git(["update-index", "--add", "--cacheinfo", "\(mode),\(hash),\(path)"], in: workspace, environment: environment)
    }

    private static func validatePath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !components.contains(where: {
                  let name = $0.lowercased()
                  return name == ".git" || name == ".env" || name.hasPrefix(".env.")
                      || name.hasSuffix(".pem") || name.hasSuffix(".key")
              }) else { throw AgentDispatchIntegrationError.unsafePath(path) }
        return path
    }

    private static func validateRevision(_ revision: String) throws {
        guard [40, 64].contains(revision.count), revision.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw AgentDispatchIntegrationError.invalidRevision
        }
    }

    private static func resolve(_ ref: String, in repository: URL) async throws -> String? {
        let result = try await git(["show-ref", "--verify", "--hash", ref], in: repository, allowedStatuses: [0, 1, 128])
        guard result.exitStatus == 0 else { return nil }
        let value = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateRevision(value)
        return value
    }

    private static func update(_ ref: String, to revision: String, expected: String?, in repository: URL) async throws {
        let result = try await git(
            ["update-ref", ref, revision, expected ?? String(repeating: "0", count: revision.count)],
            in: repository, allowedStatuses: [0, 1, 128]
        )
        guard result.exitStatus == 0 else { throw AgentDispatchIntegrationError.concurrentUpdate }
    }

    private static func oid(_ arguments: [String], in repository: URL, environment: [String: String] = [:]) async throws -> String {
        let result = try await git(arguments, in: repository, environment: environment)
        let value = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateRevision(value)
        return value
    }

    private static func git(
        _ arguments: [String], in repository: URL,
        environment overrides: [String: String] = [:], allowedStatuses: Set<Int32> = [0]
    ) async throws -> AgentSubprocess.Output {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false", "-c", "merge.renormalize=false",
        ] + arguments
        process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge([
            "GIT_AUTHOR_NAME": "WillDeep", "GIT_AUTHOR_EMAIL": "agent@localhost",
            "GIT_COMMITTER_NAME": "WillDeep", "GIT_COMMITTER_EMAIL": "agent@localhost",
            "GIT_TERMINAL_PROMPT": "0", "GIT_LITERAL_PATHSPECS": "1",
        ]) { _, new in new }
        environment.merge(overrides) { _, new in new }
        process.environment = environment
        let output = try await AgentSubprocess.run(process, timeout: commandTimeout, stdoutLimit: outputLimit, stderrLimit: outputLimit)
        guard !output.timedOut, !output.stdoutWasTruncated else { throw AgentDispatchIntegrationError.outputIncomplete }
        guard allowedStatuses.contains(output.exitStatus) else {
            throw AgentDispatchIntegrationError.commandFailed(operation: arguments.first ?? "git", status: output.exitStatus)
        }
        return output
    }
}
