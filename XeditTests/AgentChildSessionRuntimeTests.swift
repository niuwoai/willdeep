import Foundation
import Testing
import WillDeepCore
@testable import WillDeep

@Suite("Independent child session boundaries")
struct AgentChildSessionRuntimeTests {
    @Test("A replayed parent tool call gets the same assignment identity")
    func stableAssignmentIdentity() {
        let parent = UUID()
        let first = AgentChildSessionIdentity.stableID(parentID: parent, toolCallID: "tool-1")
        #expect(first == AgentChildSessionIdentity.stableID(parentID: parent, toolCallID: "tool-1"))
        #expect(first != AgentChildSessionIdentity.stableID(parentID: parent, toolCallID: "tool-2"))
        #expect(first != AgentChildSessionIdentity.stableID(parentID: UUID(), toolCallID: "tool-1"))
    }

    @Test("A child's new task is assigned to the same top-level coordinator")
    func siblingCoordinatorIdentity() {
        let root = AgentSession()
        let child = AgentSession(parentSessionID: root.id)
        #expect(AgentChildSessionIdentity.coordinatorID(for: root) == root.id)
        #expect(AgentChildSessionIdentity.coordinatorID(for: child) == root.id)
        #expect(AgentChildSessionIdentity.stableID(parentID: root.id, toolCallID: "same-tool")
            != AgentChildSessionIdentity.stableID(parentID: child.id, toolCallID: "same-tool"))
    }

    @Test("Read-only children cannot execute a command or edit")
    func toolCapabilityCeiling() {
        for name in ["run_command", "create_file", "write_file", "apply_patch", "spawn_agent",
                     "call_mcp_tool", "claude_code", "change_workspace"] {
            #expect(!AgentChildSessionTool.permits(name))
        }
        for name in ["read_file", "grep_files", "list_directory", "git_status", "ask_user",
                     "load_tool_pack", "list_workspace_sessions", "start_session"] {
            #expect(AgentChildSessionTool.permits(name))
        }
        #expect(!AgentChildSessionTool.permits("plugin_claiming_read_only"))
    }

    @Test("Restart interrupts unfinished assignments without replacing terminal results")
    func restartRecovery() throws {
        let parentID = UUID()
        let assignmentID = UUID()
        let date = Date(timeIntervalSince1970: 760_000_000)
        for status: AgentChildSessionAssignment.Status in [.queued, .running, .waiting] {
            let original = AgentChildSessionAssignment(id: assignmentID, prompt: "Inspect", status: status)
            let interrupted = try #require(AgentChildSessionRecovery.interrupted(
                original, parentID: parentID, at: date
            ))
            #expect(interrupted.status == .interrupted)
            #expect(interrupted.completedAt == date)
            #expect(interrupted.resultNotificationID == AgentChildSessionIdentity.stableID(
                parentID: parentID, toolCallID: assignmentID.uuidString + ":result"
            ))
            #expect(original.status == status)
        }
        let finished = AgentChildSessionAssignment(id: assignmentID, prompt: "Inspect", status: .completed)
        #expect(AgentChildSessionRecovery.interrupted(finished, parentID: parentID, at: date) == nil)
    }

    @Test("A queued child stopped before claiming a provider slot reports cancellation")
    @MainActor
    func queuedChildStopSettlesAssignment() throws {
        let state = AppState(rootDirectory: nil, loadSessionCatalog: false)
        let parent = AgentSession()
        let child = AgentSession(parentSessionID: parent.id,
                                 childSessionAssignment: AgentChildSessionAssignment(
                                    id: UUID(), prompt: "Inspect", status: .running))
        defer { AgentSessionStore.delete(id: child.id); AgentSessionStore.delete(id: parent.id) }
        let runtime = AgentRuntime(session: child)
        state.agentSessions = [parent, child]
        state.agentRuntimes[child.id] = runtime
        runtime.isAwaitingProviderSlot = true
        let message = AgentMessage(role: .user, content: "Inspect", source: .hostInstruction)
        runtime.messages.append(message)
        state.pendingDispatchQueue = [AppState.PendingDispatch(
            runtimeID: child.id, userMessageID: message.id, text: message.content,
            images: [], textAttachments: [], attachedSkills: [], providerID: "test-provider",
            enqueuedAt: Date(), source: .hostInstruction
        )]

        state.stopAgentResponse(for: runtime)

        #expect(state.pendingDispatchQueue.isEmpty)
        #expect(!runtime.isAwaitingProviderSlot)
        #expect(runtime.session.childSessionAssignment?.status == .cancelled)
        #expect(runtime.session.childSessionAssignment?.resultNotificationID != nil)
    }

    @Test("首次委派落盘失败时不发送简报也不留下子会话")
    @MainActor
    func initialSaveFailureStopsDispatch() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let state = AppState(rootDirectory: workspace, loadSessionCatalog: false)
        let parent = AgentSession(workspaceRootPath: workspace.path)
        state.agentSessions = [parent]
        state.agentRuntimes[parent.id] = AgentRuntime(session: parent)

        do {
            _ = try state.startChildSession(
                from: try #require(state.agentRuntimes[parent.id]),
                title: "Inspect", brief: "Read the project", toolCallID: "failed-start",
                saveInitialState: { _ in false }
            )
            Issue.record("A child must not dispatch after its initial save fails")
        } catch AgentChildSessionError.unavailable {
            #expect(!state.agentSessions.contains { $0.parentSessionID == parent.id })
            #expect(!state.agentRuntimes.values.contains { $0.session.parentSessionID == parent.id })
        }
    }

    @Test("An unfinished child protects its parent from archival")
    @MainActor
    func unfinishedChildProtectsParent() {
        let state = AppState(rootDirectory: nil, loadSessionCatalog: false)
        let parent = AgentSession()
        var child = AgentSession(parentSessionID: parent.id,
                                 childSessionAssignment: AgentChildSessionAssignment(
                                    id: UUID(), prompt: "Inspect", status: .queued))
        state.agentSessions = [parent, child]
        for status: AgentChildSessionAssignment.Status in [.queued, .running, .waiting] {
            child.childSessionAssignment?.status = status
            state.agentSessions[1] = child
            #expect(state.sessionManagementProtectionReason(parent) == "active_child_session")
        }
        child.childSessionAssignment?.status = .completed
        state.agentSessions[1] = child
        #expect(state.sessionManagementProtectionReason(parent) == nil)
    }

    @Test("首次结果先结算，不能被待处理后台事件与后续消息替换")
    @MainActor
    func firstReportSettlesDespiteUnrelatedWakeup() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let (state, parent, child) = childFixture(kernel: kernel)
        defer { AgentSessionStore.delete(id: child.id); AgentSessionStore.delete(id: parent.id) }
        child.messages.append(AgentMessage(role: .assistant, content: "First task report"))
        kernel.publish(AgentKernelEvent(
            runtimeID: child.id,
            source: .worker,
            kind: .workerCompleted,
            title: "Unrelated background event",
            payload: "Pending event"
        ))
        #expect(kernel.pendingModelEventCount(for: child.id) > 0)

        state.recordChildSessionCompletionIfNeeded(for: child, wasUserStopped: false)
        #expect(child.session.childSessionAssignment?.status == .completed)
        #expect(child.session.childSessionAssignment?.resultExcerpt == "First task report")
        child.messages.append(AgentMessage(role: .assistant, content: "Later reply"))
        state.recordChildSessionCompletionIfNeeded(for: child, wasUserStopped: false)
        #expect(child.session.childSessionAssignment?.resultExcerpt == "First task report")
        #expect(kernel.events.contains {
            $0.metadata["child_session_id"] == child.id.uuidString
                && $0.payload.contains("First task report")
        })
    }

    @Test("跑道续跑次数耗尽时首次任务中断而不是完成")
    @MainActor
    func exhaustedRunwayReportsInterruption() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let (state, parent, child) = childFixture(kernel: kernel)
        defer { AgentSessionStore.delete(id: child.id); AgentSessionStore.delete(id: parent.id) }
        child.messages.append(AgentMessage(role: .assistant, content: "PAUSE: context exhausted"))
        child.contextRunwayResumeCount = AgentContextRunwayPolicy.maximumAutomaticResumes
        state.concludeContextRunwayHandoff(for: child, finishReason: nil)
        #expect(!child.pendingContextRunwayResume)

        state.recordChildSessionCompletionIfNeeded(for: child, wasUserStopped: false)
        #expect(child.session.childSessionAssignment?.status == .interrupted)
        #expect(kernel.events.contains {
            $0.metadata["child_session_id"] == child.id.uuidString
                && $0.payload.contains("status=\"interrupted\"")
        })
    }

    @Test("子会话终态未确认落盘时不向父会话发布结果")
    @MainActor
    func failedDurableSaveDoesNotPublish() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let (state, parent, child) = childFixture(kernel: kernel)
        defer { AgentSessionStore.delete(id: child.id); AgentSessionStore.delete(id: parent.id) }
        child.messages.append(AgentMessage(role: .assistant, content: "First task report"))

        state.recordChildSessionCompletionIfNeeded(
            for: child,
            wasUserStopped: false,
            saveTerminalState: { _ in false }
        )
        #expect(child.session.childSessionAssignment?.status == .completed)
        #expect(child.errorMessage == L10n.AgentPanel.sessionSaveFailed)
        #expect(!kernel.events.contains { $0.metadata["child_session_id"] == child.id.uuidString })
    }

    @Test("终态保存恢复后在同一进程补发首次结果")
    @MainActor
    func terminalSaveRetryPublishesResult() async {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let (state, parent, child) = childFixture(kernel: kernel)
        defer { AgentSessionStore.delete(id: child.id); AgentSessionStore.delete(id: parent.id) }
        child.messages.append(AgentMessage(role: .assistant, content: "Recovered report"))
        state.recordChildSessionCompletionIfNeeded(
            for: child, wasUserStopped: false, saveTerminalState: { _ in false }
        )
        #expect(!kernel.events.contains { $0.metadata["child_session_id"] == child.id.uuidString })

        let deadline = ContinuousClock.now + .seconds(5)
        while !kernel.events.contains(where: { $0.metadata["child_session_id"] == child.id.uuidString }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(kernel.events.contains {
            $0.metadata["child_session_id"] == child.id.uuidString
                && $0.payload.contains("Recovered report")
        })
        #expect(child.errorMessage == nil)
    }

    @Test("子会话结果写入父会话日志前会脱敏")
    @MainActor
    func childResultJournalRedactsCredentialLikeText() throws {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: true)
        let syntheticCredential = "sk-" + String(repeating: "a", count: 20)
        let (state, parent, child) = childFixture(kernel: kernel)
        defer {
            kernel.removeEvents(for: parent.id)
            _ = AgentKernelEventStore.flushPendingWrites()
            AgentSessionStore.delete(id: child.id)
            AgentSessionStore.delete(id: parent.id)
        }
        child.session.title = "Task \(syntheticCredential)"
        child.messages.append(AgentMessage(role: .assistant, content: "Found \(syntheticCredential)"))

        state.recordChildSessionCompletionIfNeeded(for: child, wasUserStopped: false)
        let result = try #require(kernel.events.first {
            $0.metadata["child_session_id"] == child.id.uuidString
        })
        #expect(!result.title.contains(syntheticCredential))
        #expect(!result.payload.contains(syntheticCredential))
        _ = AgentKernelEventStore.flushPendingWrites()
        let journal = try String(contentsOf: AgentKernelEventStore.fileURL(for: parent.id), encoding: .utf8)
        #expect(!journal.contains(syntheticCredential))
        #expect(journal.contains("[REDACTED:API-KEY]"))
    }

    @Test("Parent discovers the tool in the session automation pack")
    func toolCatalogRegistration() {
        #expect(AgentToolPackCatalog.toolNames(in: .sessionAutomation)
            .contains(AgentChildSessionTool.startName))
        #expect(AgentToolRegistry.all.contains { $0.name == AgentChildSessionTool.startName })
    }

    @MainActor
    private func childFixture(kernel: AgentRuntimeKernel) -> (AppState, AgentSession, AgentRuntime) {
        let state = AppState(rootDirectory: nil, runtimeKernel: kernel, loadSessionCatalog: false)
        let parent = AgentSession()
        let childSession = AgentSession(
            parentSessionID: parent.id,
            childSessionAssignment: AgentChildSessionAssignment(prompt: "Inspect", status: .running)
        )
        let parentRuntime = AgentRuntime(session: parent)
        parentRuntime.isResponding = true
        let child = AgentRuntime(session: childSession)
        state.agentSessions = [parent, childSession]
        state.agentRuntimes[parent.id] = parentRuntime
        state.agentRuntimes[child.id] = child
        return (state, parent, child)
    }
}
