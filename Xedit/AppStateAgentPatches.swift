//
//  AppStateAgentPatches.swift
//  WillDeep
//
//  Agent patch proposal capture and application helpers split from
//  AppStateAgentLoop.swift.
//

import Foundation

enum AgentPatchRollbackAction: Equatable {
    case noChangeNeeded
    case restoreOriginal
    case removeNewFile
    case preserveConflict
}

extension AppState {
    func isAgentPatchReviewCollecting(forMessageID messageID: AgentMessage.ID) -> Bool {
        activeRuntime?.collectingPatchReviewMessageIDs.contains(messageID) == true
    }

    func rejectAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let runtime = activeRuntime,
              let index = runtime.patchProposals.firstIndex(where: { $0.id == id }),
              runtime.patchProposals[index].status == .pending,
              !runtime.collectingPatchReviewMessageIDs.contains(
                runtime.patchProposals[index].messageID
              ) else {
            return
        }
        runtime.patchProposals[index].status = .rejected
        runtime.patchProposals[index].statusMessage = "Rejected"
        synchronizeAgentPatchDecision(runtime.patchProposals[index], in: runtime)
        resumeAgentPatchDecisionWaiter(id: id, runtime: runtime)
        persistAgentSession(runtime: runtime)
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
            synchronizeAgentPatchDecision(runtime.patchProposals[index], in: runtime)
            resumeAgentPatchDecisionWaiter(id: runtime.patchProposals[index].id, runtime: runtime)
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

    /// Resolve cancellation for one review batch as a single main-actor
    /// transition. Every proposal, persisted tool result, live tool-call
    /// result, and registered waiter observes the same terminal state before
    /// any continuation can resume.
    @discardableResult
    private func rejectPendingAgentPatchProposals(
        forMessageID messageID: AgentMessage.ID,
        runtime: AgentRuntime,
        statusMessage: String
    ) -> [AgentPatchProposal] {
        let indices = runtime.patchProposals.indices.filter {
            runtime.patchProposals[$0].messageID == messageID
                && runtime.patchProposals[$0].status == .pending
        }
        guard !indices.isEmpty else {
            return runtime.patchProposals.filter { $0.messageID == messageID }
        }

        for index in indices {
            runtime.patchProposals[index].status = .rejected
            runtime.patchProposals[index].statusMessage = statusMessage
            synchronizeAgentPatchDecision(runtime.patchProposals[index], in: runtime)
        }
        let proposalIDs = indices.map { runtime.patchProposals[$0].id }
        for proposalID in proposalIDs {
            resumeAgentPatchDecisionWaiter(id: proposalID, runtime: runtime)
        }
        persistAgentSession(runtime: runtime)
        return runtime.patchProposals.filter { $0.messageID == messageID }
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
                runtime: runtime,
                appliedMessage: autoApplyStatusMessage(for: source)
            )
            runtime.patchProposals[index].status = outcome.status
            runtime.patchProposals[index].statusMessage = outcome.message
            synchronizeAgentPatchDecision(runtime.patchProposals[index], in: runtime)
            resumeAgentPatchDecisionWaiter(id: runtime.patchProposals[index].id, runtime: runtime)
            resolvedCount += 1
        }

        if resolvedCount > 0 {
            persistAgentSession(runtime: runtime)
        }
        return resolvedCount
    }

    /// Apply every still-pending proposal that belongs to one assistant
    /// message (one review batch). Backs the "Apply All" button on the
    /// collapsed patch group card. Diffs are merged before application so the
    /// patch applier validates every target/hunk before it starts writing;
    /// one stale proposal therefore cannot leave the earlier files applied
    /// and the later files failed.
    func applyAgentPatchProposals(forMessageID messageID: AgentMessage.ID) {
        guard let runtime = activeRuntime,
              !runtime.collectingPatchReviewMessageIDs.contains(messageID) else {
            return
        }
        let indices = runtime.patchProposals.indices.filter {
            runtime.patchProposals[$0].messageID == messageID
                && runtime.patchProposals[$0].status == .pending
        }
        guard !indices.isEmpty else { return }

        let combinedDiff = indices
            .map { runtime.patchProposals[$0].diff }
            // `AgentPatchApplier` flushes the preceding file when it sees a
            // `diff --git` header. Plain `---` / `+++` headers alone do not
            // delimit two independently generated proposal strings.
            .joined(separator: "\ndiff --git a/.willdeep-review-boundary b/.willdeep-review-boundary\n")
        let outcome = resolveAgentPatchApplication(
            combinedDiff,
            runtime: runtime,
            appliedMessage: "Applied as part of batch"
        )
        for index in indices {
            runtime.patchProposals[index].status = outcome.status
            runtime.patchProposals[index].statusMessage = outcome.message
            synchronizeAgentPatchDecision(runtime.patchProposals[index], in: runtime)
            resumeAgentPatchDecisionWaiter(
                id: runtime.patchProposals[index].id,
                runtime: runtime
            )
        }
        persistAgentSession(runtime: runtime)
    }

    /// Reject every still-pending proposal from one assistant message.
    /// Backs the "Reject All" button on the collapsed patch group card.
    func rejectAgentPatchProposals(forMessageID messageID: AgentMessage.ID) {
        guard let runtime = activeRuntime,
              !runtime.collectingPatchReviewMessageIDs.contains(messageID) else {
            return
        }
        rejectPendingAgentPatchProposals(
            forMessageID: messageID,
            runtime: runtime,
            statusMessage: "Rejected"
        )
    }

    /// Apply every still-pending proposal across ALL assistant messages.
    /// Backs the transcript-level "Apply All" bar shown when several
    /// independent patch cards stack up (e.g. one patch per turn over
    /// many turns). Reuses the single-proposal path so disk writes, tab
    /// sync and status messages stay identical.
    func applyAllPendingAgentPatchProposals() {
        guard let runtime = activeRuntime,
              !runtime.patchProposals.contains(where: {
                  $0.status == .pending
                      && runtime.collectingPatchReviewMessageIDs.contains($0.messageID)
              }) else {
            return
        }
        let ids = agentPatchProposals
            .filter { $0.status == .pending }
            .map(\.id)
        for id in ids {
            applyAgentPatchProposal(id: id)
        }
    }

    /// Reject every still-pending proposal across ALL assistant messages.
    func rejectAllPendingAgentPatchProposals() {
        guard let runtime = activeRuntime,
              !runtime.patchProposals.contains(where: {
                  $0.status == .pending
                      && runtime.collectingPatchReviewMessageIDs.contains($0.messageID)
              }) else {
            return
        }
        let ids = agentPatchProposals
            .filter { $0.status == .pending }
            .map(\.id)
        for id in ids {
            rejectAgentPatchProposal(id: id)
        }
    }

    func applyAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let runtime = activeRuntime,
              let index = runtime.patchProposals.firstIndex(where: { $0.id == id }),
              runtime.patchProposals[index].status == .pending,
              !runtime.collectingPatchReviewMessageIDs.contains(
                runtime.patchProposals[index].messageID
              ) else {
            return
        }

        let outcome = resolveAgentPatchApplication(
            runtime.patchProposals[index].diff,
            runtime: runtime,
            appliedMessage: "Applied"
        )
        runtime.patchProposals[index].status = outcome.status
        runtime.patchProposals[index].statusMessage = outcome.message
        synchronizeAgentPatchDecision(runtime.patchProposals[index], in: runtime)
        resumeAgentPatchDecisionWaiter(id: id, runtime: runtime)
        persistAgentSession(runtime: runtime)
    }

    /// Wait for one inline patch card to be resolved. The interactive Agent
    /// loop first enqueues every adjacent file-edit call from the model round,
    /// then waits through `awaitPendingAgentPatchProposals` so the user sees
    /// one review group instead of one blocking card per file. Direct tool
    /// harnesses may still use this single-proposal primitive.
    func awaitAgentPatchDecision(
        _ proposal: AgentPatchProposal,
        runtime: AgentRuntime
    ) async -> AgentPatchProposal {
        guard proposal.status == .pending else { return proposal }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let current = runtime.patchProposals.first(where: { $0.id == proposal.id }) else {
                    continuation.resume(returning: proposal)
                    return
                }
                guard current.status == .pending else {
                    continuation.resume(returning: current)
                    return
                }
                if Task.isCancelled {
                    rejectPendingAgentPatchProposals(
                        forMessageID: current.messageID,
                        runtime: runtime,
                        statusMessage: "Response stopped before patch approval"
                    )
                    let resolved = runtime.patchProposals.first(where: {
                        $0.id == proposal.id
                    }) ?? current
                    continuation.resume(returning: resolved)
                    return
                }
                runtime.patchDecisionWaiters[proposal.id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime else { return }
                self.rejectPendingAgentPatchProposals(
                    forMessageID: proposal.messageID,
                    runtime: runtime,
                    statusMessage: "Response stopped before patch approval"
                )
            }
        }
    }

    /// Settle every patch produced by one assistant message, waiting only for
    /// proposals that are still pending.
    ///
    /// The IDs are snapshotted before the first suspension. This lets the
    /// execution loop enqueue a consecutive run of create/edit/apply calls,
    /// surface all of their diffs together, and then pause once at the review
    /// boundary. "Apply All" / "Reject All" may resolve every proposal while
    /// only the first waiter is registered; later calls therefore re-read the
    /// runtime and return immediately instead of hanging.
    @discardableResult
    func awaitPendingAgentPatchProposals(
        forMessageID messageID: AgentMessage.ID,
        runtime: AgentRuntime
    ) async -> [AgentPatchProposal] {
        // Seal the collection before the first suspension. The UI observes
        // this published transition and enables Apply/Reject only after every
        // adjacent proposal for the batch is already present.
        runtime.collectingPatchReviewMessageIDs.remove(messageID)
        let proposalIDs = runtime.patchProposals
            .filter { $0.messageID == messageID && $0.status == .pending }
            .map(\.id)
        var resolved: [AgentPatchProposal] = []
        resolved.reserveCapacity(proposalIDs.count)

        for (offset, id) in proposalIDs.enumerated() {
            guard let proposal = runtime.patchProposals.first(where: { $0.id == id }) else {
                continue
            }
            let decision = await awaitAgentPatchDecision(proposal, runtime: runtime)
            // The user can click Apply All while the tool runner is still
            // finishing its textual result. Re-sync at the review boundary so
            // that race cannot leave a newly appended provider result saying
            // "pending" after the patch was already applied or rejected.
            let finalDecision = runtime.patchProposals.first(where: {
                $0.id == id
            }) ?? decision
            synchronizeAgentPatchDecision(finalDecision, in: runtime)
            resolved.append(finalDecision)
            if Task.isCancelled {
                for remainingID in proposalIDs.dropFirst(offset + 1) {
                    if let remaining = runtime.patchProposals.first(where: {
                        $0.id == remainingID
                    }) {
                        resolved.append(remaining)
                    }
                }
                break
            }
        }
        if !resolved.isEmpty {
            persistAgentSession(runtime: runtime)
        }
        return resolved
    }

    private func resumeAgentPatchDecisionWaiter(
        id: AgentPatchProposal.ID,
        runtime: AgentRuntime
    ) {
        guard let continuation = runtime.patchDecisionWaiters.removeValue(forKey: id),
              let proposal = runtime.patchProposals.first(where: { $0.id == id }) else {
            return
        }
        continuation.resume(returning: proposal)
    }

    /// Keep both copies of a completed tool result honest: the live tool-call
    /// ledger used by the UI and the persisted role=tool message replayed to
    /// the provider on later turns. This also repairs proposals created by
    /// older builds whose original result already said "pending".
    private func synchronizeAgentPatchDecision(
        _ proposal: AgentPatchProposal,
        in runtime: AgentRuntime
    ) {
        let patchIDLine = "Patch ID: \(proposal.id.uuidString)"
        for index in runtime.messages.indices
            where runtime.messages[index].role == .tool
                && runtime.messages[index].content.contains(patchIDLine) {
            runtime.messages[index].content = patchDecisionPayload(
                replacing: runtime.messages[index].content,
                with: proposal
            )
        }

        for index in runtime.toolCalls.indices {
            guard let result = runtime.toolCalls[index].result,
                  result.payload.contains(patchIDLine) else {
                continue
            }
            runtime.toolCalls[index].result = AgentToolResult(
                summary: patchDecisionSummary(replacing: result.summary, with: proposal.status),
                payload: patchDecisionPayload(replacing: result.payload, with: proposal),
                references: result.references,
                images: result.images
            )
        }
    }

    private func patchDecisionSummary(
        replacing summary: String,
        with status: AgentPatchStatus
    ) -> String {
        let prefix: String
        switch status {
        case .pending:
            prefix = "patch queued:"
        case .applied:
            prefix = "patch applied:"
        case .rejected:
            prefix = "patch rejected:"
        case .failed:
            prefix = "patch failed:"
        }
        guard let separator = summary.firstIndex(of: ":") else {
            return "\(prefix.dropLast()) patch"
        }
        return prefix + summary[summary.index(after: separator)...]
    }

    private func patchDecisionPayload(
        replacing payload: String,
        with proposal: AgentPatchProposal
    ) -> String {
        let placement: String
        let statusLine: String
        switch proposal.status {
        case .pending:
            return payload
        case .applied:
            placement = "Changes written to disk after user approval. No further approval is required for this patch."
            statusLine = "Patch status: applied. The user already approved this patch; do not ask for approval again."
        case .rejected:
            placement = "The user rejected this patch. Do not apply it unless the user explicitly asks again."
            statusLine = "Patch status: rejected."
        case .failed:
            placement = "The user approved this patch, but applying it failed. Diagnose the failure before retrying."
            statusLine = "Patch status: failed: \(proposal.statusMessage ?? "unknown error")"
        }

        return payload
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                if trimmed.hasPrefix("Patch status:") {
                    return String(indentation) + statusLine
                }
                if trimmed.hasPrefix("A patch card is shown inline")
                    || trimmed.hasPrefix("Changes written to disk") {
                    return String(indentation) + placement
                }
                return line
            }
            .joined(separator: "\n")
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
        resolveAgentPatchApplication(
            diff,
            runtime: activeRuntime,
            appliedMessage: appliedMessage
        )
    }

    func resolveAgentPatchApplication(
        _ diff: String,
        runtime: AgentRuntime?,
        appliedMessage: String
    ) -> (status: AgentPatchStatus, message: String) {
        do {
            try applyAgentPatch(diff, runtime: runtime)
            return (.applied, appliedMessage)
        } catch {
            if case AgentPatchError.hunkDidNotMatch = error,
               agentPatchIsAlreadyApplied(diff, runtime: runtime) {
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
        agentPatchIsAlreadyApplied(diff, runtime: activeRuntime)
    }

    func agentPatchIsAlreadyApplied(_ diff: String, runtime: AgentRuntime?) -> Bool {
        guard let root = agentPatchWorkspaceRoot(for: runtime) else { return false }
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

        // Dispatch workers have no operator attached to their conversation.
        // Plain fenced diffs must follow the same unattended auto-apply path
        // as create_file / edit_file / apply_patch instead of becoming review
        // cards that can suspend the scheduler forever.
        if runtime.isUnattendedDispatchTask {
            _ = autoApplyPendingAgentPatchProposals(for: runtime, source: .dispatchTask)
        }

        let existingDiffs = Set(runtime.patchProposals.map(\.diff))
        for (offset, diff) in diffs.enumerated() where !existingDiffs.contains(diff) {
            let title = diffs.count == 1 ? "Agent Patch" : "Agent Patch \(offset + 1)"
            if runtime.isUnattendedDispatchTask {
                do {
                    _ = try enqueueAgentPatchProposal(
                        for: runtime,
                        messageID: messageID,
                        title: title,
                        diff: diff,
                        autoApplySource: .dispatchTask
                    )
                } catch {
                    runtime.patchProposals.append(
                        AgentPatchProposal(
                            messageID: messageID,
                            title: title,
                            diff: diff,
                            status: .failed,
                            statusMessage: "Unattended dispatch auto-apply failed: \(error.localizedDescription)"
                        )
                    )
                    persistAgentSession(runtime: runtime)
                }
                continue
            }
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
        try validateUniqueAgentPatchTargets(parsed, runtime: runtime)

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

        let effectiveAutoApplySource = autoApplySource
            ?? (runtime.approvalMode == .smart ? AgentToolApprovalSource.staticAllowlist : nil)

        // Goal, Smart review, and Workspace Access apply validated
        // workspace-contained patches immediately. Strict mode is the only
        // posture that leaves every file change pending for explicit review.
        if let effectiveAutoApplySource,
           runtime.patchProposals[proposalIndex].status == .pending {
            let outcome = resolveAgentPatchApplication(
                diff,
                runtime: runtime,
                appliedMessage: autoApplyStatusMessage(for: effectiveAutoApplySource)
            )
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
        case .dispatchTask:
            return "Auto-applied by unattended dispatch task"
        case .workspaceAccess:
            return "Auto-applied by workspace access approval"
        case .staticAllowlist:
            return "Auto-applied by Smart review"
        default:
            return "Auto-applied"
        }
    }

    private func pendingPatchAutoApplySource(for runtime: AgentRuntime) -> AgentToolApprovalSource? {
        if runtime.isUnattendedDispatchTask {
            return .dispatchTask
        }
        if runtime.interactionMode == .goal {
            return .goalMode
        }
        if runtime.approvalMode == .workspaceAccess {
            return .workspaceAccess
        }
        if runtime.approvalMode == .smart {
            return .staticAllowlist
        }
        return nil
    }

    func applyAgentPatch(_ diff: String) throws {
        try applyAgentPatch(diff, runtime: activeRuntime)
    }

    func applyAgentPatch(_ diff: String, runtime: AgentRuntime?) throws {
        // Agent mode 下 editor 窗口的 `rootDirectory` 经常是 nil(没在
        // editor 里打开文件夹),但 agent 会话本身锚在一个 workspace 上。
        // 之前只看 `rootDirectory` → 一律报「请先打开项目文件夹」,哪怕
        // 用户明明在 mylinux 这个 workspace 里。改成和 worktree diff 同
        // 一套优先级:已知 git repo root → 会话 workspaceRootPath → editor
        // rootDirectory。
        guard let resolvedRoot = agentPatchWorkspaceRoot(for: runtime) else {
            throw AgentPatchError.noWorkspace
        }

        let changes = try AgentPatchApplier.parse(diff)
        let root = resolvedRoot.standardizedFileURL
        let rootPath = root.path
        try validateUniqueAgentPatchTargets(changes, runtime: runtime)
        var pendingWrites: [(
            url: URL,
            content: String,
            originalData: Data?,
            relativePath: String,
            isNewFile: Bool
        )] = []

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
                pendingWrites.append((url, newContent, nil, relativePath, true))
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentPatchError.missingFile(change.path)
            }

            // Disk-backed edits must derive both the hunk result and the CAS
            // baseline from one read. Otherwise an external edit between two
            // reads could be accepted as the baseline and then overwritten by
            // a patch calculated from older bytes. An open tab intentionally
            // remains the edit source, while these same disk bytes protect the
            // eventual save from concurrent on-disk changes.
            let originalData = try Data(contentsOf: url)
            let standardizedPath = url.standardizedFileURL.path
            let currentContent: String
            if let tab = tabs.first(where: {
                $0.url.standardizedFileURL.path == standardizedPath
            }) {
                currentContent = tab.content
            } else {
                currentContent = Self.decodeText(from: originalData)
            }
            let newContent = try AgentPatchApplier.apply(change, to: currentContent)
            let relativePath = Self.relativeWorkspacePath(for: url, root: root, rootPath: rootPath)
            pendingWrites.append((url, newContent, originalData, relativePath, false))
        }

        var attemptedWrites: [(
            url: URL,
            content: String,
            originalData: Data?,
            relativePath: String,
            isNewFile: Bool
        )] = []
        do {
            for pendingWrite in pendingWrites {
                let displayPath = pendingWrite.relativePath.isEmpty
                    ? pendingWrite.url.lastPathComponent
                    : pendingWrite.relativePath
                if let originalData = pendingWrite.originalData {
                    // Approval can sit open while another process edits the
                    // workspace. Re-check the exact preflight bytes before
                    // replacing this target so rollback never overwrites a
                    // newer external change with an older snapshot.
                    guard (try? Data(contentsOf: pendingWrite.url)) == originalData else {
                        throw AgentPatchError.hunkDidNotMatch(displayPath)
                    }
                } else {
                    guard !FileManager.default.fileExists(atPath: pendingWrite.url.path) else {
                        throw AgentPatchError.targetAlreadyExists(displayPath)
                    }
                }
                // Track the attempt before Foundation's atomic replacement.
                // If the call reports an error after touching the target, the
                // rollback below still knows to inspect and restore it.
                attemptedWrites.append(pendingWrite)
                try FileManager.default.createDirectory(
                    at: pendingWrite.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pendingWrite.content.write(
                    to: pendingWrite.url,
                    atomically: true,
                    encoding: .utf8
                )
                let verifiedContent = try Self.decodeText(
                    from: Self.readFileData(from: pendingWrite.url, allowLargeFile: true)
                )
                guard verifiedContent == pendingWrite.content else {
                    throw AgentPatchError.writeVerificationFailed(
                        displayPath
                    )
                }
            }
        } catch {
            let originalError = error
            let rollbackFailures = rollbackAgentPatchWrites(attemptedWrites)
            guard rollbackFailures.isEmpty else {
                throw AgentPatchError.rollbackFailed(
                    rollbackFailures.joined(separator: ", ")
                )
            }
            throw originalError
        }

        // Keep editor buffers untouched until every disk write has succeeded.
        // A failed batch can then roll the filesystem back without also
        // reconstructing tab content/revision/dirty state.
        for pendingWrite in pendingWrites {
            applyAgentPatchedContent(pendingWrite.content, to: pendingWrite.url)
        }

        // Mark this session as having had the Agent actually touch files so
        // the worktree-change card can show. Fresh sessions with no applied
        // patch never get the card, even if the repo has unrelated diffs.
        if !pendingWrites.isEmpty {
            let trackingRuntime = runtime ?? activeRuntime
            trackingRuntime?.didEditFiles = true
            // Record each written path so the card stays scoped to files
            // Agent actually touched in THIS session — never the user's
            // own diffs or untracked build artifacts.
            var edited = trackingRuntime?.agentEditedPaths ?? []
            var artifacts = trackingRuntime?.agentArtifactPaths ?? []
            for write in pendingWrites where !write.relativePath.isEmpty {
                edited.insert(write.relativePath)
                if write.isNewFile, Self.isAgentSessionArtifactPath(write.relativePath) {
                    artifacts.insert(write.relativePath)
                }
            }
            trackingRuntime?.agentEditedPaths = edited
            trackingRuntime?.agentArtifactPaths = artifacts
            if let trackingRuntime {
                persistAgentSession(runtime: trackingRuntime)
            } else {
                persistActiveAgentSession()
            }
        }

        refreshAgentPatchGitStatus(for: runtime, workspaceRoot: root)
        persistSession()
    }

    private func validateUniqueAgentPatchTargets(
        _ changes: [AgentPatchFileChange],
        runtime: AgentRuntime?
    ) throws {
        guard let resolvedRoot = agentPatchWorkspaceRoot(for: runtime) else {
            throw AgentPatchError.noWorkspace
        }
        let root = resolvedRoot.standardizedFileURL
        let rootPath = root.path
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRootPath = canonicalRoot.path
        let volumeSupportsCaseSensitiveNames = (
            try? canonicalRoot.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames
        ) ?? false
        var targetIdentities: Set<String> = []

        for change in changes {
            let url = try resolveAgentPatchURL(change.path, root: root, rootPath: rootPath)
            let canonicalURL: URL
            if FileManager.default.fileExists(atPath: url.path) {
                canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            } else {
                canonicalURL = url.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(url.lastPathComponent)
                    .standardizedFileURL
            }
            let canonicalPath = canonicalURL.path
            guard canonicalPath == canonicalRootPath
                    || canonicalPath.hasPrefix(canonicalRootPath + "/") else {
                throw AgentPatchError.pathOutsideWorkspace(change.path)
            }

            let identity: String
            if !change.isNewFile,
               let attributes = try? FileManager.default.attributesOfItem(
                   atPath: canonicalPath
               ),
               let systemNumber = attributes[.systemNumber],
               let fileNumber = attributes[.systemFileNumber] {
                // Device + inode catches hard-link aliases in addition to
                // repeated lexical paths and symlink aliases.
                identity = "inode:\(systemNumber):\(fileNumber)"
            } else {
                let normalizedPath = canonicalPath.precomposedStringWithCanonicalMapping
                identity = "path:" + (
                    volumeSupportsCaseSensitiveNames
                        ? normalizedPath
                        : normalizedPath.lowercased()
                )
            }
            guard targetIdentities.insert(identity).inserted else {
                throw AgentPatchError.duplicateTarget(change.path)
            }
        }
    }

    private func rollbackAgentPatchWrites(
        _ writes: [(
            url: URL,
            content: String,
            originalData: Data?,
            relativePath: String,
            isNewFile: Bool
        )]
    ) -> [String] {
        var failures: [String] = []
        for write in writes.reversed() {
            let displayPath = write.relativePath.isEmpty
                ? write.url.lastPathComponent
                : write.relativePath
            do {
                let currentData = try? Data(contentsOf: write.url)
                let expectedData = write.content.data(using: .utf8) ?? Data()
                switch Self.agentPatchRollbackAction(
                    currentData: currentData,
                    originalData: write.originalData,
                    expectedData: expectedData
                ) {
                case .noChangeNeeded:
                    continue
                case .restoreOriginal:
                    guard let originalData = write.originalData else {
                        throw AgentPatchError.rollbackFailed(displayPath)
                    }
                    try originalData.write(to: write.url, options: .atomic)
                    guard (try? Data(contentsOf: write.url)) == originalData else {
                        throw AgentPatchError.writeVerificationFailed(displayPath)
                    }
                case .removeNewFile:
                    try FileManager.default.removeItem(at: write.url)
                case .preserveConflict:
                    // A newer external edit owns the current bytes. Keep it
                    // intact and report that rollback could not be completed.
                    throw AgentPatchError.rollbackFailed(displayPath)
                }
            } catch {
                failures.append(displayPath)
            }
        }
        return failures
    }

    nonisolated static func agentPatchRollbackAction(
        currentData: Data?,
        originalData: Data?,
        expectedData: Data
    ) -> AgentPatchRollbackAction {
        if let originalData {
            if currentData == originalData {
                return .noChangeNeeded
            }
            return currentData == expectedData
                ? .restoreOriginal
                : .preserveConflict
        }
        guard let currentData else {
            return .noChangeNeeded
        }
        return currentData == expectedData
            ? .removeNewFile
            : .preserveConflict
    }

    /// Workspace root used for resolving / confining agent patches.
    /// Mirrors the worktree-diff resolver so patch apply works in Agent
    /// mode even when the editor window has no folder open.
    func agentPatchWorkspaceRoot() -> URL? {
        agentPatchWorkspaceRoot(for: activeRuntime)
    }

    func agentPatchWorkspaceRoot(for runtime: AgentRuntime?) -> URL? {
        if let runtime,
           (runtime.workspaceRootPath?.isEmpty == false || runtime.workspaceLocation?.localPath != nil) {
            return try? runtime.localWorkspaceURLForOptimisticUse()
        }
        if let repoRoot = agentWorktreeChanges.repositoryRoot {
            return repoRoot.standardizedFileURL
        }
        return rootDirectory?.standardizedFileURL
    }

    private func refreshAgentPatchGitStatus(for runtime: AgentRuntime?, workspaceRoot: URL) {
        guard let runtime else {
            refreshGitStatus()
            return
        }

        let targetDirectory = workspaceRoot.standardizedFileURL
        let runtimeID = runtime.id
        let editedPaths = runtime.agentEditedPaths
        Task { [weak self] in
            let snapshot = await Self.loadAgentWorktreeSnapshot(
                for: targetDirectory,
                restrictTo: editedPaths
            )
            await MainActor.run {
                guard let self,
                      let liveRuntime = self.agentRuntimes[runtimeID] else {
                    return
                }
                guard let liveWorkspaceURL = try? liveRuntime.localWorkspaceURLForOptimisticUse(),
                      liveWorkspaceURL.standardizedFileURL.path == targetDirectory.path else {
                    return
                }

                if liveRuntime.worktreeChanges != snapshot.changes {
                    liveRuntime.worktreeChanges = snapshot.changes
                }
                if self.rootDirectory?.standardizedFileURL.path == targetDirectory.path,
                   self.gitStatus != snapshot.status {
                    self.gitStatus = snapshot.status
                }
            }
        }
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

    func writeDelegatedAgentContent(
        _ content: String,
        to url: URL,
        runtime: AgentRuntime,
        workspaceRoot: URL
    ) throws {
        let root = workspaceRoot.standardizedFileURL
        let destination: URL
        do {
            destination = try AgentWorkspacePathGuard.validate(
                url,
                root: root
            )
        } catch {
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [
                    NSFilePathErrorKey: url.standardizedFileURL.path,
                    NSLocalizedDescriptionKey: "Delegated agent write is outside the workspace.",
                ]
            )
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: destination, options: .atomic)
        applyAgentPatchedContent(content, to: destination)
        runtime.didEditFiles = true
        let relativePath = destination.path == root.path
            ? destination.lastPathComponent
            : String(destination.path.dropFirst(root.path.count + 1))
        runtime.agentEditedPaths.insert(relativePath)
    }
}
