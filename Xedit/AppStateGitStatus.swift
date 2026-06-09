//
//  AppStateGitStatus.swift
//  VeilWriter
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Houses the pure-static git plumbing AppState uses for sidebar
//  status markers, the status-bar branch name, and the Agent-mode
//  worktree-change summary:
//
//    - GitFileStatusKind / GitRepositoryStatus value types
//    - ProcessOutputCollector / TimedProcessState helpers
//    - The nonisolated static `loadGitStatus`, `loadAgentWorktreeChangeSummary`,
//      and parsing helpers, attached to AppState by extension
//
//  None of this touches instance state — every entry point is
//  `nonisolated static`. The split is purely physical so AppState.swift
//  can drop under the CLAUDE.md §10 size budget.
//

import Foundation

extension AppState {
    nonisolated static func loadGitStatus(for directoryURL: URL) -> GitRepositoryStatus {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return GitRepositoryStatus()
        }

        let branch = runGit(arguments: ["branch", "--show-current"], in: repositoryRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusOutput = runGit(arguments: ["status", "--porcelain=v1", "-uall"], in: repositoryRoot)
        let entries = parseGitStatusPorcelain(statusOutput)

        return GitRepositoryStatus(
            repositoryRoot: repositoryRoot,
            branchName: branch.isEmpty ? "detached" : branch,
            entries: entries
        )
    }

    /// Build the summary that drives the "正在编辑 / N 个文件已更改" card.
    ///
    /// `restrictTo` is the per-session allow-list of workspace-relative
    /// paths the Agent has actually written via apply_patch. When non-nil
    /// we hard-filter the result to that set, so the user's own diffs
    /// and untracked junk (`__pycache__/*.pyc`, build artifacts, …)
    /// never get attributed to the Agent. Nil = legacy "whole worktree"
    /// fallback, used only for the global pre-session refresh path.
    nonisolated static func loadAgentWorktreeChangeSummary(
        status: GitRepositoryStatus,
        restrictTo: Set<String>? = nil
    ) -> AgentWorktreeChangeSummary {
        guard let repositoryRoot = status.repositoryRoot else {
            return AgentWorktreeChangeSummary()
        }

        let numstatOutput = runGit(arguments: ["diff", "--numstat", "HEAD", "--"], in: repositoryRoot)
        let lineStats = parseGitNumstat(numstatOutput)
        let files: [AgentFileChangeSummary] = status.entries.compactMap { entry in
            let path = entry.key
            let kind = entry.value
            if let restrictTo, !restrictTo.contains(path) {
                return nil
            }
            let stats = lineStats[path] ?? AgentLineChangeStats(added: nil, deleted: nil)
            let hasNumstatEntry = lineStats[path] != nil
            guard shouldIncludeAgentWorktreeChange(
                kind: kind,
                lineStats: stats,
                hasNumstatEntry: hasNumstatEntry
            ) else {
                return nil
            }
            return AgentFileChangeSummary(
                path: path,
                kind: kind,
                lineStats: stats
            )
        }

        return AgentWorktreeChangeSummary(repositoryRoot: repositoryRoot, files: files)
    }

    nonisolated static func shouldIncludeAgentWorktreeChange(
        kind: GitFileStatusKind,
        lineStats: AgentLineChangeStats,
        hasNumstatEntry: Bool
    ) -> Bool {
        if let added = lineStats.added, let deleted = lineStats.deleted {
            return added > 0 || deleted > 0
        }
        if hasNumstatEntry {
            return true
        }
        switch kind {
        case .added, .deleted, .renamed, .untracked:
            return true
        case .modified:
            return false
        }
    }

    nonisolated static func parseGitNumstat(_ output: String) -> [String: AgentLineChangeStats] {
        var result: [String: AgentLineChangeStats] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let added = Int(parts[0])
            let deleted = Int(parts[1])
            let path = parts.dropFirst(2).joined(separator: "\t")
            guard !path.isEmpty else { continue }

            result[String(path)] = AgentLineChangeStats(added: added, deleted: deleted)
        }

        return result
    }

    nonisolated static func formatLineStats(_ stats: AgentLineChangeStats) -> String {
        let added = stats.added.map { "+\($0)" } ?? "+?"
        let deleted = stats.deleted.map { "-\($0)" } ?? "-?"
        return "\(added) \(deleted)"
    }

    nonisolated static func parseGitStatusPorcelain(_ output: String) -> [String: GitFileStatusKind] {
        var result: [String: GitFileStatusKind] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 4 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            var path = String(line[pathStart...])
            if let renameRange = path.range(of: " -> ") {
                path = String(path[renameRange.upperBound...])
            }

            result[path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] = GitFileStatusKind(indexStatus: x, workTreeStatus: y)
        }

        return result
    }

    nonisolated static func findGitRepositoryRoot(startingAt directoryURL: URL) -> URL? {
        var currentURL = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        while true {
            if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(".git").path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            guard parentURL.path != currentURL.path else { return nil }
            currentURL = parentURL
        }
    }

    nonisolated static let maxGitOutputBytes = 512 * 1024
    nonisolated static let gitCommandTimeout: TimeInterval = 5

    nonisolated static func runGit(
        arguments: [String],
        in repositoryRoot: URL,
        allowedExitStatuses: Set<Int32> = [0]
    ) -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let collector = ProcessOutputCollector(limit: maxGitOutputBytes)
        let runState = TimedProcessState()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { current, _ in current }
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return ""
        }

        let timeoutWorkItem = DispatchWorkItem {
            runState.markTimedOut()
            if process.isRunning {
                process.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    process.interrupt()
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gitCommandTimeout, execute: timeoutWorkItem)

        process.waitUntilExit()
        timeoutWorkItem.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        collector.append(stdoutPipe.fileHandleForReading.availableData)

        guard !runState.didTimeout else { return "" }
        guard allowedExitStatuses.contains(process.terminationStatus) else { return "" }

        return collector.stringValue
    }
}

nonisolated final class ProcessOutputCollector: @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - data.count)
        guard remaining > 0 else { return }
        data.append(chunk.prefix(remaining))
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? AppState.decodeText(from: snapshot)
    }
}

nonisolated final class TimedProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeout: Bool {
        lock.lock()
        let value = timedOut
        lock.unlock()
        return value
    }
}

enum GitFileStatusKind: String, Equatable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"

    nonisolated init(indexStatus: Character, workTreeStatus: Character) {
        if indexStatus == "?" || workTreeStatus == "?" {
            self = .untracked
        } else if indexStatus == "A" || workTreeStatus == "A" {
            self = .added
        } else if indexStatus == "D" || workTreeStatus == "D" {
            self = .deleted
        } else if indexStatus == "R" || workTreeStatus == "R" {
            self = .renamed
        } else {
            self = .modified
        }
    }

    nonisolated static func aggregate(_ kinds: [GitFileStatusKind]) -> GitFileStatusKind? {
        kinds.max { $0.folderPriority < $1.folderPriority }
    }

    private nonisolated var folderPriority: Int {
        switch self {
        case .deleted:
            return 50
        case .renamed:
            return 40
        case .modified:
            return 30
        case .added:
            return 20
        case .untracked:
            return 10
        }
    }
}

struct GitRepositoryStatus: Equatable {
    var repositoryRoot: URL?
    var branchName: String?
    var entries: [String: GitFileStatusKind]

    nonisolated init(repositoryRoot: URL? = nil, branchName: String? = nil, entries: [String: GitFileStatusKind] = [:]) {
        self.repositoryRoot = repositoryRoot
        self.branchName = branchName
        self.entries = entries
    }

    nonisolated var isRepository: Bool {
        repositoryRoot != nil
    }

    nonisolated func kind(for url: URL) -> GitFileStatusKind? {
        guard let repositoryRoot else { return nil }
        let rootPath = repositoryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let kind = entries[relativePath] {
            return kind
        }

        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let childKinds = entries.compactMap { path, kind in
            path.hasPrefix(prefix) ? kind : nil
        }
        return GitFileStatusKind.aggregate(childKinds)
    }
}

extension AppState {
    func refreshGitStatus() {
        gitStatusRefreshTask?.cancel()

        guard let rootDirectory else {
            let emptyStatus = GitRepositoryStatus()
            let emptyChanges = AgentWorktreeChangeSummary()
            DispatchQueue.main.async { [weak self] in
                self?.gitStatus = emptyStatus
                self?.agentWorktreeChanges = emptyChanges
            }
            return
        }

        let targetDirectory = rootDirectory.standardizedFileURL
        let editedPaths = agentEditedRelativePaths
        gitStatusRefreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                let status = Self.loadGitStatus(for: targetDirectory)
                let changes = Self.loadAgentWorktreeChangeSummary(
                    status: status,
                    restrictTo: editedPaths
                )
                return (status: status, changes: changes)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.rootDirectory?.standardizedFileURL.path == targetDirectory.path else {
                    return
                }
                self.gitStatus = snapshot.status
                self.agentWorktreeChanges = snapshot.changes
            }
        }
    }

    func refreshActiveAgentWorktreeChanges() {
        guard let runtime = activeRuntime else {
            agentWorktreeChanges = .init()
            return
        }
        guard let workspaceRootPath = runtime.workspaceRootPath else {
            runtime.worktreeChanges = .init()
            return
        }

        let runtimeID = runtime.id
        let targetDirectory = URL(fileURLWithPath: workspaceRootPath).standardizedFileURL
        let editedPaths = runtime.agentEditedPaths
        Task { [weak self] in
            let snapshot = await Self.loadAgentWorktreeSnapshot(
                for: targetDirectory,
                restrictTo: editedPaths
            )
            await MainActor.run {
                guard let self,
                      let runtime = self.agentRuntimes[runtimeID],
                      runtime.workspaceRootPath == workspaceRootPath else {
                    return
                }

                runtime.worktreeChanges = snapshot.changes
                if self.rootDirectory?.standardizedFileURL.path == targetDirectory.path {
                    self.gitStatus = snapshot.status
                }
            }
        }
    }

    func refreshGitStatusAfterAgentTool(
        for runtime: AgentRuntime,
        workspaceURL: URL?,
        baselineFingerprint: String
    ) async {
        guard let workspaceURL else {
            refreshGitStatus()
            return
        }

        let targetDirectory = workspaceURL.standardizedFileURL
        let snapshot = await Self.loadAgentWorktreeSnapshot(
            for: targetDirectory,
            restrictTo: runtime.agentEditedPaths
        )

        runtime.worktreeChanges = snapshot.changes
        // didEditFiles flips on any real worktree movement (including
        // run_command side effects), keyed off fingerprint — NOT the
        // filtered card content, otherwise a run_command that touched
        // unrelated files would never trip it.
        if snapshot.fingerprint != baselineFingerprint {
            runtime.didEditFiles = true
            persistAgentSession(runtime: runtime)
        }

        if rootDirectory?.standardizedFileURL.path == targetDirectory.path {
            gitStatus = snapshot.status
            if activeRuntime === runtime {
                agentWorktreeChanges = snapshot.changes
            }
        }
    }

    struct AgentWorktreeSnapshot {
        var status: GitRepositoryStatus
        var changes: AgentWorktreeChangeSummary
        var fingerprint: String
    }

    nonisolated static func loadAgentWorktreeSnapshot(
        for directoryURL: URL?,
        restrictTo: Set<String>? = nil
    ) async -> AgentWorktreeSnapshot {
        guard let directoryURL else {
            return AgentWorktreeSnapshot(
                status: GitRepositoryStatus(),
                changes: AgentWorktreeChangeSummary(),
                fingerprint: ""
            )
        }
        let targetDirectory = directoryURL.standardizedFileURL
        return await Task.detached(priority: .utility) {
            let status = Self.loadGitStatus(for: targetDirectory)
            let changes = Self.loadAgentWorktreeChangeSummary(status: status, restrictTo: restrictTo)
            let fingerprint = Self.agentWorktreeFingerprint(status: status)
            return AgentWorktreeSnapshot(status: status, changes: changes, fingerprint: fingerprint)
        }.value
    }

    nonisolated static func agentWorktreeFingerprint(status: GitRepositoryStatus) -> String {
        guard let repositoryRoot = status.repositoryRoot else { return "" }
        let entries = status.entries
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key):\($0.value.rawValue)" }
            .joined(separator: "\n")
        let rawDiff = runGit(arguments: ["diff", "--raw", "HEAD", "--"], in: repositoryRoot)
        return entries + "\n" + rawDiff
    }

    nonisolated static func loadAgentWorktreeDiffPreview(
        changes: AgentWorktreeChangeSummary,
        repositoryRoot: URL
    ) -> AgentWorktreeDiffPreview {
        var sections: [String] = []
        let trackedDiff = runGit(
            arguments: ["diff", "--no-ext-diff", "HEAD", "--"],
            in: repositoryRoot
        )
        if !trackedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(trackedDiff)
        }

        for change in changes.files where change.kind == .untracked {
            let untrackedDiff = runGit(
                arguments: ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", change.path],
                in: repositoryRoot,
                allowedExitStatuses: [0, 1]
            )
            if !untrackedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(untrackedDiff)
            }
        }

        var diff = sections.joined(separator: "\n")
        if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diff = "当前没有可显示的 diff。"
        } else if diff.count > maxGitOutputBytes {
            let end = diff.index(diff.startIndex, offsetBy: maxGitOutputBytes)
            diff = String(diff[..<end]) + "\n\n... diff output truncated ..."
        }

        return AgentWorktreeDiffPreview(
            title: "\(changes.fileCount) 个文件已更改 +\(changes.totalAddedLines) -\(changes.totalDeletedLines)",
            diff: diff
        )
    }

}
