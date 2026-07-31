//
//  AgentPatchBatchApprovalTests.swift
//  WillDeepTests
//
//  同一轮多个文件补丁必须一起进入审核态，并由 Apply All / Reject All
//  一次性解除工具循环等待。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Agent 补丁批量审批", .serialized)
@MainActor
struct AgentPatchBatchApprovalTests {
    @Test("同轮补丁全部可见后 Apply All 写入所有文件并结束等待")
    func applyAllResolvesPendingPatchBatch() async throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_apply",
            files: [
                "First.swift": "let first = 1\n",
                "Second.swift": "let second = 1\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime

        let messageID = UUID()
        let proposals = try enqueueModifyProposals(
            appState: appState,
            runtime: runtime,
            messageID: messageID
        )

        #expect(proposals.count == 2)
        #expect(runtime.patchProposals.filter { $0.messageID == messageID }.count == 2)
        #expect(runtime.patchProposals.allSatisfy { $0.status == .pending })
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 1\n")

        runtime.collectingPatchReviewMessageIDs.insert(messageID)
        let waitTask = Task { @MainActor in
            await appState.awaitPendingAgentPatchProposals(
                forMessageID: messageID,
                runtime: runtime
            )
        }
        await waitUntilPatchDecisionIsRegistered(runtime: runtime)
        #expect(!runtime.collectingPatchReviewMessageIDs.contains(messageID))

        appState.applyAgentPatchProposals(forMessageID: messageID)
        let resolved = await waitTask.value

        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.status == .applied })
        #expect(runtime.patchProposals.allSatisfy { $0.status == .applied })
        #expect(runtime.patchDecisionWaiters.isEmpty)
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 2\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 2\n")
    }

    @Test("同轮补丁全部可见后 Reject All 保持磁盘不变并结束等待")
    func rejectAllResolvesPendingPatchBatchWithoutWriting() async throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_reject",
            files: [
                "First.swift": "let first = 1\n",
                "Second.swift": "let second = 1\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime

        let messageID = UUID()
        let proposals = try enqueueModifyProposals(
            appState: appState,
            runtime: runtime,
            messageID: messageID
        )

        #expect(proposals.count == 2)
        #expect(runtime.patchProposals.filter { $0.messageID == messageID }.count == 2)
        #expect(runtime.patchProposals.allSatisfy { $0.status == .pending })
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 1\n")

        let waitTask = Task { @MainActor in
            await appState.awaitPendingAgentPatchProposals(
                forMessageID: messageID,
                runtime: runtime
            )
        }
        await waitUntilPatchDecisionIsRegistered(runtime: runtime)

        appState.rejectAgentPatchProposals(forMessageID: messageID)
        let resolved = await waitTask.value

        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.status == .rejected })
        #expect(runtime.patchProposals.allSatisfy { $0.status == .rejected })
        #expect(runtime.patchDecisionWaiters.isEmpty)
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 1\n")
    }

    @Test("停止审批等待会原子拒绝整批并同步模型历史")
    func cancellationRejectsWholeBatchAndKeepsReceiptsConsistent() async throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_cancel",
            files: [
                "First.swift": "let first = 1\n",
                "Second.swift": "let second = 1\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime
        let messageID = UUID()
        let proposals = try enqueueModifyProposals(
            appState: appState,
            runtime: runtime,
            messageID: messageID
        )
        for (index, proposal) in proposals.enumerated() {
            installPendingToolReceipt(
                for: proposal,
                externalID: "cancel_patch_\(index)",
                runtime: runtime
            )
        }

        runtime.collectingPatchReviewMessageIDs.insert(messageID)
        let waitTask = Task { @MainActor in
            await appState.awaitPendingAgentPatchProposals(
                forMessageID: messageID,
                runtime: runtime
            )
        }
        await waitUntilPatchDecisionIsRegistered(runtime: runtime)
        waitTask.cancel()
        let resolved = await waitTask.value

        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.status == .rejected })
        #expect(runtime.patchProposals.allSatisfy { $0.status == .rejected })
        #expect(runtime.patchDecisionWaiters.isEmpty)
        for proposal in proposals {
            let patchIDLine = "Patch ID: \(proposal.id.uuidString)"
            let message = try #require(runtime.messages.first {
                $0.role == .tool && $0.content.contains(patchIDLine)
            })
            #expect(message.content.contains("Patch status: rejected"))
            #expect(!message.content.contains("Patch status: pending"))
            let call = try #require(runtime.toolCalls.first {
                $0.result?.payload.contains(patchIDLine) == true
            })
            #expect(call.result?.payload.contains("Patch status: rejected") == true)
            #expect(call.result?.summary.hasPrefix("patch rejected:") == true)
        }

        // A stale click or delayed mobile command cannot resurrect a batch
        // after cancellation has made the terminal decision visible.
        appState.applyAgentPatchProposal(id: proposals[0].id)
        #expect(runtime.patchProposals.allSatisfy { $0.status == .rejected })
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 1\n")
    }

    @Test("批量应用先校验全部补丁，后一个失效时不写入前一个")
    func applyAllPreflightsEveryPatchBeforeWriting() async throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_preflight",
            files: [
                "First.swift": "let first = 1\n",
                "Second.swift": "let second = 1\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime

        let messageID = UUID()
        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "有效的第一个补丁",
            diff: modifyDiff(
                path: "First.swift",
                oldLine: "let first = 1",
                newLine: "let first = 2"
            )
        )
        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "已过期的第二个补丁",
            diff: modifyDiff(
                path: "Second.swift",
                oldLine: "let second = 999",
                newLine: "let second = 2"
            )
        )

        let waitTask = Task { @MainActor in
            await appState.awaitPendingAgentPatchProposals(
                forMessageID: messageID,
                runtime: runtime
            )
        }
        await waitUntilPatchDecisionIsRegistered(runtime: runtime)

        appState.applyAgentPatchProposals(forMessageID: messageID)
        let resolved = await waitTask.value

        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.status == .failed })
        #expect(runtime.patchDecisionWaiters.isEmpty)
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 1\n")
    }

    @Test("只有目标路径不重叠的文件工具可以共享审核批次")
    func patchReviewPathKeysDetectOverlap() throws {
        let first = try #require(AppState.patchReviewPathKeys(
            toolName: "edit_file",
            arguments: ["path": .string("./Sources/../First.swift")]
        ))
        let same = try #require(AppState.patchReviewPathKeys(
            toolName: "create_file",
            arguments: ["path": .string("first.swift")]
        ))
        let second = try #require(AppState.patchReviewPathKeys(
            toolName: "edit_file",
            arguments: ["path": .string("Second.swift")]
        ))
        let different = try #require(AppState.patchReviewPathKeys(
            toolName: "apply_patch",
            arguments: [
                "diff": .string(
                    modifyDiff(
                        path: "Second.swift",
                        oldLine: "let second = 1",
                        newLine: "let second = 2"
                    )
                    + "\ndiff --git a/Third.swift b/Third.swift\n"
                    + modifyDiff(
                        path: "Third.swift",
                        oldLine: "let third = 1",
                        newLine: "let third = 2"
                    )
                )
            ]
        ))

        #expect(!first.isDisjoint(with: same))
        #expect(first.isDisjoint(with: different))
        #expect(!second.isDisjoint(with: different))
        #expect(different.count == 2)
        #expect(AppState.patchReviewPathKeys(
            toolName: "run_command",
            arguments: ["command": .string("git status")]
        ) == nil)
    }

    @Test("审核批次收集完成前拒绝提前 Apply 或 Reject")
    func collectingBatchCannotBeResolvedEarly() throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_collecting",
            files: [
                "First.swift": "let first = 1\n",
                "Second.swift": "let second = 1\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime

        let messageID = UUID()
        runtime.collectingPatchReviewMessageIDs.insert(messageID)
        let first = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "第一份仍在收集中的补丁",
            diff: modifyDiff(
                path: "First.swift",
                oldLine: "let first = 1",
                newLine: "let first = 2"
            )
        )

        #expect(appState.isAgentPatchReviewCollecting(forMessageID: messageID))
        appState.applyAgentPatchProposal(id: first.id)
        appState.applyAgentPatchProposals(forMessageID: messageID)
        appState.rejectAgentPatchProposal(id: first.id)
        appState.rejectAgentPatchProposals(forMessageID: messageID)
        appState.applyAllPendingAgentPatchProposals()
        appState.rejectAllPendingAgentPatchProposals()
        #expect(runtime.patchProposals.first?.status == .pending)
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")

        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "第二份仍在收集中的补丁",
            diff: modifyDiff(
                path: "Second.swift",
                oldLine: "let second = 1",
                newLine: "let second = 2"
            )
        )
        runtime.collectingPatchReviewMessageIDs.remove(messageID)
        #expect(!appState.isAgentPatchReviewCollecting(forMessageID: messageID))
        appState.applyAgentPatchProposals(forMessageID: messageID)

        #expect(runtime.patchProposals.allSatisfy { $0.status == .applied })
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 2\n")
        #expect(try contents(of: "Second.swift", in: workspace) == "let second = 2\n")
    }

    @Test("同一批次中的重复真实文件目标会在入队前被拒绝")
    func duplicatePatchTargetIsRejected() throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_duplicate",
            files: ["First.swift": "let first = 1\n"]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("Alias.swift"),
            withDestinationURL: workspace.appendingPathComponent("First.swift")
        )
        let duplicateDiff = modifyDiff(
            path: "First.swift",
            oldLine: "let first = 1",
            newLine: "let first = 2"
        )
        + "\ndiff --git a/Alias.swift b/Alias.swift\n"
        + modifyDiff(
            path: "Alias.swift",
            oldLine: "let first = 1",
            newLine: "let first = 3"
        )

        var rejectedPath: String?
        do {
            _ = try appState.enqueueAgentPatchProposal(
                for: runtime,
                messageID: UUID(),
                title: "重复目标",
                diff: duplicateDiff
            )
        } catch AgentPatchError.duplicateTarget(let path) {
            rejectedPath = path
        }

        #expect(rejectedPath == "Alias.swift")
        #expect(runtime.patchProposals.isEmpty)
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
    }

    @Test("两张补丁卡指向同一真实文件时批量应用会整组拒绝")
    func duplicateTargetsAcrossProposalsAreRejectedAtomically() throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_duplicate_proposals",
            files: ["First.swift": "let first = 1\n"]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("Alias.swift"),
            withDestinationURL: workspace.appendingPathComponent("First.swift")
        )
        let messageID = UUID()
        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "真实路径补丁",
            diff: modifyDiff(
                path: "First.swift",
                oldLine: "let first = 1",
                newLine: "let first = 2"
            )
        )
        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "符号链接别名补丁",
            diff: modifyDiff(
                path: "Alias.swift",
                oldLine: "let first = 1",
                newLine: "let first = 3"
            )
        )

        appState.applyAgentPatchProposals(forMessageID: messageID)

        #expect(runtime.patchProposals.count == 2)
        #expect(runtime.patchProposals.allSatisfy { $0.status == .failed })
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
    }

    @Test("后一个文件写入失败时回滚此前已写入的文件")
    func writeFailureRollsBackEarlierFiles() throws {
        let workspace = try makeWorkspace(
            prefix: "willdeep_patch_batch_rollback",
            files: ["First.swift": "let first = 1\n"]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let lockedDirectory = workspace.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockedDirectory,
            withIntermediateDirectories: true
        )
        let secondURL = lockedDirectory.appendingPathComponent("Second.swift")
        try "let second = 1\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime
        let messageID = UUID()
        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "先写入的文件",
            diff: modifyDiff(
                path: "First.swift",
                oldLine: "let first = 1",
                newLine: "let first = 2"
            )
        )
        _ = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "应写入失败的文件",
            diff: modifyDiff(
                path: "Locked/Second.swift",
                oldLine: "let second = 1",
                newLine: "let second = 2"
            )
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: lockedDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: lockedDirectory.path
            )
        }

        appState.applyAgentPatchProposals(forMessageID: messageID)

        #expect(runtime.patchProposals.allSatisfy { $0.status == .failed })
        #expect(try contents(of: "First.swift", in: workspace) == "let first = 1\n")
        #expect(try contents(of: "Locked/Second.swift", in: workspace) == "let second = 1\n")
    }

    @Test("回滚只撤销本批写入，不覆盖回滚期间的外部修改")
    func rollbackDecisionPreservesConcurrentExternalEdit() {
        let original = Data("let value = 1\n".utf8)
        let batchWrite = Data("let value = 2\n".utf8)
        let externalWrite = Data("let value = 99\n".utf8)

        #expect(AppState.agentPatchRollbackAction(
            currentData: batchWrite,
            originalData: original,
            expectedData: batchWrite
        ) == .restoreOriginal)
        #expect(AppState.agentPatchRollbackAction(
            currentData: externalWrite,
            originalData: original,
            expectedData: batchWrite
        ) == .preserveConflict)
        #expect(AppState.agentPatchRollbackAction(
            currentData: externalWrite,
            originalData: nil,
            expectedData: batchWrite
        ) == .preserveConflict)
    }

    @Test("工具循环不在第一张补丁卡内等待而在批次边界统一等待")
    func toolLoopKeepsPatchSinkNonBlockingUntilBatchBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let loopSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AppStateAgentLoop.swift"
            ),
            encoding: .utf8
        )
        let sinkStart = try #require(loopSource.range(
            of: "patchProposalSink: { title, diff, applyImmediately in"
        ))
        let sinkEnd = try #require(loopSource.range(
            of: "editableContentProvider:",
            range: sinkStart.upperBound..<loopSource.endIndex
        ))
        let sinkBody = loopSource[sinkStart.lowerBound..<sinkEnd.lowerBound]

        #expect(sinkBody.contains("enqueueAgentPatchProposal"))
        #expect(!sinkBody.contains("awaitAgentPatchDecision"))
        #expect(loopSource.contains("_ = await awaitPendingAgentPatchProposals("))
        #expect(loopSource.contains(
            "runtime.collectingPatchReviewMessageIDs.insert(assistantID)"
        ))
    }

    @Test("工具契约要求独立文件修改进入同一审核组")
    func promptAndRegistryAdvertiseBatchReview() {
        let prompt = AgentContextBuilder.stableSystemPromptPrefix(
            toolsEnabled: true,
            promptProfile: .extended
        )
        let createFile = AgentToolRegistry.descriptor(for: "create_file")
        let editFile = AgentToolRegistry.descriptor(for: "edit_file")

        #expect(prompt.contains(
            "WillDeep collects their patch cards into one review group with Apply All / Reject All"
        ))
        #expect(createFile?.description.contains("one Apply All review group") == true)
        #expect(editFile?.description.contains("one Apply All review group") == true)
        #expect(AppState.patchReviewToolNames == ["create_file", "edit_file", "apply_patch"])
    }

    private func makeWorkspace(
        prefix: String,
        files: [String: String]
    ) throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        for (path, content) in files {
            try content.write(
                to: workspace.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }
        return workspace
    }

    private func enqueueModifyProposals(
        appState: AppState,
        runtime: AgentRuntime,
        messageID: UUID
    ) throws -> [AgentPatchProposal] {
        let first = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "更新 First.swift",
            diff: modifyDiff(
                path: "First.swift",
                oldLine: "let first = 1",
                newLine: "let first = 2"
            )
        )
        let second = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "更新 Second.swift",
            diff: modifyDiff(
                path: "Second.swift",
                oldLine: "let second = 1",
                newLine: "let second = 2"
            )
        )
        return [first, second]
    }

    private func installPendingToolReceipt(
        for proposal: AgentPatchProposal,
        externalID: String,
        runtime: AgentRuntime
    ) {
        let payload = """
        A patch card is shown inline in the chat, right below your message.

        Patch ID: \(proposal.id.uuidString)
        Patch status: pending. No files were modified; the user must click Apply.
        """
        runtime.messages.append(
            AgentMessage(
                role: .tool,
                content: payload,
                toolCallID: externalID,
                toolCallStatus: .succeeded
            )
        )
        runtime.toolCalls.append(
            AgentToolCall(
                messageID: proposal.messageID,
                externalID: externalID,
                toolName: "edit_file",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(
                    summary: "patch queued: 1 file",
                    payload: payload
                )
            )
        )
    }

    private func modifyDiff(
        path: String,
        oldLine: String,
        newLine: String
    ) -> String {
        """
        --- a/\(path)
        +++ b/\(path)
        @@ -1 +1 @@
        -\(oldLine)
        +\(newLine)
        """
    }

    private func contents(of path: String, in workspace: URL) throws -> String {
        try String(
            contentsOf: workspace.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func waitUntilPatchDecisionIsRegistered(runtime: AgentRuntime) async {
        var spins = 0
        while runtime.patchDecisionWaiters.isEmpty, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        #expect(!runtime.patchDecisionWaiters.isEmpty)
    }
}
