//
//  AgentToolIntegrationTests.swift
//  WillDeepTests
//
//  Split from XeditTests.swift to keep the broad app test suite under the
//  repository file-size limit while keeping Agent tool regressions grouped.
//  Further split by topic — prompt snapshot guards, queued-task tools,
//  some.im browser login, tool-call grouping, command safety, and usage
//  stats now live in their own sibling files.
//

import Testing
import Foundation
@testable import WillDeep

extension WillDeepTests {
    // MARK: - Agent tools

    @Test("grep_files matches a regex across workspace files and respects include filter")
    @MainActor
    func testGrepFilesMatchesRegexWithInclude() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_grep_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "func alpha() {}\nlet beta = 1\n".write(
            to: workspace.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8
        )
        try "function gamma(){}\nconst delta = 1;\n".write(
            to: workspace.appendingPathComponent("sample.js"), atomically: true, encoding: .utf8
        )

        let context = AgentToolContext(rootDirectory: workspace)
        let result = try await AgentToolRunner.run(
            name: "grep_files",
            arguments: [
                "pattern": .string("^(func|function)\\s+\\w+"),
                "include": .string("*.swift")
            ],
            context: context
        )

        #expect(result.payload.contains("Sample.swift"))
        #expect(result.payload.contains("alpha"))
        #expect(!result.payload.contains("gamma"))
    }

    @Test("grep_files rejects invalid regex with a descriptive error")
    @MainActor
    func testGrepFilesRejectsInvalidRegex() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_grep_bad_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        await #expect(throws: AgentToolError.self) {
            try await AgentToolRunner.run(
                name: "grep_files",
                arguments: ["pattern": .string("[unterminated")],
                context: context
            )
        }
    }

    @Test("encodeChatRequest echoes assistant reasoning_content back to the provider")
    func testReasoningContentRoundTrip() throws {
        // Empty reasoning must not emit the key (some providers reject empty strings).
        let withoutReasoning = AgentMessage(role: .assistant, content: "Hi.")
        let dataWithout = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [withoutReasoning],
            tools: []
        )
        let jsonWithout = String(data: dataWithout, encoding: .utf8) ?? ""
        #expect(!jsonWithout.contains("reasoning_content"))

        // Non-empty reasoning MUST be present in the assistant message.
        // DashScope's thinking-mode 400's without it.
        let withReasoning = AgentMessage(
            role: .assistant,
            content: "The answer is 42.",
            reasoningContent: "I considered alternatives and concluded 42."
        )
        let dataWith = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [withReasoning],
            tools: []
        )
        let jsonWith = String(data: dataWith, encoding: .utf8) ?? ""
        #expect(jsonWith.contains("reasoning_content"))
        #expect(jsonWith.contains("I considered alternatives"))

        // The field must only attach to assistant messages — a user
        // role with reasoningContent set (shouldn't happen, but defend)
        // doesn't leak it.
        var sneakyUser = AgentMessage(role: .user, content: "hello")
        sneakyUser.reasoningContent = "secret"
        let dataUser = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [sneakyUser],
            tools: []
        )
        let jsonUser = String(data: dataUser, encoding: .utf8) ?? ""
        #expect(!jsonUser.contains("secret"))
    }

    // MARK: - apply_patch proposals

    @Test("apply_patch queues a right-side patch proposal without writing files")
    @MainActor
    func testApplyPatchQueuesProposalWithoutWritingFiles() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_apply_patch_tool_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let diff = """
        --- a/Sample.swift
        +++ b/Sample.swift
        @@ -1 +1 @@
        -let value = 1
        +let value = 2
        """

        var queuedProposal: AgentPatchProposal?
        let context = AgentToolContext(
            rootDirectory: workspace,
            patchProposalSink: { title, diff, _ in
                let proposal = AgentPatchProposal(
                    messageID: UUID(),
                    title: title ?? "Agent Patch",
                    diff: diff
                )
                queuedProposal = proposal
                return proposal
            }
        )

        let result = try await AgentToolRunner.run(
            name: "apply_patch",
            arguments: [
                "title": .string("Update sample"),
                "diff": .string(diff)
            ],
            context: context
        )

        #expect(queuedProposal?.title == "Update sample")
        #expect(queuedProposal?.diff == diff)
        #expect(result.summary == "patch queued: 1 file")
        #expect(result.payload.contains("No files were modified"))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 1\n")
    }

    @Test("apply_patch auto-applies through existing patch applier in Goal and workspace access modes")
    @MainActor
    func testApplyPatchAutoAppliesInGoalAndWorkspaceAccessModes() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_apply_patch_auto_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let proposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Auto update sample",
            diff: """
            --- a/Sample.swift
            +++ b/Sample.swift
            @@ -1 +1 @@
            -let value = 1
            +let value = 2
            """,
            autoApplySource: .goalMode
        )

        #expect(proposal.status == .applied)
        #expect(proposal.statusMessage == "Auto-applied by Goal mode")
        #expect(runtime.patchProposals.first?.status == .applied)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 2\n")

        let workspaceAccessProposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Workspace access update",
            diff: """
            --- a/Sample.swift
            +++ b/Sample.swift
            @@ -1 +1 @@
            -let value = 2
            +let value = 3
            """,
            autoApplySource: .workspaceAccess
        )

        #expect(workspaceAccessProposal.status == .applied)
        #expect(workspaceAccessProposal.statusMessage == "Auto-applied by workspace access approval")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 3\n")
    }

    @Test("Smart review auto-applies clean and dirty workspace files")
    @MainActor
    func testSmartReviewAutoAppliesWorkspaceFilesRegardlessOfGitStatus() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_apply_patch_clean_tracked_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        func runGit(_ arguments: [String]) {
            let result = AppState.runGitCommand(arguments: arguments, in: workspace)
            #expect(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        }

        runGit(["init"])
        runGit(["config", "user.email", "tests@example.invalid"])
        runGit(["config", "user.name", "WillDeep Tests"])

        let cleanURL = workspace.appendingPathComponent("Clean.swift")
        let dirtyURL = workspace.appendingPathComponent("Dirty.swift")
        try "let clean = 1\n".write(to: cleanURL, atomically: true, encoding: .utf8)
        try "let dirty = 1\n".write(to: dirtyURL, atomically: true, encoding: .utf8)
        runGit(["add", "Clean.swift", "Dirty.swift"])
        runGit(["commit", "-m", "initial"])

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let cleanProposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Clean tracked update",
            diff: """
            --- a/Clean.swift
            +++ b/Clean.swift
            @@ -1 +1 @@
            -let clean = 1
            +let clean = 2
            """
        )

        #expect(cleanProposal.status == .applied)
        #expect(cleanProposal.statusMessage == "Auto-applied by Smart review")
        #expect(try String(contentsOf: cleanURL, encoding: .utf8) == "let clean = 2\n")

        try "let dirty = 2\n".write(to: dirtyURL, atomically: true, encoding: .utf8)
        let dirtyProposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Dirty tracked update",
            diff: """
            --- a/Dirty.swift
            +++ b/Dirty.swift
            @@ -1 +1 @@
            -let dirty = 2
            +let dirty = 3
            """
        )

        #expect(dirtyProposal.status == .applied)
        #expect(dirtyProposal.statusMessage == "Auto-applied by Smart review")
        #expect(try String(contentsOf: dirtyURL, encoding: .utf8) == "let dirty = 3\n")
    }

    @Test("Smart writes without git while Strict keeps workspace changes pending")
    @MainActor
    func testOnlyStrictModeRequiresWorkspacePatchConfirmation() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_patch_mode_gate_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let smartCreation = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Smart creation without git",
            diff: AgentToolRunner.makeCreationDiff(
                path: "Generated.swift",
                content: "let generated = true\n"
            ),
            applyImmediately: true
        )
        #expect(smartCreation.status == .applied)
        #expect(smartCreation.statusMessage == "Auto-applied by Smart review")
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("Generated.swift").path
        ))

        func runGit(_ arguments: [String]) {
            let result = AppState.runGitCommand(arguments: arguments, in: workspace)
            #expect(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        }
        runGit(["init"])
        runGit(["config", "user.email", "tests@example.invalid"])
        runGit(["config", "user.name", "WillDeep Tests"])
        let strictURL = workspace.appendingPathComponent("Strict.swift")
        try "let strict = 1\n".write(to: strictURL, atomically: true, encoding: .utf8)
        runGit(["add", "Strict.swift"])
        runGit(["commit", "-m", "baseline"])

        runtime.approvalMode = .requestEveryTime
        let strictEdit = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Strict tracked edit",
            diff: """
            --- a/Strict.swift
            +++ b/Strict.swift
            @@ -1 +1 @@
            -let strict = 1
            +let strict = 2
            """
        )
        #expect(strictEdit.status == .pending)
        #expect(try String(contentsOf: strictURL, encoding: .utf8) == "let strict = 1\n")
    }

    @Test("pending patch proposals auto-resolve before the next message in autonomous modes")
    @MainActor
    func testPendingPatchProposalsAutoResolveBeforeNextMessageInAutonomousModes() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_pending_patch_auto_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let goalFileURL = workspace.appendingPathComponent("Goal.swift")
        let workspaceFileURL = workspace.appendingPathComponent("Workspace.swift")
        let smartFileURL = workspace.appendingPathComponent("Smart.swift")
        try "let value = 1\n".write(to: goalFileURL, atomically: true, encoding: .utf8)
        try "let value = 1\n".write(to: workspaceFileURL, atomically: true, encoding: .utf8)
        try "let value = 1\n".write(to: smartFileURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        runtime.interactionMode = .goal
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Goal pending",
                diff: """
                --- a/Goal.swift
                +++ b/Goal.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .applied)
        #expect(runtime.patchProposals.last?.statusMessage == "Auto-applied by Goal mode")
        #expect(try String(contentsOf: goalFileURL, encoding: .utf8) == "let value = 2\n")

        runtime.interactionMode = .normal
        runtime.approvalMode = .workspaceAccess
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Workspace access pending",
                diff: """
                --- a/Workspace.swift
                +++ b/Workspace.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .applied)
        #expect(runtime.patchProposals.last?.statusMessage == "Auto-applied by workspace access approval")
        #expect(try String(contentsOf: workspaceFileURL, encoding: .utf8) == "let value = 2\n")

        runtime.approvalMode = .smart
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Smart pending",
                diff: """
                --- a/Smart.swift
                +++ b/Smart.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .applied)
        #expect(runtime.patchProposals.last?.statusMessage == "Auto-applied by Smart review")
        #expect(try String(contentsOf: smartFileURL, encoding: .utf8) == "let value = 2\n")
    }

    @Test("manual patch Apply resumes the tool and rewrites stale pending feedback")
    @MainActor
    func testManualPatchApplyResumesToolWithAppliedFeedback() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_patch_decision_sync_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Pending.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime
        let messageID = UUID()
        let proposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: messageID,
            title: "Pending update",
            diff: """
            --- a/Pending.swift
            +++ b/Pending.swift
            @@ -1 +1 @@
            -let value = 1
            +let value = 2
            """
        )
        #expect(proposal.status == .pending)

        let externalID = "call_patch_decision_sync"
        let pendingPayload = """
        A patch card is shown inline in the chat, right below your message.

        Patch ID: \(proposal.id.uuidString)
        Title: Pending update
        Patch status: pending. No files were modified; the user must click Apply.
        Files:
        - Pending.swift
        """
        runtime.messages.append(
            AgentMessage(
                role: .tool,
                content: pendingPayload,
                toolCallID: externalID,
                toolCallStatus: .succeeded
            )
        )
        runtime.toolCalls.append(
            AgentToolCall(
                messageID: messageID,
                externalID: externalID,
                toolName: "apply_patch",
                arguments: [:],
                risk: .read,
                status: .succeeded,
                result: AgentToolResult(summary: "patch queued: 1 file", payload: pendingPayload)
            )
        )

        let waiter = Task { @MainActor in
            await appState.awaitAgentPatchDecision(proposal, runtime: runtime)
        }
        for _ in 0..<20 where runtime.patchDecisionWaiters[proposal.id] == nil {
            await Task.yield()
        }
        #expect(runtime.patchDecisionWaiters[proposal.id] != nil)

        appState.applyAgentPatchProposal(id: proposal.id)
        let resolved = await waiter.value

        #expect(resolved.status == .applied)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 2\n")
        let toolMessage = try #require(runtime.messages.last(where: { $0.toolCallID == externalID }))
        #expect(toolMessage.content.contains("Patch status: applied"))
        #expect(toolMessage.content.contains("do not ask for approval again"))
        #expect(!toolMessage.content.contains("Patch status: pending"))
        let toolCall = try #require(runtime.toolCalls.last(where: { $0.externalID == externalID }))
        #expect(toolCall.result?.summary == "patch applied: 1 file")
        #expect(toolCall.result?.payload.contains("No further approval is required") == true)
    }

    @Test("manual patch approval reaches the provider as an applied tool result")
    @MainActor
    func testManualPatchApprovalReturnsAppliedToolResult() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_patch_tool_wait_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Pending.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime
        let messageID = UUID()
        let toolTask = Task { @MainActor in
            try await AgentToolRunner.run(
                name: "apply_patch",
                arguments: [
                    "title": .string("Pending update"),
                    "diff": .string("""
                    --- a/Pending.swift
                    +++ b/Pending.swift
                    @@ -1 +1 @@
                    -let value = 1
                    +let value = 2
                    """)
                ],
                context: AgentToolContext(
                    rootDirectory: workspace,
                    patchProposalSink: { title, diff, _ in
                        let proposal = try appState.enqueueAgentPatchProposal(
                            for: runtime,
                            messageID: messageID,
                            title: title,
                            diff: diff
                        )
                        return await appState.awaitAgentPatchDecision(proposal, runtime: runtime)
                    }
                )
            )
        }

        for _ in 0..<100 where runtime.patchProposals.isEmpty {
            await Task.yield()
        }
        let proposal = try #require(runtime.patchProposals.first)
        for _ in 0..<20 where runtime.patchDecisionWaiters[proposal.id] == nil {
            await Task.yield()
        }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 1\n")

        appState.applyAgentPatchProposal(id: proposal.id)
        let result = try await toolTask.value

        #expect(result.summary == "patch applied: 1 file")
        #expect(result.payload.contains("Patch status: applied"))
        #expect(result.payload.contains("No further approval is required"))
        #expect(!result.payload.contains("Patch status: pending"))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 2\n")
    }

    @Test("apply_patch is advertised in extended prompt and tool registry")
    func testApplyPatchPromptAndRegistrySurface() {
        let descriptor = AgentToolRegistry.descriptor(for: "apply_patch")
        #expect(descriptor?.risk == .read)
        #expect(descriptor?.description.contains("LEGACY fallback") == true)
        #expect(descriptor?.description.contains("PREFER `edit_file`") == true)
        #expect(descriptor?.description.contains("patch card INLINE IN THE CHAT") == true)

        let prompt = AgentContextBuilder.stableSystemPromptPrefix(
            toolsEnabled: true,
            promptProfile: .extended
        )
        #expect(prompt.contains("Extended operating model"))
        #expect(prompt.contains("Do NOT hand-craft unified diffs with apply_patch unless edit_file genuinely cannot express the change"))
        #expect(prompt.contains("Never tell the user to look in a \"right-side review panel\""))
    }

    // MARK: - Dependency directory skipping

    @Test("quick open skips dependency directories")
    func testQuickOpenSkipsDependencyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_quick_open_skip_\(UUID().uuidString)", isDirectory: true)
        let nodeModules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("App.swift")
        let dependency = nodeModules.appendingPathComponent("dep.swift")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "dependency".write(to: dependency, atomically: true, encoding: .utf8)

        let urls = AppState.quickOpenFileURLs(in: tempDir)

        #expect(urls.map(\.lastPathComponent).contains("App.swift"))
        #expect(!urls.map(\.lastPathComponent).contains("dep.swift"))
    }

    @Test("folder text operations skip dependency directories")
    func testTextFileURLsSkipDependencyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_text_file_skip_\(UUID().uuidString)", isDirectory: true)
        let nodeModules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("Source.swift")
        let dependency = nodeModules.appendingPathComponent("Dependency.swift")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "dependency".write(to: dependency, atomically: true, encoding: .utf8)

        let paths = AppState.textFileURLs(in: tempDir).map(\.lastPathComponent)

        #expect(paths.contains("Source.swift"))
        #expect(!paths.contains("Dependency.swift"))
    }

    @Test("agent list_directory skips dependency directories")
    func testAgentListDirectorySkipsDependencyDirectories() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_agent_list_skip_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "source".write(to: workspace.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let result = try await AgentToolRunner.run(
            name: "list_directory",
            arguments: ["path": .string(".")],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.payload.contains("App.swift"))
        #expect(!result.payload.contains("node_modules"))
    }
}
