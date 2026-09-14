//
//  AgentWorkspaceMutationGuard.swift
//  WillDeep
//
//  Optimistic concurrency protection for Git mutations issued by Agent
//  sessions. A revision is captured immediately before each model request.
//  Before a later `git add` / `git commit` / merge / push actually starts,
//  the host acquires a repository-scoped lease and compares the live checkout
//  with that revision. Any drift forces the model to inspect and validate the
//  new state instead of executing a command prepared against stale context.
//

import CryptoKit
import Darwin
import Foundation
import WillDeepCore

nonisolated struct AgentWorkspaceRevision: Equatable, Sendable {
    let repositoryRootPath: String
    let repositoryCommonDirectoryPath: String
    let headOID: String
    let branchName: String
    let stagedDigest: String
    let operationDigest: String
    let fileStates: [String: String]

    func difference(from expected: AgentWorkspaceRevision) -> AgentWorkspaceRevisionDifference {
        let paths = Set(fileStates.keys).union(expected.fileStates.keys)
        let changedPaths = paths.filter { fileStates[$0] != expected.fileStates[$0] }.sorted()
        return AgentWorkspaceRevisionDifference(
            repositoryChanged: repositoryRootPath != expected.repositoryRootPath
                || repositoryCommonDirectoryPath != expected.repositoryCommonDirectoryPath,
            headChanged: headOID != expected.headOID,
            branchChanged: branchName != expected.branchName,
            stagedChanged: stagedDigest != expected.stagedDigest,
            operationChanged: operationDigest != expected.operationDigest,
            changedPaths: changedPaths
        )
    }
}

nonisolated struct AgentWorkspaceRevisionDifference: Equatable, Sendable {
    let repositoryChanged: Bool
    let headChanged: Bool
    let branchChanged: Bool
    let stagedChanged: Bool
    let operationChanged: Bool
    let changedPaths: [String]

    var isEmpty: Bool {
        !repositoryChanged
            && !headChanged
            && !branchChanged
            && !stagedChanged
            && !operationChanged
            && changedPaths.isEmpty
    }

    var summaryLines: [String] {
        var lines: [String] = []
        if repositoryChanged { lines.append("repository/worktree identity changed") }
        if branchChanged { lines.append("checked-out branch changed") }
        if headChanged { lines.append("HEAD changed") }
        if stagedChanged { lines.append("staged index changed") }
        if operationChanged { lines.append("merge/rebase/cherry-pick state changed") }
        if !changedPaths.isEmpty {
            let visible = changedPaths.prefix(12).joined(separator: ", ")
            let remainder = changedPaths.count > 12 ? " (+\(changedPaths.count - 12) more)" : ""
            lines.append("changed paths: \(visible)\(remainder)")
        }
        return lines
    }
}

nonisolated struct AgentGuardedGitMutation: Equatable, Sendable {
    let actions: [String]

    var displayName: String {
        actions.joined(separator: " + ")
    }
}

nonisolated enum AgentWorkspaceMutationPolicy {
    private static let readOnlyGitSubcommands: Set<String> = [
        "annotate", "blame", "cat-file", "describe", "diff", "for-each-ref",
        "help", "log", "ls-files", "ls-remote", "ls-tree", "name-rev",
        "reflog", "rev-list", "rev-parse", "shortlog", "show", "status",
        "symbolic-ref", "var", "version", "whatchanged"
    ]

    static func guardedMutation(in command: String) -> AgentGuardedGitMutation? {
        let actions = SafeCommand.splitPipeline(command).flatMap { segment in
            guardedActions(in: SafeCommand.tokenize(segment), depth: 0)
        }
        guard !actions.isEmpty else { return nil }
        return AgentGuardedGitMutation(actions: actions)
    }

    private static func guardedActions(in tokens: [String], depth: Int) -> [String] {
        guard depth < 6, !tokens.isEmpty else { return [] }

        let first = executableName(tokens[0])
        if ["sh", "bash", "zsh"].contains(first),
           let commandIndex = shellCommandIndex(tokens),
           commandIndex < tokens.count {
            return guardedMutation(in: tokens[commandIndex])?.actions ?? []
        }

        if first == "env" {
            let nested = environmentCommandTokens(tokens)
            return nested.isEmpty ? [] : guardedActions(in: nested, depth: depth + 1)
        }

        if ["command", "time", "nice", "nohup"].contains(first) {
            return guardedActions(in: Array(tokens.dropFirst()), depth: depth + 1)
        }

        guard let gitIndex = tokens.firstIndex(where: { executableName($0) == "git" }) else {
            return []
        }
        let gitTokens = Array(tokens[gitIndex...])
        guard let subcommandIndex = gitSubcommandIndex(gitTokens), subcommandIndex < gitTokens.count else {
            return []
        }

        let subcommand = gitTokens[subcommandIndex].lowercased()
        let arguments = Array(gitTokens.dropFirst(subcommandIndex + 1))
        guard gitInvocationMutates(subcommand: subcommand, arguments: arguments) else {
            return []
        }
        return ["git \(subcommand)"]
    }

    private static func executableName(_ token: String) -> String {
        URL(fileURLWithPath: token).lastPathComponent.lowercased()
    }

    private static func shellCommandIndex(_ tokens: [String]) -> Int? {
        guard tokens.count > 2 else { return nil }
        for index in 1..<(tokens.count - 1) where tokens[index] == "-c" || tokens[index] == "-lc" {
            return index + 1
        }
        return nil
    }

    private static func environmentCommandTokens(_ tokens: [String]) -> [String] {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            if token.hasPrefix("-") || (token.contains("=") && !token.hasPrefix("=")) {
                index += 1
                continue
            }
            break
        }
        return index < tokens.count ? Array(tokens[index...]) : []
    }

    private static func gitSubcommandIndex(_ tokens: [String]) -> Int? {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            let lower = token.lowercased()
            if lower == "--" {
                return index + 1 < tokens.count ? index + 1 : nil
            }
            if ["-c", "-C", "--git-dir", "--work-tree", "--namespace"].contains(token) {
                index += 2
                continue
            }
            if lower.hasPrefix("--git-dir=")
                || lower.hasPrefix("--work-tree=")
                || lower.hasPrefix("--namespace=")
                || lower.hasPrefix("-c=") {
                index += 1
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

    private static func gitInvocationMutates(subcommand: String, arguments: [String]) -> Bool {
        if readOnlyGitSubcommands.contains(subcommand) { return false }

        switch subcommand {
        case "branch":
            return branchInvocationMutates(arguments)
        case "config":
            return configInvocationMutates(arguments)
        case "remote":
            return remoteInvocationMutates(arguments)
        case "stash":
            return !["list", "show"].contains(arguments.first?.lowercased() ?? "")
        case "tag":
            return tagInvocationMutates(arguments)
        case "worktree":
            return arguments.first?.lowercased() != "list"
        default:
            // Unknown Git subcommands are guarded conservatively. The guard
            // does not decide approval risk; it only prevents stale execution.
            return true
        }
    }

    private static func branchInvocationMutates(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        let mutatingFlags: Set<String> = [
            "-c", "-C", "-d", "-D", "-f", "-m", "-M", "--copy", "--delete",
            "--edit-description", "--force", "--move", "--set-upstream-to",
            "--unset-upstream"
        ]
        if arguments.contains(where: { mutatingFlags.contains($0) }) { return true }

        let readOnlyFlags: Set<String> = [
            "-a", "-r", "-l", "-v", "-vv", "--all", "--color", "--contains",
            "--format", "--ignore-case", "--list", "--merged", "--no-color",
            "--no-contains", "--no-merged", "--points-at", "--remotes", "--show-current",
            "--sort", "--verbose"
        ]
        return arguments.contains { argument in
            !argument.hasPrefix("-") && !readOnlyFlags.contains(argument)
        }
    }

    private static func configInvocationMutates(_ arguments: [String]) -> Bool {
        let readFlags: Set<String> = [
            "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
            "--name-only", "--show-origin", "--show-scope", "--type"
        ]
        if arguments.contains(where: { readFlags.contains($0) }) { return false }
        let positional = arguments.filter { !$0.hasPrefix("-") }
        return positional.count >= 2 || arguments.contains { argument in
            ["--add", "--edit", "--remove-section", "--rename-section", "--replace-all",
             "--unset", "--unset-all"].contains(argument)
        }
    }

    private static func remoteInvocationMutates(_ arguments: [String]) -> Bool {
        guard let first = arguments.first?.lowercased() else { return false }
        return !["-v", "get-url", "show"].contains(first)
    }

    private static func tagInvocationMutates(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        let mutatingFlags: Set<String> = ["-a", "-d", "-f", "-s", "-u", "--annotate", "--delete", "--force", "--sign"]
        if arguments.contains(where: { mutatingFlags.contains($0) }) { return true }
        let readFlags: Set<String> = [
            "-l", "--column", "--contains", "--format", "--ignore-case", "--list",
            "--merged", "--no-contains", "--no-merged", "--points-at", "--sort"
        ]
        if arguments.contains(where: { readFlags.contains($0) }) { return false }
        return true
    }
}

nonisolated enum AgentWorkspaceMutationGuardError: LocalizedError, Equatable {
    case multipleGitMutations([String])
    case backgroundGitMutation(String)
    case workspaceChanged(action: String, details: [String], activeSessions: [String])
    case leaseFailed(String)
    case leaseTimedOut

    var errorDescription: String? {
        switch self {
        case .multipleGitMutations(let actions):
            return "Blocked stale-prone Git command: run one Git mutation at a time, then inspect the result before continuing. Mutations: \(actions.joined(separator: ", "))."
        case .backgroundGitMutation(let action):
            return "Blocked \(action): guarded Git mutations must run in the foreground so WillDeep can hold the workspace lease and verify completion."
        case .workspaceChanged(let action, let details, let activeSessions):
            var lines = [
                "Blocked \(action): the workspace changed after this model round started, so the command was prepared against stale repository state.",
                "Detected changes:"
            ]
            lines.append(contentsOf: details.map { "- \($0)" })
            if !activeSessions.isEmpty {
                lines.append("Other active sessions in this workspace: \(activeSessions.joined(separator: ", ")).")
            }
            lines.append("Re-run git status and inspect staged, unstaged, and untracked changes. Re-run affected tests, then issue a new single Git mutation.")
            return lines.joined(separator: "\n")
        case .leaseFailed(let message):
            return "Could not acquire the WillDeep workspace mutation lease: \(message)"
        case .leaseTimedOut:
            return "Timed out waiting for another WillDeep session to finish its Git mutation. Inspect workspace sessions and retry after the active mutation completes."
        }
    }
}

/// Cross-session and cross-process advisory lease. Human editors do not honor
/// it, so correctness still comes from the revision comparison performed while
/// this lease is held. The lease closes the race between two WillDeep sessions.
nonisolated final class AgentWorkspaceMutationLease: @unchecked Sendable {
    private static let retryMicroseconds: useconds_t = 50_000
    private static let timeout: TimeInterval = 30

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquire(
        repositoryIdentity: String,
        lockDirectory: URL? = nil
    ) async throws -> AgentWorkspaceMutationLease {
        try await Task.detached(priority: .userInitiated) {
            let directory = lockDirectory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".willdeep/locks/workspace-mutations", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw AgentWorkspaceMutationGuardError.leaseFailed(error.localizedDescription)
            }

            let name = AgentWorkspaceRevisionCapture.sha256(repositoryIdentity)
            let url = directory.appendingPathComponent("\(name).lock")
            let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw AgentWorkspaceMutationGuardError.leaseFailed(String(cString: strerror(errno)))
            }

            let startedAt = Date()
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                if errno != EWOULDBLOCK && errno != EAGAIN {
                    let message = String(cString: strerror(errno))
                    close(descriptor)
                    throw AgentWorkspaceMutationGuardError.leaseFailed(message)
                }
                if Task.isCancelled {
                    close(descriptor)
                    throw CancellationError()
                }
                if Date().timeIntervalSince(startedAt) >= timeout {
                    close(descriptor)
                    throw AgentWorkspaceMutationGuardError.leaseTimedOut
                }
                usleep(retryMicroseconds)
            }
            return AgentWorkspaceMutationLease(descriptor: descriptor)
        }.value
    }
}

nonisolated enum AgentWorkspaceRevisionCapture {
    private static let operationMarkers = [
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
        "rebase-apply", "rebase-merge"
    ]
    private static let maximumHashPathsPerGitInvocation = 256

    static func capture(for directoryURL: URL?) async -> AgentWorkspaceRevision? {
        guard let directoryURL else { return nil }
        let target = directoryURL.standardizedFileURL
        return await Task.detached(priority: .utility) {
            captureSynchronously(for: target)
        }.value
    }

    static func repositoryIdentity(for directoryURL: URL?) async -> String? {
        guard let directoryURL else { return nil }
        let target = directoryURL.standardizedFileURL
        return await Task.detached(priority: .utility) {
            guard let repositoryRoot = AppState.findGitRepositoryRoot(startingAt: target) else {
                return nil
            }
            return repositoryCommonDirectory(for: repositoryRoot).standardizedFileURL.path
        }.value
    }

    static func sha256(_ value: String) -> String {
        hexDigest(SHA256.hash(data: Data(value.utf8)))
    }

    private static func captureSynchronously(for directoryURL: URL) -> AgentWorkspaceRevision? {
        guard let repositoryRoot = AppState.findGitRepositoryRoot(startingAt: directoryURL) else {
            return nil
        }
        // The mutation guard only needs a deterministic repository revision,
        // not one status row per untracked file. `-unormal` keeps an
        // untracked directory as one entry; directoryDigest still detects
        // changes inside legitimate directories, while hidden caches can be
        // rejected before they are recursively expanded.
        let status = AppState.loadGitStatus(
            for: repositoryRoot,
            enumerateUntrackedFiles: false
        )
        let head = gitOutput(
            arguments: ["rev-parse", "--verify", "HEAD"],
            in: repositoryRoot,
            allowedExitStatuses: [0, 128],
            retryEmptyOutput: true
        )
        let commonDirectory = repositoryCommonDirectory(for: repositoryRoot).path
        let stagedState = AppState.runGit(
            arguments: ["diff", "--cached", "--raw", "--no-abbrev", "--no-renames", "HEAD", "--"],
            in: repositoryRoot,
            allowedExitStatuses: [0, 128]
        )

        var fileStates: [String: String] = [:]
        var regularFilePaths: [(path: String, kind: GitFileStatusKind)] = []
        for (path, kind) in status.entries.sorted(by: { $0.key < $1.key }) {
            let url = repositoryRoot.appendingPathComponent(path).standardizedFileURL
            let rootPath = repositoryRoot.standardizedFileURL.path
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
                fileStates[path] = "\(kind.rawValue)|outside-repository"
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                fileStates[path] = "\(kind.rawValue)|missing"
                continue
            }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            // Build caches can contain tens of thousands of untracked files.
            // Git's normal untracked mode reports a top-level directory
            // without a trailing slash, so use the resource type to preserve
            // the distinction from a legitimate top-level file named
            // `.gocache`.
            let cacheProbePath = values?.isDirectory == true ? path + "/" : path
            guard !AppState.isHiddenCacheWorktreePath(cacheProbePath) else { continue }

            if values?.isRegularFile == true, values?.isSymbolicLink != true {
                regularFilePaths.append((path: path, kind: kind))
            } else if values?.isDirectory == true, values?.isSymbolicLink != true {
                let digest = untrackedDirectoryDigest(
                    relativePath: path,
                    repositoryRoot: repositoryRoot
                ) ?? directoryDigest(at: url)
                fileStates[path] = "\(kind.rawValue)|directory:\(digest)"
            } else {
                fileStates[path] = "\(kind.rawValue)|\(pathState(at: url))"
            }
        }

        // Hash regular files in bounded batches inside Git's native
        // implementation. The previous Swift loop opened every file and fed
        // it through CryptoKit separately; on a dirty workspace that occupied
        // a utility worker for most of every model round. `hash-object
        // --no-filters` preserves exact byte-level drift detection (including
        // same-size edits) while avoiding per-file FileHandle/Data churn.
        let contentDigests = batchedFileDigests(
            relativePaths: regularFilePaths.map(\.path),
            repositoryRoot: repositoryRoot
        )
        for item in regularFilePaths {
            let digest = contentDigests[item.path]
                ?? ((try? fileDigest(
                    at: repositoryRoot.appendingPathComponent(item.path)
                )) ?? "unreadable")
            fileStates[item.path] = "\(item.kind.rawValue)|file:\(digest)"
        }

        let operationState = operationMarkers.map { marker -> String in
            let rawPath = AppState.runGit(arguments: ["rev-parse", "--git-path", marker], in: repositoryRoot)
            guard let url = resolvedGitPath(rawPath, repositoryRoot: repositoryRoot) else {
                return "\(marker)=missing"
            }
            return "\(marker)=\(pathState(at: url))"
        }.joined(separator: "\n")

        // A ref update during capture would otherwise create a mixed revision
        // (old status plus new HEAD, or vice versa). Refuse the sample and let
        // the caller retry on its next model round instead of weakening CAS.
        let verifiedHead = gitOutput(
            arguments: ["rev-parse", "--verify", "HEAD"],
            in: repositoryRoot,
            allowedExitStatuses: [0, 128],
            retryEmptyOutput: true
        )
        guard verifiedHead == head else { return nil }

        return AgentWorkspaceRevision(
            repositoryRootPath: repositoryRoot.standardizedFileURL.path,
            repositoryCommonDirectoryPath: URL(fileURLWithPath: commonDirectory).standardizedFileURL.path,
            headOID: head,
            branchName: status.branchName ?? "detached",
            stagedDigest: sha256(stagedState),
            operationDigest: sha256(operationState),
            fileStates: fileStates
        )
    }

    private static func gitOutput(
        arguments: [String],
        in repositoryRoot: URL,
        allowedExitStatuses: Set<Int32>,
        retryEmptyOutput: Bool
    ) -> String {
        let maximumAttempts = retryEmptyOutput ? 3 : 1
        for attempt in 0..<maximumAttempts {
            let output = AppState.runGit(
                arguments: arguments,
                in: repositoryRoot,
                allowedExitStatuses: allowedExitStatuses
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !retryEmptyOutput || !output.isEmpty || attempt == maximumAttempts - 1 {
                return output
            }
        }
        return ""
    }

    private static func resolvedGitPath(_ rawPath: String, repositoryRoot: URL) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return repositoryRoot.appendingPathComponent(trimmed).standardizedFileURL
    }

    private static func repositoryCommonDirectory(for repositoryRoot: URL) -> URL {
        resolvedGitPath(
            AppState.runGit(arguments: ["rev-parse", "--git-common-dir"], in: repositoryRoot),
            repositoryRoot: repositoryRoot
        ) ?? repositoryRoot.appendingPathComponent(".git").standardizedFileURL
    }

    static func batchedFileDigests(
        relativePaths: [String],
        repositoryRoot: URL
    ) -> [String: String] {
        guard !relativePaths.isEmpty else { return [:] }

        var result: [String: String] = [:]
        var startIndex = 0
        while startIndex < relativePaths.count {
            let endIndex = min(
                startIndex + maximumHashPathsPerGitInvocation,
                relativePaths.count
            )
            let paths = Array(relativePaths[startIndex..<endIndex])
            let commandResult = AppState.runGitCommand(
                arguments: ["hash-object", "--no-filters", "--"] + paths,
                in: repositoryRoot
            )
            guard commandResult.succeeded else {
                startIndex = endIndex
                continue
            }
            let hashes = commandResult.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard hashes.count == paths.count else {
                startIndex = endIndex
                continue
            }
            for (path, hash) in zip(paths, hashes) {
                result[path] = hash
            }
            startIndex = endIndex
        }
        return result
    }

    private static func untrackedDirectoryDigest(
        relativePath: String,
        repositoryRoot: URL
    ) -> String? {
        let result = AppState.runGitCommand(
            arguments: ["ls-files", "--others", "--exclude-standard", "-z", "--", relativePath],
            in: repositoryRoot
        )
        guard result.succeeded,
              result.stdout.isEmpty || result.stdout.hasSuffix("\0") else {
            return nil
        }

        let maximumDigestEntries = 20_000
        let listedPaths = result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !AppState.isHiddenCacheWorktreePath($0) }
            .sorted()
        guard listedPaths.count <= maximumDigestEntries else { return nil }

        var regularFilePaths: [String] = []
        var specialStates: [String: String] = [:]
        let rootPath = repositoryRoot.standardizedFileURL.path + "/"
        for path in listedPaths {
            let url = repositoryRoot.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(rootPath) else {
                specialStates[path] = "outside-repository"
                continue
            }
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values?.isRegularFile == true, values?.isSymbolicLink != true {
                regularFilePaths.append(path)
            } else {
                specialStates[path] = pathState(at: url)
            }
        }

        let contentDigests = batchedFileDigests(
            relativePaths: regularFilePaths,
            repositoryRoot: repositoryRoot
        )
        let regularFilePathSet = Set(regularFilePaths)
        var hasher = SHA256()
        for path in listedPaths {
            let state: String
            if let digest = contentDigests[path] {
                state = "file:\(digest)"
            } else if regularFilePathSet.contains(path) {
                let url = repositoryRoot.appendingPathComponent(path)
                state = "file:\((try? fileDigest(at: url)) ?? "unreadable")"
            } else {
                state = specialStates[path] ?? "missing"
            }
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(state.utf8))
            hasher.update(data: Data([0]))
        }
        return hexDigest(hasher.finalize())
    }

    private static func pathState(at url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                return "symlink:\(sha256(destination))"
            }
            if values.isDirectory == true {
                return "directory:\(directoryDigest(at: url))"
            }
            if values.isRegularFile == true {
                return "file:\(try fileDigest(at: url))"
            }
            return "special"
        } catch {
            return "unreadable:\(error.localizedDescription)"
        }
    }

    private static func fileDigest(at url: URL) throws -> String {
        let fullHashBudget: UInt64 = 8 * 1_024 * 1_024
        let sampleBytes = Int(fullHashBudget / 2)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        if fileSize > fullHashBudget {
            let prefix = try handle.read(upToCount: sampleBytes) ?? Data()
            hasher.update(data: prefix)
            try handle.seek(toOffset: fileSize - UInt64(sampleBytes))
            let suffix = try handle.read(upToCount: sampleBytes) ?? Data()
            hasher.update(data: suffix)
            hasher.update(data: Data("sampled-size=\(fileSize)".utf8))
            return "sampled:" + hexDigest(hasher.finalize())
        }
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hexDigest(hasher.finalize())
    }

    private static func directoryDigest(at directory: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "unreadable"
        }
        let rootPath = directory.standardizedFileURL.path + "/"
        let maximumTraversalNodes = 50_000
        let maximumDigestEntries = 20_000
        var urls: [URL] = []
        var visited = 0
        var wasTruncated = false
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maximumTraversalNodes || urls.count >= maximumDigestEntries || Task.isCancelled {
                wasTruncated = true
                break
            }
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }
        var hasher = SHA256()
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(pathState(at: url).utf8))
            hasher.update(data: Data([0]))
        }
        if wasTruncated {
            hasher.update(data: Data("truncated-directory-digest".utf8))
        }
        return hexDigest(hasher.finalize())
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
