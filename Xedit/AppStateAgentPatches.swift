//
//  AppStateAgentPatches.swift
//  WillDeep
//
//  Agent patch proposal capture and application helpers split from
//  AppStateAgentLoop.swift.
//

import Foundation

extension AppState {
    func rejectAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }
        agentPatchProposals[index].status = .rejected
        agentPatchProposals[index].statusMessage = "Rejected"
    }

    @discardableResult
    func rejectPendingAgentPatchProposals(
        for runtime: AgentRuntime,
        statusMessage: String
    ) -> Int {
        var rejectedCount = 0
        for index in runtime.patchProposals.indices where runtime.patchProposals[index].status == .pending {
            runtime.patchProposals[index].status = .rejected
            runtime.patchProposals[index].statusMessage = statusMessage
            rejectedCount += 1
        }
        if rejectedCount > 0 {
            persistAgentSession(runtime: runtime)
        }
        return rejectedCount
    }

    @discardableResult
    func resolvePendingAgentPatchProposalsBeforeNewMessage(for runtime: AgentRuntime) -> Int {
        if let autoApplySource = pendingPatchAutoApplySource(for: runtime) {
            return autoApplyPendingAgentPatchProposals(for: runtime, source: autoApplySource)
        }

        return rejectPendingAgentPatchProposals(
            for: runtime,
            statusMessage: "Superseded by a newer message."
        )
    }

    @discardableResult
    func autoApplyPendingAgentPatchProposals(
        for runtime: AgentRuntime,
        source: AgentToolApprovalSource
    ) -> Int {
        var resolvedCount = 0
        for index in runtime.patchProposals.indices where runtime.patchProposals[index].status == .pending {
            let outcome = resolveAgentPatchApplication(
                runtime.patchProposals[index].diff,
                appliedMessage: autoApplyStatusMessage(for: source)
            )
            runtime.patchProposals[index].status = outcome.status
            runtime.patchProposals[index].statusMessage = outcome.message
            resolvedCount += 1
        }

        if resolvedCount > 0 {
            persistAgentSession(runtime: runtime)
        }
        return resolvedCount
    }

    /// Apply every still-pending proposal that belongs to one assistant
    /// message (one turn). Backs the "Apply All" button on the collapsed
    /// patch group card. Reuses the single-proposal apply path so disk
    /// writes, tab sync and status messages stay identical.
    func applyAgentPatchProposals(forMessageID messageID: AgentMessage.ID) {
        let ids = agentPatchProposals
            .filter { $0.messageID == messageID && $0.status == .pending }
            .map(\.id)
        for id in ids {
            applyAgentPatchProposal(id: id)
        }
    }

    /// Reject every still-pending proposal from one assistant message.
    /// Backs the "Reject All" button on the collapsed patch group card.
    func rejectAgentPatchProposals(forMessageID messageID: AgentMessage.ID) {
        let ids = agentPatchProposals
            .filter { $0.messageID == messageID && $0.status == .pending }
            .map(\.id)
        for id in ids {
            rejectAgentPatchProposal(id: id)
        }
    }

    /// Apply every still-pending proposal across ALL assistant messages.
    /// Backs the transcript-level "Apply All" bar shown when several
    /// independent patch cards stack up (e.g. one patch per turn over
    /// many turns). Reuses the single-proposal path so disk writes, tab
    /// sync and status messages stay identical.
    func applyAllPendingAgentPatchProposals() {
        let ids = agentPatchProposals
            .filter { $0.status == .pending }
            .map(\.id)
        for id in ids {
            applyAgentPatchProposal(id: id)
        }
    }

    /// Reject every still-pending proposal across ALL assistant messages.
    func rejectAllPendingAgentPatchProposals() {
        let ids = agentPatchProposals
            .filter { $0.status == .pending }
            .map(\.id)
        for id in ids {
            rejectAgentPatchProposal(id: id)
        }
    }

    func applyAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }

        let outcome = resolveAgentPatchApplication(agentPatchProposals[index].diff, appliedMessage: "Applied")
        agentPatchProposals[index].status = outcome.status
        agentPatchProposals[index].statusMessage = outcome.message
    }

    /// Apply `diff`, folding a benign "already applied" outcome into
    /// `.applied` so a change that landed earlier — Goal/workspace
    /// auto-apply, another session touching the same working tree, or a
    /// duplicate card whose twin was applied — no longer surfaces as a scary
    /// "hunk did not match" failure the user can't act on. Shared by the
    /// manual Apply button, batch auto-apply, and immediate apply so all
    /// three treat an already-landed change identically.
    func resolveAgentPatchApplication(
        _ diff: String,
        appliedMessage: String
    ) -> (status: AgentPatchStatus, message: String) {
        do {
            try applyAgentPatch(diff)
            return (.applied, appliedMessage)
        } catch {
            if case AgentPatchError.hunkDidNotMatch = error, agentPatchIsAlreadyApplied(diff) {
                return (.applied, L10n.AgentPatch.alreadyApplied)
            }
            return (.failed, error.localizedDescription)
        }
    }

    /// After an apply throws `hunkDidNotMatch`, decide whether the file is
    /// simply already in the patch's target state (see
    /// `AgentPatchApplier.isAlreadyApplied`). Reads the current in-tab / on
    /// disk content per file so it reflects edits made outside this card.
    func agentPatchIsAlreadyApplied(_ diff: String) -> Bool {
        guard let root = agentPatchWorkspaceRoot() else { return false }
        guard let changes = try? AgentPatchApplier.parse(diff), !changes.isEmpty else { return false }
        let standardizedRoot = root.standardizedFileURL
        let rootPath = standardizedRoot.path
        for change in changes {
            guard let url = try? resolveAgentPatchURL(change.path, root: standardizedRoot, rootPath: rootPath),
                  let content = try? editableContent(forAgentPatchURL: url),
                  AgentPatchApplier.isAlreadyApplied(change, to: content) else {
                return false
            }
        }
        return true
    }

    func captureAgentPatchProposals(for runtime: AgentRuntime, fromMessageID messageID: UUID) {
        guard let message = runtime.messages.first(where: { $0.id == messageID }) else { return }
        let diffs = AgentPatchApplier.extractDiffBlocks(from: message.content)
        guard !diffs.isEmpty else { return }

        let existingDiffs = Set(runtime.patchProposals.map(\.diff))
        for (offset, diff) in diffs.enumerated() where !existingDiffs.contains(diff) {
            let title = diffs.count == 1 ? "Agent Patch" : "Agent Patch \(offset + 1)"
            runtime.patchProposals.append(
                AgentPatchProposal(messageID: messageID, title: title, diff: diff)
            )
        }
    }

    @discardableResult
    func enqueueAgentPatchProposal(
        for runtime: AgentRuntime,
        messageID: UUID,
        title: String?,
        diff: String,
        autoApplySource: AgentToolApprovalSource? = nil,
        applyImmediately: Bool = false
    ) throws -> AgentPatchProposal {
        let parsed = try AgentPatchApplier.parse(diff)
        // 创建新文件直接落地,不进审核 —— 用户反馈:新建文件不需要点
        // Apply。只有「编辑已存在文件」才排进 chat 里的审核卡片等确认
        // (Goal / workspace-access 模式仍照常自动应用编辑)。
        let isPureCreation = !parsed.isEmpty && parsed.allSatisfy(\.isNewFile)

        let proposalIndex: Int
        if let existingIndex = runtime.patchProposals.firstIndex(where: { $0.diff == diff }) {
            proposalIndex = existingIndex
        } else {
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let proposal = AgentPatchProposal(
                messageID: messageID,
                title: trimmedTitle?.isEmpty == false ? trimmedTitle! : "Agent Patch",
                diff: diff
            )
            runtime.patchProposals.append(proposal)
            proposalIndex = runtime.patchProposals.count - 1
        }

        // 直接落盘的三种情形:Goal / workspace-access 自动应用、纯新建
        // 文件、以及用户本轮明确要求「直接写 / 落盘 / 不用审核」
        // (applyImmediately)。其余编辑仍排进 chat 卡片等用户点 Apply。
        if (autoApplySource != nil || isPureCreation || applyImmediately),
           runtime.patchProposals[proposalIndex].status == .pending {
            let appliedMessage = autoApplySource
                .map(autoApplyStatusMessage(for:))
                ?? (isPureCreation ? "New file written automatically" : "Applied immediately as requested")
            let outcome = resolveAgentPatchApplication(diff, appliedMessage: appliedMessage)
            runtime.patchProposals[proposalIndex].status = outcome.status
            runtime.patchProposals[proposalIndex].statusMessage = outcome.message
        }

        persistAgentSession(runtime: runtime)
        return runtime.patchProposals[proposalIndex]
    }

    private func autoApplyStatusMessage(for source: AgentToolApprovalSource) -> String {
        switch source {
        case .goalMode:
            return "Auto-applied by Goal mode"
        case .workspaceAccess:
            return "Auto-applied by workspace access approval"
        default:
            return "Auto-applied"
        }
    }

    private func pendingPatchAutoApplySource(for runtime: AgentRuntime) -> AgentToolApprovalSource? {
        if runtime.interactionMode == .goal {
            return .goalMode
        }
        if runtime.interactionMode != .plan,
           runtime.approvalMode == .workspaceAccess {
            return .workspaceAccess
        }
        return nil
    }

    func applyAgentPatch(_ diff: String) throws {
        // Agent mode 下 editor 窗口的 `rootDirectory` 经常是 nil(没在
        // editor 里打开文件夹),但 agent 会话本身锚在一个 workspace 上。
        // 之前只看 `rootDirectory` → 一律报「请先打开项目文件夹」,哪怕
        // 用户明明在 mylinux 这个 workspace 里。改成和 worktree diff 同
        // 一套优先级:已知 git repo root → 会话 workspaceRootPath → editor
        // rootDirectory。
        guard let resolvedRoot = agentPatchWorkspaceRoot() else {
            throw AgentPatchError.noWorkspace
        }

        let changes = try AgentPatchApplier.parse(diff)
        let root = resolvedRoot.standardizedFileURL
        let rootPath = root.path
        var pendingWrites: [(url: URL, content: String, relativePath: String)] = []

        for change in changes {
            let url = try resolveAgentPatchURL(change.path, root: root, rootPath: rootPath)
            if change.isNewFile {
                // Creating a file: no existing content to read; the diff's
                // added lines are the whole file.
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentPatchError.targetAlreadyExists(change.path)
                }
                let newContent = try AgentPatchApplier.apply(change, to: "")
                let relativePath = Self.relativeWorkspacePath(for: url, root: root, rootPath: rootPath)
                pendingWrites.append((url, newContent, relativePath))
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentPatchError.missingFile(change.path)
            }

            let currentContent = try editableContent(forAgentPatchURL: url)
            let newContent = try AgentPatchApplier.apply(change, to: currentContent)
            let relativePath = Self.relativeWorkspacePath(for: url, root: root, rootPath: rootPath)
            pendingWrites.append((url, newContent, relativePath))
        }

        for pendingWrite in pendingWrites {
            // Ensure parent directories exist for newly created files.
            try FileManager.default.createDirectory(
                at: pendingWrite.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pendingWrite.content.write(to: pendingWrite.url, atomically: true, encoding: .utf8)
            applyAgentPatchedContent(pendingWrite.content, to: pendingWrite.url)
        }

        // Mark this session as having had the Agent actually touch files so
        // the worktree-change card can show. Fresh sessions with no applied
        // patch never get the card, even if the repo has unrelated diffs.
        if !pendingWrites.isEmpty {
            agentSessionDidEditFiles = true
            // Record each written path so the card stays scoped to files
            // Agent actually touched in THIS session — never the user's
            // own diffs or untracked build artifacts.
            var edited = agentEditedRelativePaths
            for write in pendingWrites where !write.relativePath.isEmpty {
                edited.insert(write.relativePath)
            }
            agentEditedRelativePaths = edited
            persistActiveAgentSession()
        }

        refreshGitStatus()
        persistSession()
    }

    /// Workspace root used for resolving / confining agent patches.
    /// Mirrors the worktree-diff resolver so patch apply works in Agent
    /// mode even when the editor window has no folder open.
    func agentPatchWorkspaceRoot() -> URL? {
        if let runtime = activeRuntime,
           (runtime.workspaceRootPath?.isEmpty == false || runtime.workspaceLocation?.localPath != nil) {
            return try? runtime.localWorkspaceURLForOptimisticUse()
        }
        if let repoRoot = agentWorktreeChanges.repositoryRoot {
            return repoRoot.standardizedFileURL
        }
        return rootDirectory?.standardizedFileURL
    }

    nonisolated static func relativeWorkspacePath(for url: URL, root: URL, rootPath: String) -> String {
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(rootPath + "/") else { return "" }
        return String(standardized.dropFirst(rootPath.count + 1))
    }

    func resolveAgentPatchURL(_ path: String, root: URL, rootPath: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let filePath = url.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            throw AgentPatchError.pathOutsideWorkspace(path)
        }
        return url
    }

    func editableContent(forAgentPatchURL url: URL) throws -> String {
        if let tab = tabs.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            return tab.content
        }

        let data = try Self.readFileData(from: url, allowLargeFile: true)
        return Self.decodeText(from: data)
    }

    func applyAgentPatchedContent(_ content: String, to url: URL) {
        let standardizedPath = url.standardizedFileURL.path

        for index in tabs.indices where tabs[index].url.standardizedFileURL.path == standardizedPath {
            if tabs[index].content != content {
                tabs[index].contentRevision += 1
            }
            tabs[index].content = content
            if tabs[index].savedContent != content {
                tabs[index].savedContentRevision += 1
            }
            tabs[index].savedContent = content
            tabs[index].isEdited = false
        }

        if openedFileURL?.standardizedFileURL.path == standardizedPath {
            isApplyingTabSnapshot = true
            fileContent = content
            isEdited = false
            isApplyingTabSnapshot = false
            bumpEditorRenderRevision()
            bumpEditorHighlightRevision()
            updateWindowTitle(url: url, isEdited: false)
        }

        knownModificationDates[url] = Self.modificationDate(at: url)
        hasExternalFileChanges = false
    }
}
