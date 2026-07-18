//
//  AppStateGitStatus.swift
//  WillDeep
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

enum AgentUntrackedDiffPreviewSection: Equatable {
    case diff(String)
    case summaryReason(String)
}

extension AppState {
    nonisolated static func loadGitStatus(
        for directoryURL: URL,
        enumerateUntrackedFiles: Bool = true
    ) -> GitRepositoryStatus {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return GitRepositoryStatus()
        }

        let branch = runGit(arguments: ["branch", "--show-current"], in: repositoryRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let untrackedMode = enumerateUntrackedFiles ? "-uall" : "-unormal"
        let statusOutput = runGit(
            arguments: ["status", "--porcelain=v1", untrackedMode],
            in: repositoryRoot
        )
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

    /// 解码 git 的 C 风格带引号路径。即使加了 `core.quotePath=false`,
    /// git 对含双引号 / 反斜杠 / 制表符 / 换行等特殊字节的路径仍会用
    /// `"..."` 包裹并转义;这里做兜底解码,保证任何路径都还原成可读文本。
    /// 非引号包裹的路径原样返回。
    ///
    /// 转义规则(对应 git unquote):`\\` `\"` `\t` `\n` `\r`,以及 `\NNN`
    /// 三位八进制字节。多字节 UTF-8(如中文)是连续多个 `\NNN`,必须先收成
    /// 字节再整体按 UTF-8 解码,不能逐字节当字符。
    nonisolated static func unquoteGitPath(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        let inner = Array(raw.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var i = 0
        while i < inner.count {
            let ch = inner[i]
            if ch == "\\", i + 1 < inner.count {
                let next = inner[i + 1]
                switch next {
                case "n": bytes.append(0x0A); i += 2
                case "t": bytes.append(0x09); i += 2
                case "r": bytes.append(0x0D); i += 2
                case "\"": bytes.append(0x22); i += 2
                case "\\": bytes.append(0x5C); i += 2
                default:
                    // \NNN 三位八进制
                    if i + 3 < inner.count,
                       next.isNumber,
                       let b = UInt8(String(inner[(i + 1)...(i + 3)]), radix: 8) {
                        bytes.append(b)
                        i += 4
                    } else {
                        bytes.append(contentsOf: Array(String(ch).utf8))
                        i += 1
                    }
                }
            } else {
                bytes.append(contentsOf: Array(String(ch).utf8))
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated static func parseGitNumstat(_ output: String) -> [String: AgentLineChangeStats] {
        var result: [String: AgentLineChangeStats] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let added = Int(parts[0])
            let deleted = Int(parts[1])
            let path = unquoteGitPath(parts.dropFirst(2).joined(separator: "\t"))
            guard !path.isEmpty else { continue }

            result[path] = AgentLineChangeStats(added: added, deleted: deleted)
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
            path = unquoteGitPath(path)

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

        let topLevel = runGit(arguments: ["rev-parse", "--show-toplevel"], in: currentURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !topLevel.isEmpty {
            return URL(fileURLWithPath: topLevel).standardizedFileURL
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
    nonisolated static let worktreeDiffPreviewMaxFiles = 40
    nonisolated static let worktreeDiffPreviewMaxChangedLines = 1_200
    nonisolated static let worktreeDiffPreviewMaxUTF8Bytes = 96 * 1024
    nonisolated static let worktreeDiffPreviewGeneratedFileThreshold = 8
    nonisolated static let worktreeDiffPreviewFileListLimit = 80
    nonisolated static let worktreeDiffPreviewMaxUntrackedFileBytes = 64 * 1024
    nonisolated static let worktreeDiffPreviewMaxUntrackedTotalBytes = 96 * 1024

    nonisolated static func runGit(
        arguments: [String],
        in repositoryRoot: URL,
        allowedExitStatuses: Set<Int32> = [0]
    ) -> String {
        let result = runGitCommand(
            arguments: arguments,
            in: repositoryRoot,
            allowedExitStatuses: allowedExitStatuses
        )
        return result.succeeded ? result.stdout : ""
    }

    nonisolated static func runGitCommand(
        arguments: [String],
        in repositoryRoot: URL,
        allowedExitStatuses: Set<Int32> = [0]
    ) -> GitCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCollector = ProcessOutputCollector(limit: maxGitOutputBytes)
        let stderrCollector = ProcessOutputCollector(limit: maxGitOutputBytes)
        let runState = TimedProcessState()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // `core.quotePath=false`:git 默认把路径里的非 ASCII 字节用八进制
        // 转义(并加双引号)输出,中文文件名于是显示成 "\351\207\215…"
        // (用户反馈:composer 上方已更改文件列表全是反斜杠数字)。关掉它
        // 让 git 直接吐 UTF-8 路径。`-c key=value` 是全局选项,必须排在子
        // 命令前面,所以前插到 arguments。对所有 git 调用统一生效(status /
        // diff numstat / branch / worktree list / rev-parse …)。
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { current, _ in current }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutCollector.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrCollector.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return GitCommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
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
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() {
            stdoutCollector.append(tail)
        }
        if let tail = try? stderrPipe.fileHandleForReading.readToEnd() {
            stderrCollector.append(tail)
        }

        return GitCommandResult(
            status: process.terminationStatus,
            stdout: stdoutCollector.stringValue,
            stderr: stderrCollector.stringValue,
            timedOut: runState.didTimeout,
            allowedExitStatuses: allowedExitStatuses
        )
    }
}

struct GitCommandResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var allowedExitStatuses: Set<Int32>

    nonisolated init(
        status: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        allowedExitStatuses: Set<Int32> = [0]
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.allowedExitStatuses = allowedExitStatuses
    }

    nonisolated var succeeded: Bool {
        !timedOut && allowedExitStatuses.contains(status)
    }

    nonisolated var userMessage: String {
        if timedOut { return "git command timed out" }
        let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { return details }
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        return "git exited with status \(status)"
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
                guard let self else { return }
                if self.gitStatus != emptyStatus {
                    self.gitStatus = emptyStatus
                }
                if self.agentWorktreeChanges != emptyChanges {
                    self.agentWorktreeChanges = emptyChanges
                }
            }
            return
        }

        let targetDirectory = rootDirectory.standardizedFileURL
        let editedPaths = agentEditedRelativePaths
        gitStatusRefreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                // Workspace selection only needs a fast first snapshot. Using
                // -uall here can recursively enumerate enormous untracked
                // build/vendor directories and has caused multi-GB git peaks.
                let status = Self.loadGitStatus(
                    for: targetDirectory,
                    enumerateUntrackedFiles: false
                )
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
                if self.gitStatus != snapshot.status {
                    self.gitStatus = snapshot.status
                }
                if self.agentWorktreeChanges != snapshot.changes {
                    self.agentWorktreeChanges = snapshot.changes
                }
            }
        }
    }

    func refreshActiveAgentWorktreeChanges() {
        guard let runtime = activeRuntime else {
            let empty = AgentWorktreeChangeSummary()
            if agentWorktreeChanges != empty {
                agentWorktreeChanges = empty
            }
            return
        }
        let workspaceURL: URL?
        do {
            workspaceURL = try runtime.localWorkspaceURLForOptimisticUse()
        } catch {
            let empty = AgentWorktreeChangeSummary()
            if runtime.worktreeChanges != empty {
                runtime.worktreeChanges = empty
            }
            if agentWorktreeChanges != empty {
                agentWorktreeChanges = empty
            }
            return
        }
        guard let targetDirectory = workspaceURL else {
            let empty = AgentWorktreeChangeSummary()
            if runtime.worktreeChanges != empty {
                runtime.worktreeChanges = empty
            }
            return
        }

        let runtimeID = runtime.id
        let editedPaths = runtime.agentEditedPaths
        Task { [weak self] in
            let snapshot = await Self.loadAgentWorktreeSnapshot(
                for: targetDirectory,
                restrictTo: editedPaths
            )
            await MainActor.run {
                guard let self,
                      let runtime = self.agentRuntimes[runtimeID],
                      runtime.workspaceRootPath == targetDirectory.path else {
                    return
                }

                if runtime.worktreeChanges != snapshot.changes {
                    runtime.worktreeChanges = snapshot.changes
                }
                if self.rootDirectory?.standardizedFileURL.path == targetDirectory.path {
                    if self.gitStatus != snapshot.status {
                        self.gitStatus = snapshot.status
                    }
                }
            }
        }
    }

    func refreshGitStatusAfterAgentTool(
        for runtime: AgentRuntime,
        workspaceURL: URL?,
        baselineSnapshot: AgentWorktreeSnapshot
    ) async {
        guard let workspaceURL else {
            refreshGitStatus()
            return
        }

        let targetDirectory = workspaceURL.standardizedFileURL
        let snapshot = await Self.loadAgentWorktreeSnapshot(
            for: targetDirectory,
            captureArtifactFiles: true
        )
        let changedPaths = Self.agentWorktreePathsChangedSinceBaseline(
            baseline: baselineSnapshot,
            current: snapshot
        )
        let createdArtifactPaths = Self.agentArtifactPathsCreatedSinceBaseline(
            baseline: baselineSnapshot,
            current: snapshot
        )
        let attributedPaths = runtime.agentEditedPaths.union(changedPaths)

        let filteredChanges = snapshot.changes.filtering(paths: attributedPaths)
        if runtime.worktreeChanges != filteredChanges {
            runtime.worktreeChanges = filteredChanges
        }
        var shouldPersistSession = false

        // didEditFiles flips on any real worktree movement (including
        // run_command side effects), but only after attributing changed paths
        // against this turn's baseline. Pre-existing user diffs should not
        // light up the Agent's worktree card or right-rail artifact list.
        if snapshot.fingerprint != baselineSnapshot.fingerprint, !attributedPaths.isEmpty {
            runtime.agentEditedPaths = attributedPaths
            runtime.didEditFiles = true
            shouldPersistSession = true
        }
        if !createdArtifactPaths.isEmpty {
            runtime.agentArtifactPaths.formUnion(createdArtifactPaths)
            shouldPersistSession = true
        }
        if shouldPersistSession {
            persistAgentSession(runtime: runtime)
        }

        if rootDirectory?.standardizedFileURL.path == targetDirectory.path {
            if gitStatus != snapshot.status {
                gitStatus = snapshot.status
            }
            if activeRuntime === runtime {
                if agentWorktreeChanges != runtime.worktreeChanges {
                    agentWorktreeChanges = runtime.worktreeChanges
                }
            }
        }
    }

    struct AgentWorktreeSnapshot {
        var status: GitRepositoryStatus
        var changes: AgentWorktreeChangeSummary
        var fingerprint: String
        var fileSignatures: [String: String]
        /// User-facing document/media files found directly on disk. This is
        /// intentionally independent from Git so `.gitignore` cannot hide a
        /// real conversation output.
        var artifactFileSignatures: [String: String] = [:]
    }

    nonisolated static func loadAgentWorktreeSnapshot(
        for directoryURL: URL?,
        restrictTo: Set<String>? = nil,
        captureArtifactFiles: Bool = false
    ) async -> AgentWorktreeSnapshot {
        guard let directoryURL else {
            return AgentWorktreeSnapshot(
                status: GitRepositoryStatus(),
                changes: AgentWorktreeChangeSummary(),
                fingerprint: "",
                fileSignatures: [:]
            )
        }
        let targetDirectory = directoryURL.standardizedFileURL
        return await Task.detached(priority: .utility) {
            let status = Self.loadGitStatus(for: targetDirectory)
            let changes = Self.loadAgentWorktreeChangeSummary(status: status, restrictTo: restrictTo)
            let fingerprint = Self.agentWorktreeFingerprint(status: status)
            let fileSignatures = Self.agentWorktreeFileSignatures(status: status)
            let artifactFileSignatures = captureArtifactFiles
                ? Self.agentArtifactFileSignatures(in: targetDirectory)
                : [:]
            return AgentWorktreeSnapshot(
                status: status,
                changes: changes,
                fingerprint: fingerprint,
                fileSignatures: fileSignatures,
                artifactFileSignatures: artifactFileSignatures
            )
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

    nonisolated static func agentWorktreeFileSignatures(status: GitRepositoryStatus) -> [String: String] {
        guard let repositoryRoot = status.repositoryRoot else { return [:] }
        let numstatOutput = runGit(arguments: ["diff", "--numstat", "HEAD", "--"], in: repositoryRoot)
        let lineStats = parseGitNumstat(numstatOutput)
        return status.entries.reduce(into: [String: String]()) { result, item in
            let path = item.key
            let kind = item.value
            let stats = lineStats[path]
            let fileURL = repositoryRoot.appendingPathComponent(path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size: String
            if let sizeValue = attributes?[.size] as? NSNumber {
                size = String(sizeValue.int64Value)
            } else {
                size = "missing"
            }
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let added = stats?.added.map(String.init) ?? "?"
            let deleted = stats?.deleted.map(String.init) ?? "?"
            result[path] = [
                kind.rawValue,
                "added=\(added)",
                "deleted=\(deleted)",
                "size=\(size)",
                "mtime=\(modified)",
            ].joined(separator: "|")
        }
    }

    nonisolated static func agentWorktreePathsChangedSinceBaseline(
        baseline: AgentWorktreeSnapshot,
        current: AgentWorktreeSnapshot
    ) -> Set<String> {
        Set(current.changes.files.compactMap { change in
            let path = change.path
            return current.fileSignatures[path] != baseline.fileSignatures[path] ? path : nil
        })
    }

    /// Returns user-facing files newly created during one Agent tool turn.
    /// This deliberately does not equate "anything Git noticed" with an
    /// artifact: existing modified files belong in Work Files, while build
    /// products and caches are transient implementation detail.
    nonisolated static func agentArtifactPathsCreatedSinceBaseline(
        baseline: AgentWorktreeSnapshot,
        current: AgentWorktreeSnapshot
    ) -> Set<String> {
        Set(current.artifactFileSignatures.keys.filter { path in
            baseline.artifactFileSignatures[path] == nil
        })
    }

    /// Lightweight, Git-independent inventory of files that can be surfaced
    /// as conversation artifacts. Transient trees are pruned before descent,
    /// avoiding the cost and noise of build products, dependencies and caches.
    nonisolated static func agentArtifactFileSignatures(in directoryURL: URL) -> [String: String] {
        let root = directoryURL.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        var signatures: [String: String] = [:]
        var visitedNodes = 0
        let maximumTraversalNodes = 50_000
        for case let fileURL as URL in enumerator {
            visitedNodes += 1
            if visitedNodes > maximumTraversalNodes || Task.isCancelled { break }
            let standardized = fileURL.standardizedFileURL
            guard standardized.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(standardized.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { continue }
            let values = try? standardized.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if isAgentTransientArtifactDirectory(relativePath) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true,
                  isAgentSessionArtifactPath(relativePath) else {
                continue
            }
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
            signatures[relativePath] = "size=\(size)|mtime=\(modified)"
        }
        return signatures
    }

    nonisolated static func isAgentTransientArtifactDirectory(_ path: String) -> Bool {
        let transientComponents: Set<String> = [
            ".git", ".build", "build", "deriveddata", "node_modules",
            ".local-cache", "cache", "caches", "tmp", "temp",
            "__pycache__", ".pytest_cache", "coverage"
        ]
        return path.split(separator: "/").contains { component in
            transientComponents.contains(component.lowercased())
        }
    }

    /// Artifact is a conversation-created, user-consumable document or media
    /// file. Source edits and transient build/cache trees stay under Work
    /// Files, where their Git-oriented semantics are explicit.
    nonisolated static func isAgentSessionArtifactPath(_ path: String) -> Bool {
        guard !isAgentTransientArtifactDirectory(path) else {
            return false
        }

        let artifactExtensions: Set<String> = [
            "md", "markdown", "txt", "html", "pdf", "csv", "json",
            "xlsx", "xls", "docx", "pptx", "png", "jpg", "jpeg",
            "gif", "webp", "heic", "svg", "mp4", "mov", "m4v",
            "webm", "avi", "mp3", "wav", "m4a", "aac", "zip"
        ]
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return artifactExtensions.contains(ext)
    }

    nonisolated static func loadAgentWorktreeDiffPreview(
        changes: AgentWorktreeChangeSummary,
        repositoryRoot: URL
    ) -> AgentWorktreeDiffPreview {
        var summaryReasons = worktreeDiffPreviewSummaryReasons(for: changes)
        if summaryReasons.isEmpty {
            summaryReasons = worktreeDiffPreviewUntrackedSummaryReasons(
                for: changes,
                repositoryRoot: repositoryRoot
            )
        }
        if !summaryReasons.isEmpty {
            return AgentWorktreeDiffPreview(
                title: "\(changes.fileCount) 个文件已更改 +\(changes.totalAddedLines) -\(changes.totalDeletedLines)",
                diff: worktreeDiffPreviewSummaryText(changes: changes, reasons: summaryReasons)
            )
        }

        var sections: [String] = []
        for change in changes.files where change.kind == .untracked {
            switch loadUntrackedDiffPreviewSection(change, repositoryRoot: repositoryRoot) {
            case .diff(let diff):
                if !diff.isEmpty {
                    sections.append(diff)
                }
            case .summaryReason(let reason):
                return AgentWorktreeDiffPreview(
                    title: "\(changes.fileCount) 个文件已更改 +\(changes.totalAddedLines) -\(changes.totalDeletedLines)",
                    diff: worktreeDiffPreviewSummaryText(changes: changes, reasons: [reason])
                )
            }
        }

        let trackedPaths = changes.files
            .filter { $0.kind != .untracked }
            .map(\.path)
        if !trackedPaths.isEmpty {
            let trackedDiff = runGit(
                arguments: ["diff", "--no-ext-diff", "HEAD", "--"] + trackedPaths,
                in: repositoryRoot
            )
            if !trackedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(trackedDiff)
            }
        }

        var diff = sections.joined(separator: "\n")
        if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diff = "当前没有可显示的 diff。"
        } else if diff.utf8.count > worktreeDiffPreviewMaxUTF8Bytes {
            diff = worktreeDiffPreviewSummaryText(
                changes: changes,
                reasons: ["diff 的 UTF-8 数据超过 \(worktreeDiffPreviewMaxUTF8Bytes / 1024)KB，已降级为摘要，避免界面渲染长文本。"],
                sample: AgentSidePanelDiffLimiter.utf8Prefix(diff, maximumBytes: 24 * 1024)
            )
        }

        return AgentWorktreeDiffPreview(
            title: "\(changes.fileCount) 个文件已更改 +\(changes.totalAddedLines) -\(changes.totalDeletedLines)",
            diff: diff
        )
    }

    /// Untracked files have no `git diff --numstat` entry, so their line
    /// counts appear as `+0 -0`. Running `git diff --no-index` once per file
    /// made seven such files wait on seven sequential child processes. Read
    /// bounded, regular UTF-8 files directly instead; large/binary/special
    /// files are summarized before any expensive diff rendering begins.
    nonisolated static func loadUntrackedDiffPreviewSection(
        _ change: AgentFileChangeSummary,
        repositoryRoot: URL
    ) -> AgentUntrackedDiffPreviewSection {
        let fileURL = repositoryRoot.appendingPathComponent(change.path).standardizedFileURL
        let rootPath = repositoryRoot.standardizedFileURL.path
        guard fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/") else {
            return .summaryReason("未跟踪文件 \(change.path) 超出工作区范围，已跳过完整内容。")
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            return .summaryReason("未跟踪文件 \(change.path) 不是可安全预览的普通文件。")
        }
        guard fileSize <= worktreeDiffPreviewMaxUntrackedFileBytes else {
            return .summaryReason(
                "未跟踪文件 \(change.path) 超过 \(worktreeDiffPreviewMaxUntrackedFileBytes / 1024)KB，已跳过完整内容。"
            )
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: worktreeDiffPreviewMaxUntrackedFileBytes + 1) ?? Data()
        } catch {
            return .summaryReason("未跟踪文件 \(change.path) 无法读取，已跳过完整内容。")
        }
        guard data.count <= worktreeDiffPreviewMaxUntrackedFileBytes else {
            return .summaryReason("未跟踪文件 \(change.path) 在读取时变大，已跳过完整内容。")
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .summaryReason("未跟踪文件 \(change.path) 是二进制或非 UTF-8 文件，已跳过完整内容。")
        }

        return .diff(syntheticUntrackedDiff(path: change.path, text: text))
    }

    nonisolated static func syntheticUntrackedDiff(path: String, text: String) -> String {
        guard !text.isEmpty else { return "" }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hasFinalNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasFinalNewline, lines.last == "" {
            lines.removeLast()
        }

        var output = [
            "diff --git a/\(path) b/\(path)",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/\(path)",
            "@@ -0,0 +1,\(lines.count) @@"
        ]
        output.append(contentsOf: lines.map { "+\($0)" })
        if !hasFinalNewline {
            output.append("\\ No newline at end of file")
        }
        return output.joined(separator: "\n")
    }

    nonisolated static func worktreeDiffPreviewUntrackedSummaryReasons(
        for changes: AgentWorktreeChangeSummary,
        repositoryRoot: URL
    ) -> [String] {
        var totalBytes = 0
        var oversizedCount = 0
        var unsupportedCount = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootPath = repositoryRoot.standardizedFileURL.path

        for change in changes.files where change.kind == .untracked {
            let fileURL = repositoryRoot.appendingPathComponent(change.path).standardizedFileURL
            guard (fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/")),
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize else {
                unsupportedCount += 1
                continue
            }
            if fileSize > worktreeDiffPreviewMaxUntrackedFileBytes {
                oversizedCount += 1
            }
            if totalBytes <= worktreeDiffPreviewMaxUntrackedTotalBytes {
                totalBytes += min(fileSize, worktreeDiffPreviewMaxUntrackedTotalBytes + 1)
            }
        }

        var reasons: [String] = []
        if oversizedCount > 0 {
            reasons.append(
                "\(oversizedCount) 个未跟踪文件超过单文件 \(worktreeDiffPreviewMaxUntrackedFileBytes / 1024)KB 的预览上限。"
            )
        }
        if totalBytes > worktreeDiffPreviewMaxUntrackedTotalBytes {
            reasons.append(
                "未跟踪文件合计超过 \(worktreeDiffPreviewMaxUntrackedTotalBytes / 1024)KB 的完整预览上限。"
            )
        }
        if unsupportedCount > 0 {
            reasons.append("\(unsupportedCount) 个未跟踪路径不是可安全预览的普通文件。")
        }
        return reasons
    }

    nonisolated static func worktreeDiffPreviewSummaryReasons(
        for changes: AgentWorktreeChangeSummary
    ) -> [String] {
        var reasons: [String] = []
        if changes.fileCount > worktreeDiffPreviewMaxFiles {
            reasons.append("\(changes.fileCount) 个文件超过 \(worktreeDiffPreviewMaxFiles) 个文件的完整 diff 展示阈值。")
        }

        let changedLines = changes.totalAddedLines + changes.totalDeletedLines
        if changedLines > worktreeDiffPreviewMaxChangedLines {
            reasons.append("\(changedLines) 行变更超过 \(worktreeDiffPreviewMaxChangedLines) 行的完整 diff 展示阈值。")
        }

        let generatedCount = changes.files.filter { isGeneratedWebDiffPath($0.path) }.count
        if generatedCount >= worktreeDiffPreviewGeneratedFileThreshold {
            reasons.append("\(generatedCount) 个文件位于疑似前端构建产物目录，已跳过完整 hunk 渲染。")
        }
        return reasons
    }

    nonisolated static func isGeneratedWebDiffPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let components = lower.split(separator: "/").map(String.init)
        let generatedDirectory = components.contains { component in
            component == "dist" ||
            component == "build" ||
            component == ".vite" ||
            component == "node_modules" ||
            component.hasSuffix("-dist") ||
            component.hasSuffix("-web-dist") ||
            component.contains("prebuilt-web-dist")
        }
        guard generatedDirectory else { return false }

        let ext = URL(fileURLWithPath: lower).pathExtension
        if ext.isEmpty { return true }
        return [
            "js", "mjs", "cjs", "css", "map", "wasm", "html",
            "svg", "png", "jpg", "jpeg", "webp", "avif", "woff", "woff2"
        ].contains(ext)
    }

    nonisolated static func worktreeDiffPreviewSummaryText(
        changes: AgentWorktreeChangeSummary,
        reasons: [String],
        sample: String? = nil
    ) -> String {
        var lines: [String] = [
            "Diff 预览已降级，未展示完整内容。",
            "这样可以避免大量文件或构建产物 diff 拖慢界面渲染。",
            "",
            "原因："
        ]
        lines.append(contentsOf: reasons.map { "- \($0)" })
        lines.append("")
        lines.append("文件摘要：")

        let listedFiles = changes.files.prefix(worktreeDiffPreviewFileListLimit)
        for change in listedFiles {
            lines.append(worktreeDiffPreviewFileSummaryLine(change))
        }

        let omitted = changes.files.count - listedFiles.count
        if omitted > 0 {
            lines.append("... 另外 \(omitted) 个文件未列出 ...")
        }

        if let sample, !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("前 \(sample.count) 个字符预览：")
            lines.append(sample)
            lines.append("")
            lines.append("... diff output truncated ...")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func worktreeDiffPreviewFileSummaryLine(
        _ change: AgentFileChangeSummary
    ) -> String {
        let marker: String
        switch change.kind {
        case .added, .untracked:
            marker = "A"
        case .deleted:
            marker = "D"
        case .renamed:
            marker = "R"
        case .modified:
            marker = "M"
        }

        let stats: String
        if change.hasKnownLineStats {
            stats = " +\(change.addedLines) -\(change.deletedLines)"
        } else {
            stats = ""
        }
        return "\(marker) \(change.path)\(stats)"
    }

}
