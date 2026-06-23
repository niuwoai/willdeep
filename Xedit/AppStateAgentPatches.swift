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

    func applyAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }

        do {
            try applyAgentPatch(agentPatchProposals[index].diff)
            agentPatchProposals[index].status = .applied
            agentPatchProposals[index].statusMessage = "Applied"
        } catch {
            agentPatchProposals[index].status = .failed
            agentPatchProposals[index].statusMessage = error.localizedDescription
        }
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
        autoApplySource: AgentToolApprovalSource? = nil
    ) throws -> AgentPatchProposal {
        _ = try AgentPatchApplier.parse(diff)

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

        if let autoApplySource,
           runtime.patchProposals[proposalIndex].status == .pending {
            do {
                try applyAgentPatch(diff)
                runtime.patchProposals[proposalIndex].status = .applied
                runtime.patchProposals[proposalIndex].statusMessage = autoApplyStatusMessage(for: autoApplySource)
            } catch {
                runtime.patchProposals[proposalIndex].status = .failed
                runtime.patchProposals[proposalIndex].statusMessage = error.localizedDescription
            }
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

    func applyAgentPatch(_ diff: String) throws {
        guard let rootDirectory else {
            throw AgentPatchError.noWorkspace
        }

        let changes = try AgentPatchApplier.parse(diff)
        let root = rootDirectory.standardizedFileURL
        let rootPath = root.path
        var pendingWrites: [(url: URL, content: String, relativePath: String)] = []

        for change in changes {
            let url = try resolveAgentPatchURL(change.path, root: root, rootPath: rootPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentPatchError.missingFile(change.path)
            }

            let currentContent = try editableContent(forAgentPatchURL: url)
            let newContent = try AgentPatchApplier.apply(change, to: currentContent)
            let relativePath = Self.relativeWorkspacePath(for: url, root: root, rootPath: rootPath)
            pendingWrites.append((url, newContent, relativePath))
        }

        for pendingWrite in pendingWrites {
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
            tabs[index].content = content
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
