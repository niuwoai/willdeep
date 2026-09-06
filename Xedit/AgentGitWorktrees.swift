//
//  AgentGitWorktrees.swift
//  WillDeep
//
//  Local Git worktree support for Agent composer workspaces. Sessions
//  still bind to a normal local workspace path; the git metadata here is
//  discovered on demand so old session JSON keeps loading unchanged.
//

import AppKit
import CryptoKit
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

/// Durable information required to recreate a WillDeep-managed worktree after
/// its checkout directory has been cleaned up. Sessions that only remember a
/// path deliberately do not get a restore button: guessing a repository or
/// branch here could bind an old conversation to the wrong code.
nonisolated struct AgentWorktreeRecoveryInfo: Codable, Equatable {
    var repositoryRootPath: String
    var worktreePath: String
    var branchName: String
    var managedByWillDeep: Bool
}

nonisolated enum AgentWorktreeRecoveryState: Equatable {
    case none
    case unavailable(path: String)
    case restorable(AgentWorktreeRecoveryInfo)
    case restoring(AgentWorktreeRecoveryInfo)
    case failed(path: String, message: String)

    var blocksComposer: Bool {
        switch self {
        case .none:
            return false
        case .unavailable, .restorable, .restoring, .failed:
            return true
        }
    }
}

extension AgentSession {
    nonisolated var isRunningInGitWorktree: Bool {
        guard let sidebarWorkspaceRootPath, !sidebarWorkspaceRootPath.isEmpty,
              let executionPath = workspaceLocation?.localPath ?? workspaceRootPath,
              !executionPath.isEmpty else {
            return false
        }
        return URL(fileURLWithPath: sidebarWorkspaceRootPath).standardizedFileURL.path
            != URL(fileURLWithPath: executionPath).standardizedFileURL.path
    }
}

struct AgentGitWorktreeCreateResult: Equatable {
    var worktree: AgentGitWorktree
    var output: String
}

/// Snapshot of "other sessions are also live in my exact working
/// directory right now". Drives the composer's soft collision warning:
/// concurrent sessions on the same checkout can silently clobber each
/// other's edits, and a Git worktree is the escape hatch. Deliberately
/// scoped to *currently-responding* runtimes so the hint stays quiet
/// (it does NOT flag every past chat that ever touched the folder).
struct AgentWorkspaceCollision: Equatable {
    /// Absolute, standardized path of the active session's local checkout.
    var workspacePath: String?
    /// How many *other* runtimes are streaming a turn in that same path.
    var otherActiveSessionCount: Int

    init(workspacePath: String? = nil, otherActiveSessionCount: Int = 0) {
        self.workspacePath = workspacePath
        self.otherActiveSessionCount = otherActiveSessionCount
    }

    var isEmpty: Bool { otherActiveSessionCount <= 0 }
}

/// One runtime's inputs to the same-checkout collision count. Extracted
/// so the counting rule is a pure function that unit tests can drive
/// without standing up a MainActor `AppState` and live runtimes.
struct AgentWorkspaceCollisionCandidate: Equatable {
    var id: UUID
    var isResponding: Bool
    var localPath: String?
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
    nonisolated static func worktreeRecoveryInfo(
        worktreePath: String,
        repositoryHint: URL,
        managedHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentWorktreeRecoveryInfo? {
        let worktreeURL = URL(fileURLWithPath: worktreePath).standardizedFileURL
        let managedRoot = managedHomeDirectory
            .appendingPathComponent(".willdeep/worktrees", isDirectory: true)
            .standardizedFileURL
        let managedPrefix = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
        guard worktreeURL.path.hasPrefix(managedPrefix),
              let repositoryRoot = findGitRepositoryRoot(startingAt: repositoryHint),
              let worktree = listGitWorktrees(repositoryRoot: repositoryRoot).first(where: {
                  $0.url.path == worktreeURL.path
              }),
              !worktree.isPrimary,
              !worktree.isDetached,
              let branch = worktree.branch,
              !branch.isEmpty else {
            return nil
        }
        return AgentWorktreeRecoveryInfo(
            repositoryRootPath: repositoryRoot.standardizedFileURL.path,
            worktreePath: worktreeURL.path,
            branchName: branch,
            managedByWillDeep: true
        )
    }

    nonisolated static func worktreeRecoveryState(
        for session: AgentSession,
        fileManager: FileManager = .default,
        managedHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentWorktreeRecoveryState {
        guard session.isRunningInGitWorktree,
              let path = session.workspaceLocation?.localPath ?? session.workspaceRootPath,
              !path.isEmpty else {
            return .none
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .none
        }
        guard let info = session.worktreeRecoveryInfo,
              info.managedByWillDeep,
              isWillDeepManagedWorktreePath(info.worktreePath, homeDirectory: managedHomeDirectory),
              URL(fileURLWithPath: info.worktreePath).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path else {
            return .unavailable(path: path)
        }
        let repositoryURL = URL(fileURLWithPath: info.repositoryRootPath).standardizedFileURL
        guard findGitRepositoryRoot(startingAt: repositoryURL)?.standardizedFileURL.path == repositoryURL.path else {
            return .unavailable(path: path)
        }
        let branch = runGitCommand(
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(info.branchName)"],
            in: repositoryURL,
            allowedExitStatuses: [0, 1]
        )
        guard branch.status == 0 else { return .unavailable(path: path) }
        let conflictingCheckout = listGitWorktrees(repositoryRoot: repositoryURL).contains { worktree in
            worktree.branch == info.branchName
                && worktree.url.path != URL(fileURLWithPath: path).standardizedFileURL.path
                && !worktree.isPrunable
        }
        return conflictingCheckout ? .unavailable(path: path) : .restorable(info)
    }

    nonisolated static func restoreGitWorktree(
        from info: AgentWorktreeRecoveryInfo,
        managedHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Result<AgentGitWorktreeCreateResult, AgentGitWorktreeFailure> {
        guard info.managedByWillDeep,
              isWillDeepManagedWorktreePath(info.worktreePath, homeDirectory: managedHomeDirectory) else {
            return .failure(.init(message: "This worktree was not created by WillDeep."))
        }
        let repositoryURL = URL(fileURLWithPath: info.repositoryRootPath).standardizedFileURL
        let worktreeURL = URL(fileURLWithPath: info.worktreePath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: worktreeURL.path) else {
            return .failure(.init(message: "The original worktree path is already occupied."))
        }
        _ = runGitCommand(arguments: ["worktree", "prune"], in: repositoryURL)
        let branch = runGitCommand(
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(info.branchName)"],
            in: repositoryURL,
            allowedExitStatuses: [0, 1]
        )
        guard branch.status == 0 else {
            return .failure(.init(message: "The original branch no longer exists."))
        }
        let conflictingCheckout = listGitWorktrees(repositoryRoot: repositoryURL).contains {
            $0.branch == info.branchName && !$0.isPrunable
        }
        guard !conflictingCheckout else {
            return .failure(.init(message: "The original branch is already checked out elsewhere."))
        }
        if let failure = prepareGitWorktreeParentDirectory(for: worktreeURL) {
            return .failure(failure)
        }
        let result = runGitCommand(
            arguments: ["worktree", "add", worktreeURL.path, info.branchName],
            in: repositoryURL
        )
        guard result.succeeded else {
            return .failure(.init(message: result.userMessage))
        }
        guard let restored = listGitWorktrees(repositoryRoot: repositoryURL).first(where: {
            $0.url.path == worktreeURL.path
        }) else {
            return .failure(.init(message: "Git restored the checkout but did not report the worktree."))
        }
        return .success(.init(worktree: restored, output: result.stdout))
    }

    nonisolated private static func isWillDeepManagedWorktreePath(
        _ path: String,
        homeDirectory: URL
    ) -> Bool {
        let worktreePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let managedRootPath = homeDirectory
            .appendingPathComponent(".willdeep/worktrees", isDirectory: true)
            .standardizedFileURL.path
        let managedPrefix = managedRootPath.hasSuffix("/") ? managedRootPath : managedRootPath + "/"
        return worktreePath.hasPrefix(managedPrefix)
    }

    func refreshActiveAgentWorktreeRecoveryState() {
        agentWorktreeRecoveryTask?.cancel()
        agentWorktreeRecoveryState = .none
        guard let runtime = activeRuntime else {
            return
        }
        let session = runtime.session
        let sessionID = session.id
        agentWorktreeRecoveryTask = Task { [weak self] in
            let state = await Task.detached(priority: .utility) {
                Self.worktreeRecoveryState(for: session)
            }.value
            guard let self, !Task.isCancelled, self.activeAgentSessionID == sessionID else { return }
            self.agentWorktreeRecoveryState = state
            if state.blocksComposer {
                _ = runtime.diagnoseLocalWorkspaceAfterFailure()
            }
        }
    }

    func restoreActiveAgentGitWorktree() {
        guard case .restorable(let info) = agentWorktreeRecoveryState,
              let sessionID = activeAgentSessionID else { return }
        agentWorktreeRecoveryState = .restoring(info)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.restoreGitWorktree(from: info)
            }.value
            guard let self, self.activeAgentSessionID == sessionID,
                  let runtime = self.activeRuntime else { return }
            switch result {
            case .success:
                runtime.rebindGitWorktree(
                    to: info.worktreePath,
                    sidebarWorkspaceRootPath: info.repositoryRootPath,
                    recoveryInfo: info
                )
                runtime.worktreeChanges = .init()
                self.persistAgentSession(runtime: runtime)
                self.agentWorktreeRecoveryState = .none
                self.refreshAgentGitWorktrees()
                self.refreshActiveAgentWorktreeChanges()
            case .failure(let failure):
                self.agentWorktreeRecoveryState = .failed(
                    path: info.worktreePath,
                    message: failure.message
                )
            }
        }
    }

    func chooseReplacementWorkspaceForActiveSession() {
        guard let runtime = activeRuntime, !runtime.isResponding else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.WorktreeRecovery.chooseWorkspace
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self, let activeRuntime = self.activeRuntime,
                      activeRuntime.id == runtime.id else { return }
                _ = self.activateSecurityScope(for: url)
                self.registerRecentFolder(url)
                activeRuntime.rebindWorkspace(to: url.standardizedFileURL.path)
                activeRuntime.worktreeChanges = .init()
                activeRuntime.agentArtifactPaths = []
                self.persistAgentSession(runtime: activeRuntime)
                self.agentWorktreeRecoveryState = .none
                self.refreshAgentGitWorktrees()
                self.refreshAgentWorkspaceCollision()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

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
        return listGitWorktrees(repositoryRoot: repositoryRoot)
    }

    nonisolated static func listGitWorktrees(repositoryRoot: URL) -> [AgentGitWorktree] {
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
        worktreeRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let baseName = repositoryRoot.lastPathComponent.isEmpty ? "repo" : repositoryRoot.lastPathComponent
        let slug = sanitizedGitWorktreeName(branchName)
        let repositoryPath = repositoryRoot.standardizedFileURL.path
        let repositoryHash = SHA256.hash(data: Data(repositoryPath.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        let repositoryDirectoryName = "\(sanitizedGitWorktreeName(baseName))-\(repositoryHash)"
        let root = worktreeRoot?.standardizedFileURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".willdeep/worktrees", isDirectory: true)
        let parent = root.appendingPathComponent(repositoryDirectoryName, isDirectory: true)
        var candidate = parent.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate.standardizedFileURL
    }

    nonisolated static func createGitWorktree(
        from directoryURL: URL,
        branchName rawBranchName: String,
        worktreeRoot: URL? = nil,
        startingRevision: String? = nil
    ) -> Result<AgentGitWorktreeCreateResult, AgentGitWorktreeFailure> {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return .failure(AgentGitWorktreeFailure(message: "当前 workspace 不是 Git 仓库。"))
        }

        if let startingRevision,
           !([40, 64].contains(startingRevision.count) && startingRevision.allSatisfy({ $0.isASCII && $0.isHexDigit })) {
            return .failure(AgentGitWorktreeFailure(message: "Invalid immutable worktree input revision."))
        }

        let branchName = sanitizedGitWorktreeName(rawBranchName)
        if let existing = reusableGitWorktree(
            forBranch: branchName,
            repositoryRoot: repositoryRoot
        ) {
            if let startingRevision, existing.head != startingRevision {
                return .failure(AgentGitWorktreeFailure(message: "Existing worktree does not match the requested input revision."))
            }
            return .success(AgentGitWorktreeCreateResult(
                worktree: existing,
                output: "Reusing existing WillDeep worktree: \(existing.path)"
            ))
        }
        let worktreeURL = defaultGitWorktreeURL(
            repositoryRoot: repositoryRoot,
            branchName: branchName,
            worktreeRoot: worktreeRoot
        )
        if let failure = prepareGitWorktreeParentDirectory(for: worktreeURL) {
            return .failure(failure)
        }
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
            if let startingRevision {
                let actual = runGitCommand(arguments: ["rev-parse", "refs/heads/\(branchName)"], in: repositoryRoot)
                guard actual.succeeded, actual.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == startingRevision else {
                    return .failure(AgentGitWorktreeFailure(message: "Existing branch does not match the requested input revision."))
                }
            }
            arguments = ["worktree", "add", worktreeURL.path, branchName]
        } else {
            arguments = ["worktree", "add", "-b", branchName, worktreeURL.path, startingRevision ?? "HEAD"]
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
        worktreeRoot: URL? = nil,
        controller: AgentGitWorktreeProcessController,
        onOutput: @escaping @Sendable (String) -> Void
    ) -> Result<AgentGitWorktreeCreateResult, AgentGitWorktreeFailure> {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return .failure(AgentGitWorktreeFailure(message: "当前 workspace 不是 Git 仓库。"))
        }

        let branchName = sanitizedGitWorktreeName(rawBranchName)
        if let existing = reusableGitWorktree(
            forBranch: branchName,
            repositoryRoot: repositoryRoot
        ) {
            let message = "Reusing existing WillDeep worktree: \(existing.path)"
            onOutput(message)
            return .success(AgentGitWorktreeCreateResult(
                worktree: existing,
                output: message
            ))
        }
        let worktreeURL = defaultGitWorktreeURL(
            repositoryRoot: repositoryRoot,
            branchName: branchName,
            worktreeRoot: worktreeRoot
        )
        if let failure = prepareGitWorktreeParentDirectory(for: worktreeURL) {
            return .failure(failure)
        }
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

    /// A deterministic dispatch branch identifies one logical task. When an
    /// earlier launch already created its worktree, reuse that checkout
    /// instead of asking Git to check out the same branch twice. Stale
    /// metadata is pruned first; primary checkouts are never treated as task
    /// isolation.
    nonisolated static func reusableGitWorktree(
        forBranch branchName: String,
        repositoryRoot: URL,
        fileManager: FileManager = .default
    ) -> AgentGitWorktree? {
        let normalizedBranch = sanitizedGitWorktreeName(branchName)
        var worktrees = listGitWorktrees(for: repositoryRoot)
        let matching = worktrees.filter {
            !$0.isPrimary && $0.branch == normalizedBranch
        }
        if let usable = matching.first(where: {
            !$0.isPrunable && fileManager.fileExists(atPath: $0.path)
        }) {
            return usable
        }
        guard !matching.isEmpty else { return nil }

        _ = runGitCommand(arguments: ["worktree", "prune"], in: repositoryRoot)
        worktrees = listGitWorktrees(for: repositoryRoot)
        return worktrees.first {
            !$0.isPrimary
                && $0.branch == normalizedBranch
                && !$0.isPrunable
                && fileManager.fileExists(atPath: $0.path)
        }
    }

    nonisolated private static func prepareGitWorktreeParentDirectory(
        for worktreeURL: URL,
        fileManager: FileManager = .default
    ) -> AgentGitWorktreeFailure? {
        do {
            try fileManager.createDirectory(
                at: worktreeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return nil
        } catch {
            return AgentGitWorktreeFailure(
                message: "无法创建 WillDeep worktree 目录：\(error.localizedDescription)"
            )
        }
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
            agentGitWorktreeRefreshTask?.cancel()
            agentGitWorktreeRefreshTask = nil
            agentGitWorktreeRefreshPath = nil
            agentGitWorktrees = []
            agentWorkspaceGitStatus = GitRepositoryStatus()
            return
        }

        let targetPath = targetDirectory.path
        if agentGitWorktreeRefreshPath == targetPath,
           agentGitWorktreeRefreshTask != nil {
            return
        }

        agentGitWorktreeRefreshTask?.cancel()
        agentGitWorktreeRefreshPath = targetPath
        agentGitWorktreeRefreshTask = Task { [weak self] in
            let context = await Task.detached(priority: .utility) {
                // Resolve the repository root once. Both lookups below used to
                // find it for themselves, which spawned `git rev-parse
                // --show-toplevel` twice against the same directory on every
                // single refresh.
                guard let repositoryRoot = Self.findGitRepositoryRoot(startingAt: targetDirectory) else {
                    return (worktrees: [AgentGitWorktree](), status: GitRepositoryStatus())
                }
                return (
                    worktrees: Self.listGitWorktrees(repositoryRoot: repositoryRoot),
                    // The workspace picker only consumes repository identity
                    // and branch here. Do not launch a second full `git status`
                    // beside the editor's own refresh.
                    status: Self.loadAgentGitRepositoryIdentity(repositoryRoot: repositoryRoot)
                )
            }.value

            await MainActor.run {
                guard let self else { return }
                defer {
                    if self.agentGitWorktreeRefreshPath == targetPath {
                        self.agentGitWorktreeRefreshTask = nil
                        self.agentGitWorktreeRefreshPath = nil
                    }
                }
                let isCurrentWorkspace = self.activeAgentLocalWorkspaceURL?.path == targetPath
                    || (self.activeAgentLocalWorkspaceURL == nil
                        && self.rootDirectory?.standardizedFileURL.path == targetPath)
                guard !Task.isCancelled, isCurrentWorkspace else { return }
                self.agentGitWorktrees = context.worktrees
                self.agentWorkspaceGitStatus = context.status
            }
        }
    }

    /// composer 上方那枚分支胶囊读的是 `agentWorkspaceGitStatus`，而它过去只在
    /// 切会话 / 切根目录 / 建删 worktree 时才刷新——全都是**路径变了**的场合。
    /// 分支却可以在同一个路径里被换掉（Agent 跑 `git switch`、内置终端、外部
    /// 终端都会），于是胶囊会一直挂着旧分支名。
    ///
    /// 这里把任何一次**已经跑完**的 git 快照里的仓库身份（root + 分支）补录进
    /// 来，不额外开 git 进程；`entries` 保持为空，维持 `agentWorkspaceGitStatus`
    /// 只承载身份、不承载逐文件状态的既有约定。
    func applyAgentWorkspaceGitIdentity(
        from status: GitRepositoryStatus,
        workspacePath: String
    ) {
        let activePath = (activeAgentLocalWorkspaceURL ?? rootDirectory?.standardizedFileURL)?.path
        guard activePath == workspacePath else { return }
        let identity = GitRepositoryStatus(
            repositoryRoot: status.repositoryRoot,
            branchName: status.branchName,
            entries: [:]
        )
        guard agentWorkspaceGitStatus != identity else { return }
        agentWorkspaceGitStatus = identity
    }

    nonisolated private static func loadAgentGitRepositoryIdentity(
        for directoryURL: URL
    ) -> GitRepositoryStatus {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return GitRepositoryStatus()
        }
        return loadAgentGitRepositoryIdentity(repositoryRoot: repositoryRoot)
    }

    nonisolated private static func loadAgentGitRepositoryIdentity(
        repositoryRoot: URL
    ) -> GitRepositoryStatus {
        let branch = runGit(arguments: ["branch", "--show-current"], in: repositoryRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitRepositoryStatus(
            repositoryRoot: repositoryRoot,
            branchName: branch.isEmpty ? "detached" : branch,
            entries: [:]
        )
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
        let sidebarWorkspaceRootPath = activeRuntime?.session.sidebarWorkspaceRootPath
            ?? activeRuntime?.localWorkspacePath
            ?? source.standardizedFileURL.path
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

        let outputHandler: @Sendable (String) -> Void = { [weak self] output in
            Task { @MainActor [weak self] in
                guard let self,
                      self.agentGitWorktreeCreation?.sessionID == sessionID else { return }
                self.agentGitWorktreeCreation?.output = output
                self.agentGitWorktreeCreation?.progress = Self.gitWorktreeCheckoutProgress(from: output)
            }
        }
        agentGitWorktreeCreationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.createGitWorktreeStreaming(
                    from: source,
                    branchName: branchName,
                    controller: controller
                ) { output in outputHandler(output) }
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
                        _ = self.moveActiveAgentSessionToGitWorktree(
                            at: created.worktree.path,
                            sidebarWorkspaceRootPath: sidebarWorkspaceRootPath
                        )
                    }
                    self.refreshAgentGitWorktrees()
                    self.refreshAgentWorkspaceCollision()
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
                        _ = self.moveActiveAgentSessionToGitWorktree(
                            at: primary.path,
                            sidebarWorkspaceRootPath: primary.path
                        )
                    }
                    self.refreshAgentGitWorktrees()
                    self.refreshAgentWorkspaceCollision()
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

    /// Recompute the same-checkout collision hint for the active session.
    ///
    /// Cheap and synchronous — it only walks the in-memory runtimes and
    /// compares standardized paths, no git or filesystem calls — so it's
    /// safe to fire from the hot agent-loop start/end and on every session
    /// switch. Only *responding* runtimes count, and a runtime must be
    /// alive to be responding, so iterating `agentRuntimes` catches every
    /// concurrent worker. Equality-guarded to avoid redundant @Published
    /// notifications (same-value writes still notify).
    func refreshAgentWorkspaceCollision() {
        guard let activeID = activeAgentSessionID,
              let activePath = activeAgentLocalWorkspaceURL?.path else {
            if !agentWorkspaceCollision.isEmpty || agentWorkspaceCollision.workspacePath != nil {
                agentWorkspaceCollision = AgentWorkspaceCollision()
            }
            return
        }

        let candidates = agentRuntimes.map { id, runtime in
            AgentWorkspaceCollisionCandidate(
                id: id,
                isResponding: runtime.isResponding,
                localPath: runtime.localWorkspacePath
            )
        }
        let count = Self.concurrentSessionCount(
            activeID: activeID,
            activePath: activePath,
            among: candidates
        )

        let next = AgentWorkspaceCollision(workspacePath: activePath, otherActiveSessionCount: count)
        if next != agentWorkspaceCollision {
            agentWorkspaceCollision = next
        }
    }

    /// Pure counting rule: how many *other* candidate runtimes are
    /// currently responding in the same standardized local checkout as
    /// the active session. Path comparison is standardized on both sides
    /// so `/foo` and `/foo/` (or symlink-y forms) collapse to one dir.
    nonisolated static func concurrentSessionCount(
        activeID: UUID,
        activePath: String,
        among candidates: [AgentWorkspaceCollisionCandidate]
    ) -> Int {
        let normalizedActive = URL(fileURLWithPath: activePath).standardizedFileURL.path
        var count = 0
        for candidate in candidates where candidate.id != activeID {
            guard candidate.isResponding, let path = candidate.localPath, !path.isEmpty else { continue }
            if URL(fileURLWithPath: path).standardizedFileURL.path == normalizedActive {
                count += 1
            }
        }
        return count
    }
}
