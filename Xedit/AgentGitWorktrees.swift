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

    nonisolated static func defaultGitWorktreeBranchName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "codex-worktree-\(formatter.string(from: now))"
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
        guard activeAgentLocalWorkspaceURL != nil else {
            showFileOperationError("先选择一个 Git workspace。")
            return
        }
        promptForName(
            title: "New Worktree",
            message: "Enter a branch name. Xedit will create a sibling Git worktree and start an Agent session there.",
            placeholder: Self.defaultGitWorktreeBranchName()
        ) { [weak self] branchName in
            self?.createAgentGitWorktree(branchName: branchName)
        }
    }

    func createAgentGitWorktree(branchName: String) {
        guard let source = activeAgentLocalWorkspaceURL else {
            showFileOperationError("先选择一个 Git workspace。")
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.createGitWorktree(from: source, branchName: branchName)
            }.value

            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let created):
                    self.agentGitWorktrees = Self.listGitWorktrees(for: created.worktree.url)
                    _ = self.moveActiveAgentSessionToWorkspace(at: created.worktree.path)
                    self.refreshAgentGitWorktrees()
                case .failure(let failure):
                    self.showFileOperationError("创建 Git worktree 失败：\(failure.message)")
                }
            }
        }
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
