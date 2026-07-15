//
//  AgentGitWorktrees.swift
//  WillDeep
//
//  Local Git worktree support for Agent composer workspaces. Sessions
//  still bind to a normal local workspace path; the git metadata here is
//  discovered on demand so old session JSON keeps loading unchanged.
//

import AppKit
import Foundation

struct AgentGitWorktree: Identifiable, Equatable {
    var path: String
    var head: String?
    var branch: String?
    var isBare: Bool
    var isDetached: Bool
    var isPrunable: Bool
    var pruneReason: String?
    var isPrimary: Bool

    nonisolated var id: String { path }

    nonisolated var url: URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    nonisolated var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }

    nonisolated var branchLabel: String {
        if let branch, !branch.isEmpty { return branch }
        if isDetached { return "detached" }
        return "unknown"
    }
}

struct AgentGitWorktreeCreateResult: Equatable {
    var worktree: AgentGitWorktree
    var output: String
}

struct AgentGitWorktreeFailure: Error, Equatable {
    var message: String
    var wasCancelled = false
}

struct AgentGitWorktreeCreation: Identifiable, Equatable {
    let id: UUID
    let sessionID: AgentSession.ID
    let branchName: String
    let startedAt: Date
    var output: String
    var progress: Double?
    var isCancelling: Bool
}

nonisolated final class AgentGitWorktreeProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeProcess = process
        lock.unlock()
        if let activeProcess, activeProcess.isRunning {
            activeProcess.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

nonisolated private final class AgentGitWorktreeOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let onUpdate: @Sendable (String) -> Void
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int, onUpdate: @escaping @Sendable (String) -> Void) {
        self.limit = limit
        self.onUpdate = onUpdate
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        let snapshot = data
        lock.unlock()
        onUpdate(Self.visibleText(from: snapshot))
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return Self.visibleText(from: snapshot)
    }

    private static func visibleText(from data: Data) -> String {
        let decoded = String(data: data, encoding: .utf8) ?? AppState.decodeText(from: data)
        return decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

extension AppState {
    nonisolated static func parseGitWorktreeListPorcelain(_ output: String) -> [AgentGitWorktree] {
        var records: [[String]] = []
        var current: [String] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .newlines)
            if line.isEmpty {
                if !current.isEmpty {
                    records.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            records.append(current)
        }

        return records.enumerated().compactMap { index, lines in
            var path: String?
            var head: String?
            var branch: String?
            var isBare = false
            var isDetached = false
            var isPrunable = false
            var pruneReason: String?

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/")
                        ? String(ref.dropFirst("refs/heads/".count))
                        : ref
                } else if line == "bare" {
                    isBare = true
                } else if line == "detached" {
                    isDetached = true
                } else if line.hasPrefix("prunable") {
                    isPrunable = true
                    let reason = String(line.dropFirst("prunable".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    pruneReason = reason.isEmpty ? nil : reason
                }
            }

            guard let path, !path.isEmpty else { return nil }
            return AgentGitWorktree(
                path: URL(fileURLWithPath: path).standardizedFileURL.path,
                head: head,
                branch: branch,
                isBare: isBare,
                isDetached: isDetached,
                isPrunable: isPrunable,
                pruneReason: pruneReason,
                isPrimary: index == 0
            )
        }
    }

    nonisolated static func listGitWorktrees(for directoryURL: URL) -> [AgentGitWorktree] {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else { return [] }
        let output = runGit(arguments: ["worktree", "list", "--porcelain"], in: repositoryRoot)
        return parseGitWorktreeListPorcelain(output)
    }

    nonisolated static func sanitizedGitWorktreeName(_ raw: String) -> String {
        var result = ""
        var previousWasSeparator = false
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isAlphaNumeric = (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
            let isAllowedPunctuation = scalar == "." || scalar == "_" || scalar == "-"
            if isAlphaNumeric || isAllowedPunctuation {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return trimmed.isEmpty ? "worktree" : trimmed
    }

    nonisolated static func defaultGitWorktreeBranchName(
        sessionTitle: String?,
        fallbackStem: String? = nil,
        uniqueness: String? = nil
    ) -> String {
        let semanticStem = semanticGitWorktreeStem(from: sessionTitle)
        let randomStem = fallbackStem ?? randomGitWorktreeStem()
        let stem = semanticStem ?? sanitizedGitWorktreeName(randomStem)
        let token = sanitizedGitWorktreeName(
            uniqueness ?? String(UUID().uuidString.prefix(4)).lowercased()
        ).lowercased()
        return "xedit-\(String(stem.prefix(40)))-\(token)"
    }

    nonisolated static func semanticGitWorktreeStem(from title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let placeholderTitles = ["new chat", "new conversation", "untitled", "新对话", "新会话", "未命名"]
        guard !placeholderTitles.contains(trimmed.lowercased()) else { return nil }

        let latin = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let slug = sanitizedGitWorktreeName(folded).lowercased()
        guard slug != "worktree", slug.count >= 2 else { return nil }
        return slug
    }

    nonisolated static func randomGitWorktreeStem() -> String {
        let adjectives = ["bright", "calm", "clever", "nimble", "quiet", "swift"]
        let nouns = ["comet", "harbor", "maple", "orbit", "river", "sparrow"]
        return "\(adjectives.randomElement() ?? "swift")-\(nouns.randomElement() ?? "orbit")"
    }

    nonisolated static func gitWorktreeCheckoutProgress(from output: String) -> Double? {
        let pattern = #"Updating files:\s*([0-9]{1,3})%"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.matches(in: output, range: range).last,
              let valueRange = Range(match.range(at: 1), in: output),
              let percentage = Double(output[valueRange]) else {
            return nil
        }
        return min(1, max(0, percentage / 100))
    }

    nonisolated static func defaultGitWorktreeURL(
        repositoryRoot: URL,
        branchName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let baseName = repositoryRoot.lastPathComponent.isEmpty ? "repo" : repositoryRoot.lastPathComponent
        let slug = sanitizedGitWorktreeName(branchName)
        let parent = repositoryRoot.deletingLastPathComponent()
        let stem = "\(baseName)-\(slug)"
        var candidate = parent.appendingPathComponent(stem, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate.standardizedFileURL
    }

    nonisolated static func createGitWorktree(
        from directoryURL: URL,
        branchName rawBranchName: String
    ) -> Result<AgentGitWorktreeCreateResult, AgentGitWorktreeFailure> {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return .failure(AgentGitWorktreeFailure(message: "当前 workspace 不是 Git 仓库。"))
        }

        let branchName = sanitizedGitWorktreeName(rawBranchName)
        let worktreeURL = defaultGitWorktreeURL(repositoryRoot: repositoryRoot, branchName: branchName)
        let existingBranch = runGitCommand(
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
            in: repositoryRoot,
            allowedExitStatuses: [0, 1]
        )
        guard existingBranch.succeeded else {
            return .failure(AgentGitWorktreeFailure(message: existingBranch.userMessage))
        }
        let arguments: [String]
        if existingBranch.status == 0 {
            arguments = ["worktree", "add", worktreeURL.path, branchName]
        } else {
            arguments = ["worktree", "add", "-b", branchName, worktreeURL.path, "HEAD"]
        }

        let result = runGitCommand(arguments: arguments, in: repositoryRoot)
        guard result.succeeded else {
            return .failure(AgentGitWorktreeFailure(message: result.userMessage))
        }

        let worktrees = listGitWorktrees(for: repositoryRoot)
        if let created = worktrees.first(where: { $0.url == worktreeURL }) {
            return .success(AgentGitWorktreeCreateResult(worktree: created, output: result.stdout))
        }

        return .success(AgentGitWorktreeCreateResult(
            worktree: AgentGitWorktree(
                path: worktreeURL.path,
                head: nil,
                branch: branchName,
                isBare: false,
                isDetached: false,
                isPrunable: false,
                pruneReason: nil,
                isPrimary: false
            ),
            output: result.stdout
        ))
    }

    nonisolated static func createGitWorktreeStreaming(
        from directoryURL: URL,
        branchName rawBranchName: String,
        controller: AgentGitWorktreeProcessController,
        onOutput: @escaping @Sendable (String) -> Void
    ) -> Result<AgentGitWorktreeCreateResult, AgentGitWorktreeFailure> {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return .failure(AgentGitWorktreeFailure(message: "当前 workspace 不是 Git 仓库。"))
        }

        let branchName = sanitizedGitWorktreeName(rawBranchName)
        let worktreeURL = defaultGitWorktreeURL(repositoryRoot: repositoryRoot, branchName: branchName)
        let existingBranch = runGitCommand(
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
            in: repositoryRoot,
            allowedExitStatuses: [0, 1]
        )
        guard existingBranch.succeeded else {
            return .failure(AgentGitWorktreeFailure(message: existingBranch.userMessage))
        }
        let createdNewBranch = existingBranch.status != 0
        let arguments = createdNewBranch
            ? ["worktree", "add", "-b", branchName, worktreeURL.path, "HEAD"]
            : ["worktree", "add", worktreeURL.path, branchName]

        if controller.isCancelled {
            return .failure(AgentGitWorktreeFailure(message: "cancelled", wasCancelled: true))
        }

        let process = Process()
        let outputPipe = Pipe()
        let collector = AgentGitWorktreeOutputCollector(limit: maxGitOutputBytes, onUpdate: onOutput)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "-e", "-F", "/dev/null",
            "/usr/bin/git", "-c", "core.quotePath=false"
        ] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PROGRESS_DELAY": "0",
            "LC_ALL": "C"
        ]) { current, _ in current }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        do {
            try process.run()
            controller.attach(process)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(AgentGitWorktreeFailure(message: error.localizedDescription))
        }

        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        if let tail = try? outputPipe.fileHandleForReading.readToEnd() {
            collector.append(tail)
        }
        let output = collector.stringValue

        guard !controller.isCancelled else {
            cleanupCancelledGitWorktree(
                worktreeURL: worktreeURL,
                branchName: branchName,
                createdNewBranch: createdNewBranch,
                repositoryRoot: repositoryRoot
            )
            return .failure(AgentGitWorktreeFailure(message: "cancelled", wasCancelled: true))
        }
        guard process.terminationStatus == 0 else {
            let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(AgentGitWorktreeFailure(
                message: details.isEmpty ? "git exited with status \(process.terminationStatus)" : details
            ))
        }

        let worktrees = listGitWorktrees(for: repositoryRoot)
        let created = worktrees.first(where: { $0.url == worktreeURL }) ?? AgentGitWorktree(
            path: worktreeURL.path,
            head: nil,
            branch: branchName,
            isBare: false,
            isDetached: false,
            isPrunable: false,
            pruneReason: nil,
            isPrimary: false
        )
        return .success(AgentGitWorktreeCreateResult(worktree: created, output: output))
    }

    nonisolated private static func cleanupCancelledGitWorktree(
        worktreeURL: URL,
        branchName: String,
        createdNewBranch: Bool,
        repositoryRoot: URL
    ) {
        _ = runGitCommand(
            arguments: ["worktree", "remove", "--force", worktreeURL.path],
            in: repositoryRoot
        )
        if FileManager.default.fileExists(atPath: worktreeURL.path) {
            try? FileManager.default.removeItem(at: worktreeURL)
        }
        _ = runGitCommand(arguments: ["worktree", "prune"], in: repositoryRoot)
        if createdNewBranch {
            _ = runGitCommand(arguments: ["branch", "-D", branchName], in: repositoryRoot)
        }
    }

    nonisolated static func removeGitWorktree(
        at worktreeURL: URL,
        from directoryURL: URL
    ) -> Result<Void, AgentGitWorktreeFailure> {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return .failure(AgentGitWorktreeFailure(message: "当前 workspace 不是 Git 仓库。"))
        }
        let result = runGitCommand(
            arguments: ["worktree", "remove", worktreeURL.standardizedFileURL.path],
            in: repositoryRoot
        )
        return result.succeeded ? .success(()) : .failure(AgentGitWorktreeFailure(message: result.userMessage))
    }

    nonisolated static func pruneGitWorktrees(from directoryURL: URL) -> Result<Void, AgentGitWorktreeFailure> {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return .failure(AgentGitWorktreeFailure(message: "当前 workspace 不是 Git 仓库。"))
        }
        let result = runGitCommand(arguments: ["worktree", "prune"], in: repositoryRoot)
        return result.succeeded ? .success(()) : .failure(AgentGitWorktreeFailure(message: result.userMessage))
    }

    func refreshAgentGitWorktrees() {
        guard let targetDirectory = activeAgentLocalWorkspaceURL ?? rootDirectory?.standardizedFileURL else {
            agentGitWorktrees = []
            agentWorkspaceGitStatus = GitRepositoryStatus()
            return
        }

        Task { [weak self] in
            let context = await Task.detached(priority: .utility) {
                (
                    worktrees: Self.listGitWorktrees(for: targetDirectory),
                    status: Self.loadGitStatus(for: targetDirectory)
                )
            }.value

            await MainActor.run {
                guard let self, self.activeAgentLocalWorkspaceURL?.path == targetDirectory.path
                    || (self.activeAgentLocalWorkspaceURL == nil
                        && self.rootDirectory?.standardizedFileURL.path == targetDirectory.path) else { return }
                self.agentGitWorktrees = context.worktrees
                self.agentWorkspaceGitStatus = context.status
            }
        }
    }

    func createAgentGitWorktreeFromActiveWorkspace() {
        guard let source = activeAgentLocalWorkspaceURL else {
            showFileOperationError("先选择一个 Git workspace。")
            return
        }
        guard agentGitWorktreeCreation == nil else { return }
        let branchName = Self.defaultGitWorktreeBranchName(sessionTitle: activeRuntime?.session.title)
        createAgentGitWorktree(from: source, branchName: branchName)
    }

    func createAgentGitWorktree(from source: URL, branchName: String) {
        guard let sessionID = activeAgentSessionID else { return }
        let controller = AgentGitWorktreeProcessController()
        agentGitWorktreeProcessController = controller
        agentGitWorktreeCreation = AgentGitWorktreeCreation(
            id: UUID(),
            sessionID: sessionID,
            branchName: branchName,
            startedAt: Date(),
            output: L10n.GitWorktreeCreation.starting(branchName),
            progress: nil,
            isCancelling: false
        )

        agentGitWorktreeCreationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.createGitWorktreeStreaming(
                    from: source,
                    branchName: branchName,
                    controller: controller
                ) { output in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.agentGitWorktreeCreation?.sessionID == sessionID else { return }
                        self.agentGitWorktreeCreation?.output = output
                        self.agentGitWorktreeCreation?.progress = Self.gitWorktreeCheckoutProgress(from: output)
                    }
                }
            }.value

            await MainActor.run {
                guard let self else { return }
                self.agentGitWorktreeCreationTask = nil
                self.agentGitWorktreeProcessController = nil
                self.agentGitWorktreeCreation = nil
                switch result {
                case .success(let created):
                    self.agentGitWorktrees = Self.listGitWorktrees(for: created.worktree.url)
                    if self.activeAgentSessionID == sessionID {
                        _ = self.moveActiveAgentSessionToWorkspace(at: created.worktree.path)
                    }
                    self.refreshAgentGitWorktrees()
                case .failure(let failure):
                    if !failure.wasCancelled {
                        self.showFileOperationError(L10n.GitWorktreeCreation.failed(failure.message))
                    }
                }
            }
        }
    }

    func cancelAgentGitWorktreeCreation() {
        guard agentGitWorktreeCreation != nil else { return }
        agentGitWorktreeCreation?.isCancelling = true
        agentGitWorktreeProcessController?.cancel()
    }

    func removeAgentGitWorktree(_ worktree: AgentGitWorktree) {
        guard let source = activeAgentLocalWorkspaceURL else { return }
        guard !worktree.isPrimary else {
            showFileOperationError("主工作树不能从这里删除。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Remove Worktree"
        alert.informativeText = "Remove \(worktree.displayName)? Git will refuse if the worktree has uncommitted changes."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.removeGitWorktree(at: worktree.url, from: source)
            }.value

            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    if self.activeAgentLocalWorkspaceURL?.path == worktree.url.path,
                       let primary = self.agentGitWorktrees.first(where: \.isPrimary) {
                        _ = self.moveActiveAgentSessionToWorkspace(at: primary.path)
                    }
                    self.refreshAgentGitWorktrees()
                case .failure(let failure):
                    self.showFileOperationError("删除 Git worktree 失败：\(failure.message)")
                }
            }
        }
    }

    func pruneAgentGitWorktrees() {
        guard let source = activeAgentLocalWorkspaceURL else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.pruneGitWorktrees(from: source)
            }.value

            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    self.refreshAgentGitWorktrees()
                case .failure(let failure):
                    self.showFileOperationError("清理 Git worktree 失败：\(failure.message)")
                }
            }
        }
    }

    private var activeAgentLocalWorkspaceURL: URL? {
        if let path = activeRuntime?.workspaceLocation?.localPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let path = activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }
}
