//
//  XeditTests.swift
//  WillDeepTests
//
//  Created by rocky on 2026/5/27.
//

import Testing
import Foundation
import CoreGraphics
import Combine
@testable import WillDeep

@Suite(.serialized)
struct WillDeepTests {
    /// Wipes the shared `UserDefaults` keys that AppState persists into so
    /// each test starts from a clean slate. swift-testing builds a fresh
    /// instance of this struct per test, so `init()` doubles as the
    /// per-test `setUp`.
    init() {
        let keys = [
            "com.willdeep.recentFiles.v1",
            "com.willdeep.recentFolders.v1",
            "com.willdeep.session.v1",
            "com.willdeep.terminalShortcuts.v1"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // Editor core behavior tests live in EditorCoreBehaviorTests.swift.

    @Test("agent session sidebar auto-hides only below responsive width")
    func testAgentSessionSidebarAutoHideThreshold() {
        let minimumSidePanelWidth: CGFloat = 240

        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 799,
            userPrefersVisible: true,
            activeSidePanel: nil,
            activeSidePanelWidth: minimumSidePanelWidth
        ) == true)
        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 800,
            userPrefersVisible: true,
            activeSidePanel: nil,
            activeSidePanelWidth: minimumSidePanelWidth
        ) == false)
        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 600,
            userPrefersVisible: false,
            activeSidePanel: nil,
            activeSidePanelWidth: minimumSidePanelWidth
        ) == false)
        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 1_039,
            userPrefersVisible: true,
            activeSidePanel: .backgroundTasks,
            activeSidePanelWidth: minimumSidePanelWidth
        ) == true)
        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 1_040,
            userPrefersVisible: true,
            activeSidePanel: .backgroundTasks,
            activeSidePanelWidth: minimumSidePanelWidth
        ) == false)
        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 1_399,
            userPrefersVisible: true,
            activeSidePanel: .terminal,
            activeSidePanelWidth: 600
        ) == true)
        #expect(AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
            totalWidth: 1_400,
            userPrefersVisible: true,
            activeSidePanel: .terminal,
            activeSidePanelWidth: 600
        ) == false)
    }

    @Test("side panel diff refuses oversized text instead of rendering a sample")
    func testSidePanelDiffRefusesOversizedText() {
        let prefix = "diff --git a/large.txt b/large.txt\n"
        let oversizedDiff = prefix + String(repeating: "+0123456789abcdef\n", count: 8_000)

        let reason = AgentSidePanelDiffLimiter.unavailableReason(for: oversizedDiff)

        #expect(reason != nil)
        #expect(reason?.contains(prefix) == false)
        #expect(reason?.contains(String(AgentSidePanelDiffLimiter.maximumDisplayUTF8Bytes)) == true)
        #expect(reason?.contains(String(AgentSidePanelDiffLimiter.maximumDisplayLines)) == true)
        #expect(reason?.contains("git diff --no-ext-diff HEAD -- <path>") == true)
    }

    @MainActor
    @Test("agent thinking indicator only shows while waiting for model output")
    func testAgentThinkingIndicatorState() {
        let appState = AppState()
        // `isAgentResponding` / `agentMessages` / `isCompressingAgentContext`
        // are delegated to the active runtime; without one every set is a
        // no-op and the indicator stays false. Production builds a runtime
        // the first time the user enters Agent mode — mirror that here.
        appState.startNewAgentSession()

        appState.isAgentResponding = true
        appState.agentMessages = [AgentMessage(role: .user, content: "Review this")]
        #expect(appState.shouldShowAgentThinkingIndicator == true)

        appState.agentMessages.append(AgentMessage(role: .assistant, content: "Done"))
        #expect(appState.shouldShowAgentThinkingIndicator == false)

        let assistant = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(externalID: "tool-1", toolName: "git_status", argumentsJSON: "{}")]
        )
        appState.agentMessages = [assistant]
        #expect(appState.shouldShowAgentThinkingIndicator == false)

        appState.agentMessages = [AgentMessage(role: .tool, content: "ok", toolCallID: "tool-1")]
        #expect(appState.shouldShowAgentThinkingIndicator == true)

        appState.isCompressingAgentContext = true
        #expect(appState.shouldShowAgentThinkingIndicator == false)
    }

    @MainActor
    @Test("agent activity stays textual and hides for user decisions")
    func testAgentActivityTextIndicatorState() {
        let appState = AppState()
        appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        appState.isAgentResponding = true
        appState.agentMessages = [AgentMessage(role: .assistant, content: "Streaming response")]

        // The text indicator remains after visible output starts instead of
        // being replaced by the former centered sparkle.
        #expect(appState.shouldShowAgentThinkingIndicator == false)
        #expect(appState.shouldShowAgentActivityTextIndicator == true)

        for status in [
            AgentToolCallStatus.pendingApproval,
            .awaitingConfirm,
            .awaitingUserAnswer
        ] {
            appState.agentToolCalls = [
                AgentToolCall(
                    messageID: UUID(),
                    externalID: UUID().uuidString,
                    toolName: "ask_user",
                    arguments: [:],
                    risk: .userInput,
                    status: status
                )
            ]
            #expect(appState.isAgentWaitingForUserDecision == true)
            #expect(appState.shouldShowAgentActivityTextIndicator == false)
        }

        appState.agentToolCalls = []
        #expect(appState.isAgentWaitingForUserDecision == false)
        appState.isCompressingAgentContext = true
        #expect(appState.shouldShowAgentActivityTextIndicator == false)
    }

    @MainActor
    @Test("goal running status bar only shows during an active goal turn")
    func testGoalRunningStatusBarVisibility() {
        let appState = AppState()
        appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )

        appState.agentInteractionMode = .goal
        appState.setAgentGoal(statement: "Ship the thing", items: ["Build", "Verify"])
        #expect(appState.shouldShowGoalRunningStatusBar == false)
        #expect(appState.shouldShowComposerGoalCard == true)

        appState.isAgentResponding = true
        #expect(appState.shouldShowGoalRunningStatusBar == true)
        #expect(appState.shouldShowComposerGoalCard == true)

        appState.agentInteractionMode = .normal
        #expect(appState.shouldShowGoalRunningStatusBar == false)
        #expect(appState.shouldShowComposerGoalCard == false)

        appState.agentInteractionMode = .goal
        appState.setAgentGoal(statement: "", items: [])
        #expect(appState.shouldShowGoalRunningStatusBar == false)
        #expect(appState.shouldShowComposerGoalCard == false)
    }

    @MainActor
    @Test("editing goal while agent is responding queues updated goal follow-up")
    func testEditingGoalWhileRespondingQueuesGoalUpdate() {
        let appState = AppState()
        appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        appState.agentInteractionMode = .goal
        appState.setAgentGoal(statement: "Old target", items: ["First"])

        appState.isAgentResponding = true
        appState.setAgentGoal(statement: "New target", items: ["First", "Second"])

        #expect(appState.agentCurrentGoal?.statement == "New target")
        #expect(appState.agentQueuedMessages.count == 1)
        #expect(appState.agentQueuedMessages.first?.text.contains("Updated goal:") == true)
        #expect(appState.agentQueuedMessages.first?.text.contains("New target") == true)
        #expect(appState.agentQueuedMessages.first?.text.contains("Second") == true)
    }

    @MainActor
    @Test("old goal-check is ignored after a mid-turn goal edit")
    func testOldGoalCheckIgnoredAfterGoalEdit() {
        let appState = AppState()
        appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        appState.agentInteractionMode = .goal
        appState.setAgentGoal(statement: "Old target", items: ["Old first"])
        appState.agentMessages.append(
            AgentMessage(
                role: .assistant,
                content: """
                Goal self-check: complete.

                ```goal-check
                1: done
                ```
                """
            )
        )

        appState.isAgentResponding = true
        appState.setAgentGoal(statement: "New target", items: ["New first"])
        appState.captureAgentGoalEvaluationFromLatestMessage()

        #expect(appState.agentCurrentGoal?.statement == "New target")
        #expect(appState.agentCurrentGoal?.checklist.first?.done == false)
    }

    @MainActor
    @Test("composer workspace pick migrates an empty active session in place")
    func testComposerWorkspacePickMigratesEmptyActiveSession() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_pick_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let initialCount = appState.agentSessions.count

        let rebound = appState.moveActiveAgentSessionToWorkspace(at: workspace.path)

        #expect(rebound.id == session.id)
        #expect(appState.agentSessions.count == initialCount)
        #expect(appState.activeRuntime?.workspaceRootPath == workspace.standardizedFileURL.path)
        #expect(appState.agentSessions.first(where: { $0.id == session.id })?.workspaceRootPath == workspace.standardizedFileURL.path)
    }

    @MainActor
    @Test("composer workspace pick migrates a no-workspace conversation in place")
    func testComposerWorkspacePickMigratesNoWorkspaceConversation() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_pick_history_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        appState.agentMessages = [
            AgentMessage(role: .user, content: "先聊一个没有工作区的问题"),
            AgentMessage(role: .assistant, content: "可以，等你选工作区后我继续。")
        ]
        appState.persistActiveAgentSession()
        let initialCount = appState.agentSessions.count

        let rebound = appState.moveActiveAgentSessionToWorkspace(at: workspace.path)

        #expect(rebound.id == session.id)
        #expect(appState.agentSessions.count == initialCount)
        #expect(appState.activeRuntime?.messages.count == 2)
        #expect(appState.activeRuntime?.workspaceRootPath == workspace.standardizedFileURL.path)
        #expect(appState.agentSessions.first(where: { $0.id == session.id })?.workspaceRootPath == workspace.standardizedFileURL.path)
    }

    @MainActor
    @Test("selecting the active workspace is a no-op")
    func testComposerWorkspacePickCurrentWorkspaceIsNoOp() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_same_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        defer { AgentSessionStore.delete(id: session.id) }
        appState.agentMessages = [AgentMessage(role: .user, content: "keep this conversation")]
        let initialCount = appState.agentSessions.count

        let selected = appState.moveActiveAgentSessionToWorkspace(at: workspace.path)

        #expect(selected.id == session.id)
        #expect(appState.activeAgentSessionID == session.id)
        #expect(appState.agentSessions.count == initialCount)
        #expect(appState.agentMessages.count == 1)
    }

    @MainActor
    @Test("expert activation gates specialist tools and side panels")
    func testExpertActivationGatesSpecialistToolsAndSidePanels() {
        let defaultTools = AgentToolRegistry.tools(activeExperts: [])
        let shortDramaTools = AgentToolRegistry.tools(activeExperts: [.shortDrama])
        let browserTools = AgentToolRegistry.tools(activeExperts: [.browserOps])

        #expect(defaultTools.contains { $0.name == "run_command" })
        #expect(!defaultTools.contains { $0.name.hasPrefix("short_drama_") })
        #expect(!defaultTools.contains { $0.name.hasPrefix("embedded_browser_") })
        #expect(!defaultTools.contains { $0.name.hasPrefix("chrome_") })
        #expect(shortDramaTools.contains { $0.name == "short_drama_create_project" })
        #expect(browserTools.contains { $0.name == "embedded_browser_capture_screenshot" })
        #expect(browserTools.contains { $0.name == "embedded_browser_console" })
        #expect(browserTools.contains { $0.name == "embedded_browser_network" })
        #expect(browserTools.contains { $0.name == "embedded_browser_snapshot" })
        #expect(browserTools.contains { $0.name == "embedded_browser_requests" })
        #expect(browserTools.contains { $0.name == "embedded_browser_export_har" })
        #expect(browserTools.contains { $0.name == "embedded_browser_storage" })
        #expect(browserTools.contains { $0.name == "embedded_browser_performance" })
        #expect(browserTools.contains { $0.name == "embedded_browser_failed_resources" })
        #expect(browserTools.contains { $0.name == "chrome_capture_tab" })
        #expect(!AgentSidePanelKind.shortDrama.isAvailable(activeExperts: []))
        #expect(AgentSidePanelKind.shortDrama.isAvailable(activeExperts: [.shortDrama]))
        #expect(!AgentSidePanelKind.embeddedBrowser.isAvailable(activeExperts: []))
        #expect(AgentSidePanelKind.embeddedBrowser.isAvailable(activeExperts: [.browserOps]))

        let appState = AppState()
        appState.startNewAgentSession()
        #expect(appState.agentActiveExperts.isEmpty)
        appState.activateAgentExpert(.shortDrama)
        #expect(appState.agentActiveExperts == [.shortDrama])
        appState.activateAgentExpert(.shortDrama)
        #expect(appState.agentActiveExperts == [.shortDrama])
        #expect(appState.activeRuntime?.session.activeExperts == [.shortDrama])
        #expect(appState.canDeactivateAgentExperts())
        #expect(appState.deactivateAgentExpert(.shortDrama))
        #expect(appState.agentActiveExperts.isEmpty)

        appState.activateAgentExpert(.browserOps)
        appState.activeRuntime?.messages.append(AgentMessage(role: .user, content: "Use the browser expert."))
        #expect(!appState.canDeactivateAgentExperts())
        #expect(!appState.deactivateAgentExpert(.browserOps))
        #expect(appState.agentActiveExperts == [.browserOps])
    }

    @Test("terminal shortcut recorder coalesces per-character password input into one protected event")
    func testTerminalShortcutRecorderCoalescesPasswordKeystrokes() throws {
        let service = AgentCredentialStore._setTestKeychainServiceOverride("terminal-shortcuts-\(UUID().uuidString)")
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcuts-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
            UserDefaults.standard.removeObject(forKey: "com.willdeep.terminalShortcuts.v1")
        }
        #expect(service.hasPrefix("terminal-shortcuts-"))

        let recorder = TerminalShortcutRecorder(startedAt: Date(timeIntervalSince1970: 0))
        // Visible command line.
        recorder.record(data: Array("ssh user@example.com\n".utf8), echoEnabled: true, now: Date(timeIntervalSince1970: 1))
        // Password typed one character at a time with echo disabled, the way a
        // real prompt delivers keystrokes. Every character used to become its own
        // protected event (the "19 protected inputs" bug).
        let password = "hunter2secret"
        for (offset, byte) in Array(password.utf8).enumerated() {
            recorder.record(data: [byte], echoEnabled: false, now: Date(timeIntervalSince1970: 2 + Double(offset) * 0.1))
        }
        // Enter is still delivered with echo off; it terminates the password line.
        recorder.record(data: [13], echoEnabled: false, now: Date(timeIntervalSince1970: 5))

        let shortcut = try #require(recorder.finish(title: "SSH login", finishedAt: Date(timeIntervalSince1970: 6)))

        let protectedEvents = shortcut.events.filter(\.requiresEchoOff)
        #expect(protectedEvents.count == 1)
        #expect(shortcut.hasProtectedInput)
        let protectedEvent = try #require(protectedEvents.first)
        #expect(protectedEvent.resolvedBytes() == Array(password.utf8))
        // The password's leading delay is measured to when typing STARTED (t=2s),
        // not diluted across the per-character keystrokes.
        #expect(protectedEvent.delayMilliseconds == 1_000)
        // The echo-off Enter is preserved as a visible submit event so replay
        // still submits the line, but it does not count as protected input.
        let visibleText = String(decoding: shortcut.events.flatMap(\.bytes), as: UTF8.self)
        #expect(!visibleText.contains(password))
        #expect(visibleText.contains("\r") || visibleText.contains("\n"))
    }

    @Test("terminal shortcut recorder protects echo-off input for echo-off replay only")
    func testTerminalShortcutRecorderProtectsEchoOffInput() throws {
        let service = AgentCredentialStore._setTestKeychainServiceOverride("terminal-shortcuts-\(UUID().uuidString)")
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcuts-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
            UserDefaults.standard.removeObject(forKey: "com.willdeep.terminalShortcuts.v1")
        }
        #expect(service.hasPrefix("terminal-shortcuts-"))

        let recorder = TerminalShortcutRecorder(startedAt: Date(timeIntervalSince1970: 0))
        recorder.record(
            data: Array("ssh user@example.com\n".utf8),
            echoEnabled: true,
            now: Date(timeIntervalSince1970: 1)
        )
        recorder.record(
            data: Array("super-secret-password".utf8),
            echoEnabled: false,
            now: Date(timeIntervalSince1970: 2)
        )
        recorder.record(
            data: [13],
            echoEnabled: true,
            now: Date(timeIntervalSince1970: 4)
        )

        let shortcut = try #require(
            recorder.finish(
                title: "SSH login",
                finishedAt: Date(timeIntervalSince1970: 5)
            )
        )
        let visibleEventText = String(decoding: shortcut.events.flatMap(\.bytes), as: UTF8.self)
        let protectedEvent = try #require(shortcut.events.first { $0.requiresEchoOff })

        #expect(shortcut.hasProtectedInput)
        #expect(shortcut.events.count == 3)
        #expect(!visibleEventText.contains("super-secret-password"))
        #expect(protectedEvent.resolvedBytes() == Array("super-secret-password".utf8))
        #expect(protectedEvent.delayMilliseconds == 1_000)

        TerminalShortcutStore.save([shortcut])
        let persistedData = try Data(contentsOf: TerminalShortcutStore.fileURL)
        let persistedJSON = String(decoding: persistedData, as: UTF8.self)
        #expect(!persistedJSON.contains("super-secret-password"))

        let loaded = try #require(TerminalShortcutStore.load().first)
        let loadedProtectedEvent = try #require(loaded.events.first { $0.requiresEchoOff })
        #expect(loadedProtectedEvent.bytes.isEmpty)
        #expect(loadedProtectedEvent.protectedBytesReference?.isEmpty == false)
        #expect(loadedProtectedEvent.resolvedBytes() == Array("super-secret-password".utf8))
    }

    @Test("terminal shortcut rename persists to disk")
    func testTerminalShortcutRenamePersistsToDisk() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-rename-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 0,
                    bytes: Array("pwd\n".utf8)
                )
            ],
            hasProtectedInput: false
        )

        var renamed = shortcut
        renamed.title = "After"
        renamed.updatedAt = Date(timeIntervalSince1970: 2)

        TerminalShortcutStore.save([renamed])

        let loaded = try #require(TerminalShortcutStore.load().first)
        #expect(loaded.title == "After")
        #expect(FileManager.default.fileExists(atPath: TerminalShortcutStore.fileURL.path))
    }

    @Test("terminal shortcut file is editable JSON and reloads edited content")
    func testTerminalShortcutEditableFileReloadsEditedContent() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-edit-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 0,
                    bytes: Array("pwd\n".utf8)
                )
            ],
            hasProtectedInput: false
        )

        TerminalShortcutStore.save([shortcut])
        let json = try String(contentsOf: TerminalShortcutStore.fileURL, encoding: .utf8)
        #expect(json.contains("\n"))
        #expect(json.contains(#""text""#))
        #expect(!json.contains(#""bytes""#))
        #expect(json.contains(#"pwd\\n"#))
        #expect(TerminalShortcutStore.lineNumber(for: shortcut.id, in: json) != nil)

        let editedJSON = json.replacingOccurrences(of: "\"Before\"", with: "\"Edited\"")
        try editedJSON.write(to: TerminalShortcutStore.fileURL, atomically: true, encoding: .utf8)

        let loaded = try #require(TerminalShortcutStore.loadEditableShortcuts().first)
        #expect(loaded.title == "Edited")
        #expect(TerminalShortcutStore.isStoreFile(TerminalShortcutStore.fileURL))
    }

    @MainActor
    @Test("terminal shortcut per-item JSON save merges into the live list")
    func testTerminalShortcutPerItemJSONSaveMergesIntoLiveList() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-single-edit-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let editedID = UUID()
        let untouchedID = UUID()
        let editedSource = TerminalShortcut(
            id: editedID,
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 2),
            durationMilliseconds: 1_000,
            events: [TerminalShortcutEvent(delayMilliseconds: 0, bytes: Array("pwd\n".utf8))],
            hasProtectedInput: false
        )
        let untouched = TerminalShortcut(
            id: untouchedID,
            title: "Untouched",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [TerminalShortcutEvent(delayMilliseconds: 0, bytes: Array("ls\n".utf8))],
            hasProtectedInput: false
        )
        TerminalShortcutStore.save([editedSource, untouched])

        let controller = AgentInteractiveTerminalController()
        let editURL = try #require(controller.prepareShortcutFileForEditing(id: editedID))
        let json = try String(contentsOf: editURL, encoding: .utf8)
        #expect(json.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        #expect(json.contains("Before"))
        #expect(!json.contains("Untouched"))
        #expect(TerminalShortcutStore.editableShortcutID(for: editURL) == editedID)

        let editedJSON = json.replacingOccurrences(of: "\"Before\"", with: "\"After\"")
        try editedJSON.write(to: editURL, atomically: true, encoding: .utf8)
        #expect(controller.reloadShortcutFromEditFile(id: editedID, url: editURL))

        let persisted = TerminalShortcutStore.load()
        #expect(persisted.count == 2)
        #expect(persisted.first(where: { $0.id == editedID })?.title == "After")
        #expect(persisted.first(where: { $0.id == untouchedID })?.title == "Untouched")

        let reopenedURL = try #require(controller.prepareShortcutFileForEditing(id: editedID))
        let reopenedJSON = try String(contentsOf: reopenedURL, encoding: .utf8)
        #expect(reopenedJSON.contains("After"))
        #expect(!reopenedJSON.contains("Before"))
    }

    @MainActor
    @Test("terminal shortcut clone creates an independent persisted copy")
    func testTerminalShortcutCloneCreatesIndependentPersistedCopy() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-clone-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let sourceEvent = TerminalShortcutEvent(
            delayMilliseconds: 250,
            bytes: Array("yarn test\n".utf8)
        )
        let source = TerminalShortcut(
            id: UUID(),
            title: "Build",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [sourceEvent],
            hasProtectedInput: false
        )
        TerminalShortcutStore.save([source])

        let controller = AgentInteractiveTerminalController()
        let clone = try #require(
            controller.cloneShortcut(
                id: source.id,
                title: "Build-副本",
                now: Date(timeIntervalSince1970: 2)
            )
        )

        #expect(clone.id != source.id)
        #expect(clone.title == "Build-副本")
        #expect(clone.events.first?.id != sourceEvent.id)
        #expect(clone.events.first?.bytes == sourceEvent.bytes)
        let persisted = TerminalShortcutStore.load()
        #expect(persisted.count == 2)
        #expect(persisted.contains(where: { $0.id == source.id }))
        #expect(persisted.contains(where: { $0.id == clone.id }))
    }

    @Test("terminal shortcut editable JSON text decodes escapes and legacy bytes")
    func testTerminalShortcutEditableTextDecodesEscapesAndLegacyBytes() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-text-codec-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let shortcutID = UUID()
        let textEventID = UUID()
        let legacyEventID = UUID()
        let json = """
        [
          {
            "id": "\(shortcutID.uuidString)",
            "title": "Escaped",
            "createdAt": "1970-01-01T00:00:00Z",
            "updatedAt": "1970-01-01T00:00:01Z",
            "durationMilliseconds": 1000,
            "hasProtectedInput": false,
            "events": [
              {
                "id": "\(textEventID.uuidString)",
                "delayMilliseconds": 0,
                "requiresEchoOff": false,
                "text": "ssh 用户@example.com\\\\n\\\\b\\\\e\\\\x03"
              },
              {
                "id": "\(legacyEventID.uuidString)",
                "delayMilliseconds": 0,
                "requiresEchoOff": false,
                "bytes": [112, 119, 100, 10]
              }
            ]
          }
        ]
        """
        try FileManager.default.createDirectory(at: shortcutsDirectory, withIntermediateDirectories: true)
        try json.write(to: TerminalShortcutStore.fileURL, atomically: true, encoding: .utf8)

        let loaded = try #require(TerminalShortcutStore.loadEditableShortcuts().first)
        #expect(loaded.events.count == 2)
        #expect(loaded.events[0].bytes == Array("ssh 用户@example.com\n".utf8) + [127, 27, 3])
        #expect(loaded.events[1].bytes == Array("pwd\n".utf8))
    }

    @Test("terminal shortcut rename does not touch persisted protected Keychain rows")
    func testTerminalShortcutRenameSkipsPersistedProtectedKeychainRows() throws {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("terminal-shortcut-rename-protected-\(UUID().uuidString)")
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-rename-protected-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let account = "terminal-shortcut/existing/event"
        AgentCredentialStore.save(Data(Array("secret-password".utf8)).base64EncodedString(), account: account)
        AgentCredentialStore._resetTestAccessCounts()

        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Renamed",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 0,
                    bytes: [],
                    requiresEchoOff: true,
                    protectedBytesReference: account
                )
            ],
            hasProtectedInput: true
        )

        TerminalShortcutStore.save([shortcut])

        #expect(AgentCredentialStore._testLoadCount(account: account) == 0)
        #expect(AgentCredentialStore._testSaveCount(account: account) == 0)
        let persistedJSON = try String(contentsOf: TerminalShortcutStore.fileURL, encoding: .utf8)
        let reloadedAccount = try #require(TerminalShortcutStore.load().first?.events.first?.protectedBytesReference)
        #expect(reloadedAccount == account)
        #expect(!persistedJSON.contains("secret-password"))
    }

    @Test("terminal shortcut protected replay migrates old Keychain rows into local vault")
    func testTerminalShortcutProtectedReplayMigratesOldKeychainRowsIntoLocalVault() {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("terminal-shortcut-replay-cache-\(UUID().uuidString)")
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-replay-cache-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let account = "terminal-shortcut/replay/event"
        let secretBytes = Array("secret-password".utf8)
        AgentCredentialStore.save(Data(secretBytes).base64EncodedString(), account: account)
        AgentCredentialStore._resetTestAccessCounts()

        var cache: [String: [UInt8]] = [:]
        let first = TerminalShortcutEvent(
            delayMilliseconds: 0,
            bytes: [],
            requiresEchoOff: true,
            protectedBytesReference: account
        )
        let second = TerminalShortcutEvent(
            delayMilliseconds: 1,
            bytes: [],
            requiresEchoOff: true,
            protectedBytesReference: account
        )

        #expect(first.resolvedBytes(cache: &cache) == secretBytes)
        #expect(second.resolvedBytes(cache: &cache) == secretBytes)
        #expect(AgentCredentialStore._testLoadCount(account: account) == 1)

        AgentCredentialStore._resetTestAccessCounts()
        var secondPlaybackCache: [String: [UInt8]] = [:]
        #expect(first.resolvedBytes(cache: &secondPlaybackCache) == secretBytes)
        #expect(AgentCredentialStore._testLoadCount(account: account) == 0)
    }

    @Test("terminal shortcut exposes recorded and replay durations")
    func testTerminalShortcutExposesRecordedAndReplayDurations() {
        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Timed replay",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 5),
            durationMilliseconds: 5_000,
            events: [
                TerminalShortcutEvent(delayMilliseconds: 1_000, bytes: Array("pwd\n".utf8)),
                TerminalShortcutEvent(delayMilliseconds: 2_500, bytes: Array("ls\n".utf8)),
                TerminalShortcutEvent(delayMilliseconds: 0, bytes: [13])
            ],
            hasProtectedInput: false
        )
        let startedAt = Date(timeIntervalSince1970: 10)
        let state = TerminalShortcutPlaybackState(
            shortcutID: shortcut.id,
            title: shortcut.title,
            currentEventIndex: 2,
            totalEvents: shortcut.eventCount,
            startedAt: startedAt,
            estimatedFinishedAt: startedAt.addingTimeInterval(Double(shortcut.playbackDurationMilliseconds) / 1000),
            totalDelayMilliseconds: shortcut.playbackDurationMilliseconds,
            status: .running
        )

        #expect(shortcut.durationMilliseconds == 5_000)
        #expect(shortcut.playbackDurationMilliseconds == 3_500)
        #expect(state.elapsedMilliseconds(now: startedAt.addingTimeInterval(1.25)) == 1_250)
        #expect(state.remainingMilliseconds(now: startedAt.addingTimeInterval(1.25)) == 2_250)
        #expect(state.isRunning)
    }

    @MainActor
    @Test("terminal shortcut can be created from dictated visible steps")
    func testTerminalShortcutCanBeCreatedFromDictatedVisibleSteps() async throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-create-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let controller = AgentInteractiveTerminalController()
        let context = AgentToolContext(
            rootDirectory: nil,
            sandboxMode: .workspaceWrite,
            terminalController: controller
        )
        let eventsJSON = """
        [
          {"command":"cd web"},
          {"delay_ms":1200,"command":"yarn test"},
          {"text":"echo done\\n"},
          {"control":"escape"}
        ]
        """
        let result = try await AgentTerminalTools.createShortcut(
            arguments: [
                "title": .string("口述测试流程"),
                "events_json": .string(eventsJSON)
            ],
            context: context
        )

        let shortcut = try #require(controller.shortcuts.first)
        #expect(result.summary == "terminal shortcut created: 口述测试流程")
        #expect(shortcut.title == "口述测试流程")
        #expect(shortcut.events.count == 4)
        #expect(shortcut.durationMilliseconds == 1_200)
        #expect(shortcut.playbackDurationMilliseconds == 1_200)
        #expect(String(decoding: shortcut.events[0].bytes, as: UTF8.self) == "cd web\n")
        #expect(String(decoding: shortcut.events[1].bytes, as: UTF8.self) == "yarn test\n")
        #expect(String(decoding: shortcut.events[2].bytes, as: UTF8.self) == "echo done\n")
        #expect(shortcut.events[3].bytes == [27])
    }

    @MainActor
    @Test("terminal tools follow the active tab for every conversation")
    func testTerminalToolsFollowActiveTab() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionA = UUID()
        let sessionB = UUID()
        let tabA = controller.openLocalTab(
            originAgentSessionID: sessionA,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        let tabB = controller.openLocalTab(
            originAgentSessionID: sessionB,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        defer {
            controller.closeTab(id: tabA.id)
            controller.closeTab(id: tabB.id)
        }

        #expect(controller.activeTabID == tabB.id)
        #expect(controller.ownedTabID(for: sessionA) == tabA.id)
        // Both conversations read the tab the user is currently looking at.
        #expect(try controller.rawSnapshot(sessionID: sessionA).tabID == tabB.id)
        #expect(try controller.rawSnapshot(sessionID: sessionB).tabID == tabB.id)

        controller.activateTab(id: tabA.id)
        #expect(try controller.rawSnapshot(sessionID: sessionB).tabID == tabA.id)

        // terminal_select_tab surface: switches routing and the visible tab.
        _ = try controller.selectTab(id: tabB.id)
        #expect(controller.activeTabID == tabB.id)
        #expect(try controller.rawSnapshot(sessionID: sessionA).tabID == tabB.id)
    }

    @MainActor
    @Test("opening terminal in a fresh conversation creates an isolated tab")
    func testFreshConversationTerminalDoesNotReuseVisibleTab() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionA = UUID()
        let sessionB = UUID()
        let tabA = controller.openLocalTab(
            originAgentSessionID: sessionA,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )

        controller.ensureAtLeastOneTab(
            originAgentSessionID: sessionB,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        let tabBID = try #require(controller.ownedTabID(for: sessionB))
        defer {
            controller.closeTab(id: tabA.id)
            controller.closeTab(id: tabBID)
        }

        #expect(tabBID != tabA.id)
        #expect(controller.tabs.count == 2)
        #expect(controller.tab(id: tabBID)?.originAgentSessionID == sessionB)

        controller.activateOwnedTab(for: sessionA)
        #expect(controller.activeTabID == tabA.id)
        controller.activateOwnedTab(for: sessionB)
        #expect(controller.activeTabID == tabBID)

        controller.ensureAtLeastOneTab(
            originAgentSessionID: sessionB,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        #expect(controller.tabs.count == 2)
    }

    @MainActor
    @Test("explicit terminal tab id overrides the active tab without moving it")
    func testExplicitTerminalTabIDOverridesActiveTab() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        let other = controller.openLocalTab(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        let active = controller.openLocalTab(
            originAgentSessionID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        defer {
            controller.closeTab(id: other.id)
            controller.closeTab(id: active.id)
        }

        #expect(controller.activeTabID == active.id)
        #expect(try controller.rawSnapshot(targetTabID: other.id, sessionID: sessionID).tabID == other.id)
        // An explicit one-off read of another tab must not steal the active
        // tab — later unqualified calls still hit what the user sees.
        #expect(controller.activeTabID == active.id)
        #expect(try controller.rawSnapshot(sessionID: sessionID).tabID == active.id)
        #expect(throws: AgentToolError.self) {
            _ = try controller.rawSnapshot(targetTabID: UUID(), sessionID: sessionID)
        }
        #expect(throws: AgentToolError.self) {
            _ = try controller.selectTab(id: UUID())
        }
    }

    @MainActor
    @Test("terminal command reports a stale explicit tab without rerouting")
    func testTerminalCommandRejectsStaleExplicitTabWithoutRerouting() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        let visible = controller.openLocalTab(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        defer { controller.closeTab(id: visible.id) }

        let staleTabID = UUID()
        do {
            _ = try controller.sendApprovedCommand(
                "echo should-not-run",
                targetTabID: staleTabID,
                sessionID: sessionID
            )
            Issue.record("expected a stale explicit terminal id to fail safely")
        } catch let error as AgentToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("no longer open"))
            #expect(message.contains("Nothing was executed"))
            #expect(message.contains("retry without terminal_tab_id"))
        }
        #expect(controller.activeTabID == visible.id)
        #expect(visible.recentCommands.isEmpty)
    }

    @MainActor
    @Test("terminal command returns an automatic follow-up snapshot instead of dispatch-only output")
    func testTerminalCommandReturnsAutomaticFollowUpSnapshot() async throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        let tab = controller.openLocalTab(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        defer { controller.closeTab(id: tab.id) }
        try await Task.sleep(nanoseconds: 300_000_000)

        let marker = "willdeep-terminal-follow-up-\(UUID().uuidString)"
        let result = try await AgentTerminalTools.sendCommand(
            arguments: [
                "command": .string("printf '\(marker)\\n'"),
                "terminal_tab_id": .string(tab.id.uuidString)
            ],
            context: AgentToolContext(
                rootDirectory: FileManager.default.temporaryDirectory,
                runtimeID: sessionID,
                sandboxMode: .workspaceWrite,
                terminalController: controller
            )
        )

        #expect(result.payload.contains("Command dispatch confirmed"))
        #expect(result.payload.contains("does not contain command output"))
        #expect(result.payload.contains("Automatic follow-up snapshot"))
        #expect(result.payload.contains(marker))
        #expect(result.payload.contains(tab.id.uuidString))
        #expect(result.payload.contains("call terminal_snapshot again"))
    }

    @MainActor
    @Test("terminal command explains when its approved tab exited")
    func testTerminalCommandExplainsExitedApprovedTab() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        let tab = controller.openLocalTab(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        tab.terminate()
        defer { controller.closeTab(id: tab.id) }

        do {
            _ = try controller.sendApprovedCommand(
                "echo should-not-run",
                targetTabID: tab.id,
                sessionID: sessionID
            )
            Issue.record("expected an exited approved terminal tab to fail safely")
        } catch let error as AgentToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("exited before the command could be sent"))
            #expect(message.contains("Nothing was executed"))
            #expect(message.contains("terminal_snapshot"))
        }
        #expect(tab.recentCommands.isEmpty)
    }

    @MainActor
    @Test("no open tabs yields guidance; any open tab routes for every conversation")
    func testSnapshotGuidanceWithoutTabsAndActiveTabFallback() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionA = UUID()
        let sessionB = UUID()

        do {
            _ = try controller.rawSnapshot(sessionID: sessionB)
            Issue.record("expected empty-panel snapshot to throw the no-tab guidance error")
        } catch let error as AgentToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("no open tabs"))
        }

        let tabA = controller.openLocalTab(
            originAgentSessionID: sessionA,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        defer { controller.closeTab(id: tabA.id) }

        // Another conversation reads the visible tab instead of erroring.
        #expect(try controller.rawSnapshot(sessionID: sessionB).tabID == tabA.id)
    }

    @MainActor
    @Test("start recording opens a local shell tab when none is usable")
    func testStartRecordingOpensLocalTabWhenNoneUsable() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        controller.defaultLocalTabProvider = { requested in
            (settings, FileManager.default.temporaryDirectory.path, requested ?? sessionID, nil)
        }

        #expect(controller.tabs.isEmpty)
        controller.startRecordingActiveTab()

        let created = try #require(controller.tabs.first)
        defer { controller.closeTab(id: created.id) }
        #expect(controller.tabs.count == 1)
        #expect(created.kind == .localShell)
        #expect(created.originAgentSessionID == sessionID)
        #expect(controller.activeTabID == created.id)
        #expect(controller.isRecording)
        controller.stopRecording()
        #expect(!controller.isRecording)
    }

    @Test("host identity probe hides its output marker from the echoed command")
    func testHostIdentityProbeCommandHidesMarker() {
        let command = AgentTerminalTab.hostIdentityProbeCommand
        #expect(!command.contains(AgentTerminalTab.hostIdentityMarker))
        #expect(command.contains("hostname"))
        #expect(command.contains("os-release"))
        #expect(command.contains("sw_vers"))
    }

    @MainActor
    @Test("terminal shortcut creation rejects protected dictated secrets")
    func testTerminalShortcutCreationRejectsProtectedDictatedSecrets() async throws {
        let controller = AgentInteractiveTerminalController()
        let context = AgentToolContext(
            rootDirectory: nil,
            sandboxMode: .workspaceWrite,
            terminalController: controller
        )

        await #expect(throws: AgentToolError.self) {
            try await AgentTerminalTools.createShortcut(
                arguments: [
                    "title": .string("Secret login"),
                    "events_json": .string("[{\"password\":\"hunter2\"}]")
                ],
                context: context
            )
        }
    }

    @MainActor
    @Test("terminal shortcut dictated placeholders are filled locally into vault")
    func testTerminalShortcutDictatedPlaceholdersFillLocallyIntoVault() async throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-placeholder-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let controller = AgentInteractiveTerminalController()
        let context = AgentToolContext(
            rootDirectory: nil,
            sandboxMode: .workspaceWrite,
            terminalController: controller
        )
        let result = try await AgentTerminalTools.createShortcut(
            arguments: [
                "title": .string("需要密码的流程"),
                "events_json": .string("""
                [
                  {"command":"ssh deploy@example.com"},
                  {"protected_placeholder":"密码 1"},
                  {"control":"enter"}
                ]
                """)
            ],
            context: context
        )

        var shortcut = try #require(controller.shortcuts.first)
        #expect(shortcut.hasProtectedInput)
        #expect(shortcut.hasPendingProtectedInput)
        #expect(shortcut.pendingProtectedInputCount == 1)
        #expect(result.payload.contains(#""kind" : "protected_placeholder""#))
        #expect(result.payload.contains(#""placeholder" : "密码 1""#))

        let filled = try controller.fillProtectedInputs(
            shortcutID: shortcut.id,
            valuesByEventIndex: [1: " local-only-password "]
        )
        shortcut = try #require(controller.shortcuts.first)

        #expect(filled.hasPendingProtectedInput == false)
        #expect(shortcut.hasPendingProtectedInput == false)
        #expect(shortcut.events[1].resolvedBytes() == Array(" local-only-password ".utf8))

        let persistedJSON = try String(contentsOf: TerminalShortcutStore.fileURL, encoding: .utf8)
        let vaultJSON = try String(
            contentsOf: shortcutsDirectory.appendingPathComponent("protected-vault.json"),
            encoding: .utf8
        )
        #expect(!persistedJSON.contains("local-only-password"))
        #expect(!vaultJSON.contains("local-only-password"))
    }

    @Test("terminal shortcut persistence deduplicates repeated protected input")
    func testTerminalShortcutPersistenceDeduplicatesRepeatedProtectedInput() throws {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("terminal-shortcut-protected-dedupe-\(UUID().uuidString)")
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-protected-dedupe-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let repeatedSecret = Array("same-secret-password".utf8)
        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Repeated password",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 2_000,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 0,
                    bytes: [],
                    requiresEchoOff: true,
                    transientProtectedBytes: repeatedSecret
                ),
                TerminalShortcutEvent(
                    delayMilliseconds: 500,
                    bytes: [],
                    requiresEchoOff: true,
                    transientProtectedBytes: repeatedSecret
                )
            ],
            hasProtectedInput: true
        )

        TerminalShortcutStore.save([shortcut])
        let loaded = try #require(TerminalShortcutStore.load().first)
        let accounts = loaded.events.compactMap(\.protectedBytesReference)

        #expect(accounts.count == 2)
        #expect(Set(accounts).count == 1)

        AgentCredentialStore._resetTestAccessCounts()
        var cache: [String: [UInt8]] = [:]
        #expect(loaded.events[0].resolvedBytes(cache: &cache) == repeatedSecret)
        #expect(loaded.events[1].resolvedBytes(cache: &cache) == repeatedSecret)
        #expect(AgentCredentialStore._testLoadCount(account: try #require(accounts.first)) == 0)
        #expect(AgentCredentialStore._testSaveCount(account: try #require(accounts.first)) == 0)

        let persistedJSON = try String(contentsOf: TerminalShortcutStore.fileURL, encoding: .utf8)
        let vaultJSON = try String(
            contentsOf: shortcutsDirectory.appendingPathComponent("protected-vault.json"),
            encoding: .utf8
        )
        #expect(!persistedJSON.contains("same-secret-password"))
        #expect(!vaultJSON.contains("same-secret-password"))
    }

    @MainActor
    @Test("terminal shortcut AI edit operations avoid protected bytes")
    func testTerminalShortcutAIEditOperationsAvoidProtectedBytes() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-ai-edit-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 2_000,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 1_000,
                    bytes: Array("echo old\n".utf8)
                ),
                TerminalShortcutEvent(
                    delayMilliseconds: 500,
                    bytes: [],
                    requiresEchoOff: true,
                    protectedBytesReference: "terminal-shortcut/existing/protected"
                )
            ],
            hasProtectedInput: true
        )
        TerminalShortcutStore.save([shortcut])

        let controller = AgentInteractiveTerminalController()
        let edited = try controller.editShortcut(
            id: shortcut.id,
            title: "After",
            operations: [
                TerminalShortcutEditOperation(
                    kind: .setDelay,
                    eventIndex: 0,
                    delayMilliseconds: 250,
                    text: nil,
                    find: nil,
                    replacement: nil
                ),
                TerminalShortcutEditOperation(
                    kind: .replaceVisibleText,
                    eventIndex: 0,
                    delayMilliseconds: nil,
                    text: nil,
                    find: "old",
                    replacement: "new"
                )
            ]
        )

        #expect(edited.title == "After")
        #expect(edited.events[0].delayMilliseconds == 250)
        #expect(String(decoding: edited.events[0].bytes, as: UTF8.self) == "echo new\n")

        #expect(throws: AgentToolError.self) {
            try controller.editShortcut(
                id: shortcut.id,
                title: nil,
                operations: [
                    TerminalShortcutEditOperation(
                        kind: .setVisibleText,
                        eventIndex: 1,
                        delayMilliseconds: nil,
                        text: "exposed",
                        find: nil,
                        replacement: nil
                    )
                ]
            )
        }
    }

    @MainActor
    @Test("live thinking preview tracks streaming reasoning and dies with the indicator")
    func testAgentLiveThinkingPreview() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentMessages = [AgentMessage(role: .user, content: "查一下这个 bug")]
        // 占位 assistant 还没到 / reasoning 还没流出来 → 无预览
        #expect(appState.agentLiveThinkingPreview == nil)

        appState.agentMessages.append(
            AgentMessage(role: .assistant, content: "", reasoningContent: "先读取文件，再分析调用链")
        )
        #expect(appState.agentLiveThinkingPreview == "先读取文件，再分析调用链")
        // Reasoning 流在识别不出阶段动词时仍会兜底成当前动作扫光标题，
        // 避免回合中段出现空白活动行。
        #expect(appState.agentCurrentActivityHeadline?.title == L10n.AgentActivity.thinking)
        #expect(appState.agentCurrentActivityHeadline?.liveTitle == "先读取文件，再分析调用链")

        // 已知阶段开头的一行正文成为当前动作，保留完整可见标题。
        appState.agentMessages[1].content = "Planning Swift enum extensions"
        #expect(appState.agentLiveThinkingPreview == nil)
        #expect(
            appState.agentCurrentActivityHeadline?.liveTitle
                == "Planning Swift enum extensions"
        )

        // 普通回答正文不冒充动作标题。
        appState.agentMessages[1].content = "好的"
        #expect(appState.agentCurrentActivityHeadline == nil)

        // turn 结束后即使 reasoning 还挂在消息上也不再预览
        appState.agentMessages[1].content = ""
        appState.isAgentResponding = false
        #expect(appState.agentLiveThinkingPreview == nil)
    }

    @MainActor
    @Test("streaming buffer publishes reasoning and answer as one atomic frame")
    func testAgentStreamingBufferPublishesAtomically() {
        let assistant = AgentMessage(role: .assistant, content: "")
        let runtime = AgentRuntime(session: AgentSession(messages: [assistant]))
        let buffer = AgentStreamingMessageBuffer(runtime: runtime, assistantID: assistant.id)
        var publishCount = 0
        let observation = runtime.objectWillChange.sink { publishCount += 1 }

        buffer.appendReasoningDelta("先检查文件")
        buffer.appendTextDelta("结论")
        buffer.flushPending()

        #expect(publishCount == 1)
        #expect(runtime.messages[0].reasoningContent == "先检查文件")
        #expect(runtime.messages[0].content == "结论")
        withExtendedLifetime(observation) {}
    }

    @Test("command palette matcher supports fuzzy and keyword lookup")
    func testCommandPaletteMatcher() {
        let command = PaletteCommand(
            title: "Open Terminal Here",
            subtitle: "Open Terminal at the project location",
            icon: "terminal",
            isEnabled: true,
            keywords: ["shell", "cli"]
        ) {}

        #expect(PaletteCommandMatcher.matches("oth", command: command) == true)
        #expect(PaletteCommandMatcher.matches("cli", command: command) == true)
        #expect(PaletteCommandMatcher.matches("preview", command: command) == false)
    }

    // Editor file loading, saving, tab, find, and dirty-state tests live in EditorWorkflowTests.swift.

    // Agent tool and command-safety tests live in AgentToolIntegrationTests.swift.

    @Test("shouldAutoCompressNow flips true once estimated context usage crosses 75%")
    @MainActor
    func testShouldAutoCompressTriggersAt75Percent() {
        let appState = AppState()
        // `agentMessages` / `isAgentResponding` / `isCompressingAgentContext`
        // all delegate to `activeRuntime` — without an explicit session,
        // writes are dropped and `shouldAutoCompressNow` short-circuits to
        // false regardless of what we try to set up. Solo runs happened to
        // inherit an `activeAgentSessionID` restored from disk by another
        // test; in a full-suite run that isolation breaks. Create the
        // session ourselves so this test stands on its own.
        _ = appState.startNewAgentSession()

        // Force a known small context window so the test doesn't depend
        // on the model fallback table.
        var config = appState.agentConfiguration
        config.model = "gpt-3.5-16k"
        config.flashModel = "gpt-3.5-16k"
        config.routingMode = .flash
        appState.agentConfiguration = config

        // Empty conversation must not trigger.
        #expect(appState.shouldAutoCompressNow == false)

        // Add 7 messages so the > 6 guard passes, but with tiny content
        // so estimated tokens stay low.
        for _ in 0..<7 {
            appState.agentMessages.append(AgentMessage(role: .user, content: "hi"))
        }
        #expect(appState.shouldAutoCompressNow == false)

        // Replace with messages that push estimated tokens past 75%.
        appState.agentMessages.removeAll()
        let observedWindow = appState.agentContextWindow
        // Need > 75% of the actual resolved window. We don't pin a
        // model fallback here because `normalized` reshuffles based
        // on provider hints — instead aim for whatever the live
        // `agentContextWindow` reports. estimateTextTokens for an
        // ascii-only string is ceil(count/4), so spread > 0.8×window×4
        // chars across 8 messages to clear the threshold with margin.
        let perMessageChars = max(2_000, (observedWindow * 4 * 80) / (100 * 8))
        let bigChunk = String(repeating: "a", count: perMessageChars)
        for _ in 0..<8 {
            appState.agentMessages.append(AgentMessage(role: .user, content: bigChunk))
        }
        #expect(appState.shouldAutoCompressNow == true)

        // A compression already in flight must suppress the trigger.
        appState.isCompressingAgentContext = true
        #expect(appState.shouldAutoCompressNow == false)
        appState.isCompressingAgentContext = false

        // Likewise, while the agent is still streaming a turn.
        appState.isAgentResponding = true
        #expect(appState.shouldAutoCompressNow == false)
        appState.isAgentResponding = false
    }

    @Test("context compression summary only affects model-facing history")
    func testContextSummaryPreservesLocalTranscript() {
        let oldUser = AgentMessage(role: .user, content: "old user turn")
        let oldAssistant = AgentMessage(role: .assistant, content: "old assistant answer")
        let recentUser = AgentMessage(role: .user, content: "recent user turn")
        let recentAssistant = AgentMessage(role: .assistant, content: "recent assistant answer")
        let localMessages = [oldUser, oldAssistant, recentUser, recentAssistant]

        let modelHistory = AppState.modelFacingHistory(
            messages: localMessages,
            contextSummary: "summary of older turns",
            contextSummaryThroughMessageID: oldAssistant.id
        )

        #expect(localMessages.map(\.content) == [
            "old user turn",
            "old assistant answer",
            "recent user turn",
            "recent assistant answer",
        ])
        #expect(modelHistory.count == 3)
        #expect(modelHistory.first?.role == .user)
        #expect(modelHistory.first?.source == .hostInstruction)
        #expect(modelHistory.first?.content.contains("<untrusted-conversation-summary>") == true)
        #expect(modelHistory.first?.content.contains("summary of older turns") == true)
        #expect(modelHistory.dropFirst().map(\.id) == [recentUser.id, recentAssistant.id])
        #expect(modelHistory.contains(where: { $0.content == "old user turn" }) == false)
    }

    @Test("agent file path links strip line suffixes")
    func testAgentFilePathWithoutLineSuffix() {
        #expect(AppState.agentFilePathWithoutLineSuffix("src/App.swift:42") == "src/App.swift")
        #expect(AppState.agentFilePathWithoutLineSuffix("web/src/index.tsx:12:4") == "web/src/index.tsx")
        #expect(AppState.agentFilePathWithoutLineSuffix("/Users/test/demo/file.vue") == "/Users/test/demo/file.vue")
    }

    @Test("some.im account credits use compact display for sidebar")
    func testSomeIMAccountCompactCredits() {
        let account = SomeIMAccount(
            email: "user@example.com",
            tenantID: nil,
            balanceUSD: "42090.04666",
            credits: "4209004666",
            creditsPerUSD: 100000,
            defaultModel: "gpt-image-2",
            lastUpdatedAt: Date()
        )

        #expect(account.compactDisplayCredits == "4.21B")
        #expect(SomeIMAccount.compactCredits("46000000") == "46.00M")
        #expect(SomeIMAccount.compactCredits("999999") == nil)
    }

    @Test("ask_user tool is registered with userInput risk and a question parameter")
    func testAskUserToolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "ask_user")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .userInput)
        #expect(descriptor?.parameters.contains(where: { $0.name == "question" && $0.required }) == true)

        let risk = AgentToolRegistry.risk(
            for: "ask_user",
            arguments: ["question": .string("What port should the server bind to?")]
        )
        #expect(risk == .userInput)
    }

    @Test("generate_image runs without user approval")
    func testGenerateImageToolDoesNotRequireApproval() {
        let descriptor = AgentToolRegistry.descriptor(for: "generate_image")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .read)
        #expect(descriptor?.parameters.contains(where: { $0.name == "prompt" && $0.required }) == true)

        let risk = AgentToolRegistry.risk(
            for: "generate_image",
            arguments: ["prompt": .string("A clean product mockup")]
        )
        #expect(risk == .read)
    }

    @Test("ask_user exposes optional options and multi_select parameters")
    func testAskUserExposesChoiceParameters() {
        let descriptor = AgentToolRegistry.descriptor(for: "ask_user")
        let options = descriptor?.parameters.first { $0.name == "options" }
        let multi = descriptor?.parameters.first { $0.name == "multi_select" }

        #expect(options?.type == .stringArray)
        #expect(options?.required == false)
        #expect(multi?.type == .boolean)
        #expect(multi?.required == false)
    }

    @Test("provider-ready messages drop orphan tool messages")
    func testProviderReadyMessagesDropOrphanTools() {
        let messages = [
            AgentMessage(role: .user, content: "hi"),
            AgentMessage(role: .tool, content: "orphan", toolCallID: "call_orphan"),
            AgentMessage(role: .assistant, content: "done")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.map(\.role) == [.user, .assistant])
    }

    @Test("provider-ready messages keep complete assistant tool exchanges")
    func testProviderReadyMessagesKeepCompleteToolExchange() {
        let toolCallA = AgentMessageToolCall(
            externalID: "call_a",
            toolName: "read_file",
            argumentsJSON: #"{"path":"A.swift"}"#
        )
        let toolCallB = AgentMessageToolCall(
            externalID: "call_b",
            toolName: "git_status",
            argumentsJSON: "{}"
        )
        let assistant = AgentMessage(role: .assistant, content: "", toolCalls: [toolCallA, toolCallB])
        let messages = [
            AgentMessage(role: .user, content: "check"),
            assistant,
            AgentMessage(role: .tool, content: "b", toolCallID: "call_b"),
            AgentMessage(role: .tool, content: "a", toolCallID: "call_a"),
            AgentMessage(role: .assistant, content: "done")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.count == 5)
        #expect(normalized[1].toolCalls.map(\.externalID) == ["call_a", "call_b"])
        #expect(normalized[2].toolCallID == "call_a")
        #expect(normalized[3].toolCallID == "call_b")
    }

    @Test("provider-ready messages drop incomplete assistant tool exchanges")
    func testProviderReadyMessagesDropIncompleteToolExchange() {
        let toolCallA = AgentMessageToolCall(
            externalID: "call_a",
            toolName: "read_file",
            argumentsJSON: "{}"
        )
        let toolCallB = AgentMessageToolCall(
            externalID: "call_b",
            toolName: "git_status",
            argumentsJSON: "{}"
        )
        let messages = [
            AgentMessage(role: .assistant, content: "", toolCalls: [toolCallA, toolCallB]),
            AgentMessage(role: .tool, content: "a", toolCallID: "call_a"),
            AgentMessage(role: .user, content: "next")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.map(\.role) == [.user])
        #expect(normalized.first?.content == "next")
    }

    @Test("provider-ready messages drop fully-empty assistant messages")
    func testProviderReadyMessagesDropEmptyAssistantMessages() {
        let messages = [
            AgentMessage(role: .user, content: "hi"),
            // 流式 turn 一无所出后残留的占位消息：无文本、无 tool calls。
            // 上线会被 OpenAI 兼容服务端以 400 拒绝（content or
            // tool_calls must be set）。
            AgentMessage(role: .assistant, content: ""),
            AgentMessage(role: .user, content: "still there?"),
            // reasoning-only 也不可表示：没有 content key 也没有 tool_calls。
            AgentMessage(role: .assistant, content: "", reasoningContent: "thinking..."),
            AgentMessage(role: .assistant, content: "done")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.map(\.role) == [.user, .user, .assistant])
        #expect(normalized.last?.content == "done")
    }

    @Test("request summary lists tool calls on empty-content assistant messages")
    func testRequestSummaryListsToolCalls() {
        let toolCall = AgentMessageToolCall(
            externalID: "call_a",
            toolName: "read_file",
            argumentsJSON: "{}"
        )
        let messages = [
            AgentMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            AgentMessage(role: .tool, content: "ok", toolCallID: "call_a")
        ]

        let summary = AgentNetworkSupport.requestSummary(for: messages)

        #expect(summary.contains("assistant: (empty) [1 tool_call: read_file]"))
    }

    @Test("provider-ready messages omit image parts when provider is text-only")
    func testProviderReadyMessagesOmitImagesForTextOnlyProviders() throws {
        let image = AgentImageAttachment(
            mimeType: "image/png",
            dataBase64: "aGVsbG8="
        )
        let messages = [
            AgentMessage(role: .user, content: "please inspect", images: [image])
        ]

        let normalized = AgentClient.providerReadyMessages(messages, supportsImages: false)
        #expect(normalized.first?.images.isEmpty == true)
        #expect(normalized.first?.content.contains("omitted because this provider only accepts text messages") == true)

        let request = try AgentClient.encodeChatRequest(
            model: "deepseek-v4-flash",
            messages: messages,
            tools: [],
            supportsImages: false
        )
        let body = String(data: request, encoding: .utf8) ?? ""
        #expect(!body.contains("image_url"))
        #expect(body.contains("please inspect"))
    }

    @Test("AgentJSONValue stringArrayValue and boolValue work")
    func testAgentJSONValueHelpers() {
        let validArray: AgentJSONValue = .array([.string("a"), .string("b"), .string("c")])
        #expect(validArray.stringArrayValue() == ["a", "b", "c"])

        // Mixed types must NOT silently coerce.
        let mixedArray: AgentJSONValue = .array([.string("a"), .number(2)])
        #expect(mixedArray.stringArrayValue() == nil)

        #expect(AgentJSONValue.bool(true).boolValue() == true)
        #expect(AgentJSONValue.string("yes").boolValue() == true)
        #expect(AgentJSONValue.string("no").boolValue() == false)
        #expect(AgentJSONValue.number(0).boolValue() == false)
        #expect(AgentJSONValue.string("maybe").boolValue() == nil)
    }

    @Test("spawn_agent tool is registered as read risk with a required prompt")
    func testSpawnAgentToolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "spawn_agent")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .read)
        #expect(descriptor?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "run_in_background" }) == true)
        // Trades replaced the free-form `model` override: cost policy is the
        // user's configuration, not a per-call decision by the model.
        #expect(descriptor?.parameters.contains(where: { $0.name == "model" }) == false)
        #expect(descriptor?.parameters.contains(where: { $0.name == "profile" }) == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "target_file" }) == true)
    }

    @Test("run_command exposes background override and user-facing label")
    func testRunCommandBackgroundPresentationRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "run_command")
        #expect(descriptor?.parameters.contains(where: { $0.name == "run_in_background" }) == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "label" }) == true)
        #expect(descriptor?.description.contains("automatically moved to the background") == true)
    }

    @Test("MCP read-style tool names pass the static heuristic")
    func testMCPReadOnlyToolNameHeuristic() {
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("get_issue"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("list_repos"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("search_code"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("Fetch_Page"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("ping"))

        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("create_issue"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("delete_branch"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("update_file"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("getdata"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly(""))
    }

    @Test("trusted-server MCP calls with read-style names auto-approve")
    @MainActor
    func testMCPAutoApprovalForReadStyleTools() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        let approved = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("github"),
                "tool": .string("list_issues"),
                "arguments_json": .string(#"{"repo":"a/b"}"#),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(approved == .staticAllowlist)

        // 严格模式仍会把同一调用交给人工。
        let gated = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("github"),
                "tool": .string("list_issues"),
            ],
            risk: .write,
            rootDirectory: root,
            approvalMode: .requestEveryTime
        )
        #expect(gated == nil)
    }

    @Test("remote media-task tools auto-approve by default but not in requestEveryTime")
    @MainActor
    func testMediaTaskToolsAutoApproval() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        // 提交·轮询·取消都应默认免审批（含 some.im 与 replicate 家族）。
        for tool in [
            "some_im_create_media_task",
            "some_im_poll_media_task",
            "some_im_cancel_media_task",
            "replicate_create_prediction",
            "replicate_poll_prediction",
            "replicate_cancel_prediction",
        ] {
            let approved = await appState.autoApprovalSource(
                toolName: tool,
                arguments: ["task_id": .string("t-123")],
                risk: .write,
                rootDirectory: root
            )
            #expect(approved == .staticAllowlist, "\(tool) 应默认免审批")
        }

        // requestEveryTime 模式仍强制人工确认。
        let gated = await appState.autoApprovalSource(
            toolName: "some_im_create_media_task",
            arguments: ["task_id": .string("t-123")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .requestEveryTime
        )
        #expect(gated == nil)
    }

    @Test("MCP settings keep trusted and untrusted sets mutually exclusive")
    @MainActor
    func testMCPTrustSetsAreMutuallyExclusive() throws {
        // 同一 id 同时出现在两个集合 → normalized 后 untrusted 胜出。
        let conflicted = AgentMCPSettings(
            disabledServerIDs: [],
            userServers: [],
            untrustedServerIDs: ["user:x"],
            trustedServerIDs: ["user:x", "user:y"]
        ).normalized
        #expect(conflicted.untrustedServerIDs == ["user:x"])
        #expect(conflicted.trustedServerIDs == ["user:y"])

        // 旧版 settings JSON（无 trustedServerIDs 键）正常解码为空集。
        let legacyJSON = #"{"disabledServerIDs":[],"userServers":[],"untrustedServerIDs":["user:old"]}"#
        let decoded = try JSONDecoder().decode(AgentMCPSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.trustedServerIDs.isEmpty)
        #expect(decoded.untrustedServerIDs == ["user:old"])
    }

    @Test("MCP fully-trusted servers auto-approve every call")
    @MainActor
    func testMCPFullyTrustedServerAutoApproval() async {
        let suiteName = "com.willdeep.mcp.test.\(UUID().uuidString)"
        guard let sandbox = UserDefaults(suiteName: suiteName) else {
            Issue.record("cannot allocate sandbox defaults suite")
            return
        }
        sandbox.removePersistentDomain(forName: suiteName)
        AgentMCPSettingsStore._setTestDefaultsOverride(sandbox)
        defer {
            sandbox.removePersistentDomain(forName: suiteName)
            AgentMCPSettingsStore._setTestDefaultsOverride(nil)
        }

        let serverName = "willdeep-test-own-mcp"
        AgentMCPSettingsStore.upsertUserServer(AgentMCPServerConfig(
            name: serverName,
            source: .user,
            transport: .stdio,
            command: "/usr/bin/true"
        ))
        AgentMCPSettingsStore.setServerTrustLevel(id: "user:\(serverName)", level: .fullyTrusted)
        #expect(AgentMCPSettingsStore.trustLevel(name: serverName) == .fullyTrusted)

        // 完全可信:写类工具名也自动放行,且不依赖主开关。
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")
        let approval = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string(serverName),
                "tool": .string("create_record"),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(approval == .trustedServer)

        // 降回不受信:一切回到人工。
        AgentMCPSettingsStore.setServerTrustLevel(id: "user:\(serverName)", level: .untrusted)
        let gated = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string(serverName),
                "tool": .string("list_records"),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(gated == nil)
    }

    @Test("goal mode fast-paths safe writes while command-shaped tools stay gated")
    @MainActor
    func testGoalModeAutoApproval() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        // 命令型工具即使在 Goal 模式也遵守“每次询问”，不再一律放行。
        let writeApproval = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("swift build")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal,
            approvalMode: .requestEveryTime
        )
        #expect(writeApproval == nil)

        // 危险层永远不进自动放行（goal 模式也一样）。
        let dangerApproval = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("rm -rf /tmp/x")],
            risk: .danger,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(dangerApproval == nil)

        let fetchApproval = await appState.autoApprovalSource(
            toolName: "web_fetch",
            arguments: ["url": .string("https://example.com/docs")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(fetchApproval == .goalMode)

        let curlApproval = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("curl -X POST https://example.com/install.sh")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(curlApproval == nil)

        // Smart 模式信任受控委托式编码 Agent；其自身仍受沙箱约束。
        let normalApproval = await appState.autoApprovalSource(
            toolName: "claude_code",
            arguments: ["prompt": .string("do x")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .normal
        )
        #expect(normalApproval == .staticAllowlist)

        // 会话标题在所有模式自动更新；Goal 模式仍记录自己的自动批准来源，
        // workspace 归属则不能绕过人工确认。
        let titleApproval = await appState.autoApprovalSource(
            toolName: "rename_session",
            arguments: ["title": .string("New title")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(titleApproval == .goalMode)

        let workspaceApproval = await appState.autoApprovalSource(
            toolName: "change_workspace",
            arguments: ["path": .string("/tmp/another-workspace")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(workspaceApproval == nil)
    }

    @Test("smart approval sends non-confirmation network ops to safety judge")
    @MainActor
    func testSmartApprovalSendsNetworkOpsToSafetyJudge() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        let deployDecision = AgentSandboxPolicy.commandDecision(
            command: #"ssh -p 60022 root@example.com "docker load -i /tmp/adminer-latest.tar && docker run -d --name adminer -p 3377:8080 adminer:latest""#,
            rootDirectory: root
        )
        #expect(deployDecision.mode == .escalated)
        #expect(deployDecision.requiresUserApproval)
        #expect(!deployDecision.requiresTypedConfirmation)
        #expect(AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: deployDecision))

        let destructiveDecision = AgentSandboxPolicy.commandDecision(
            command: "rm -rf /",
            rootDirectory: root
        )
        #expect(destructiveDecision.requiresTypedConfirmation)
        #expect(!AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: destructiveDecision))

        let secretDecision = AgentSandboxPolicy.commandDecision(
            command: #"ssh deploy@example.com "cat ~/.ssh/id_rsa""#,
            rootDirectory: root
        )
        #expect(secretDecision.requiresTypedConfirmation)
        #expect(!AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: secretDecision))
    }

    @Test("safety judge prompt allows normal operations but rejects malicious commands")
    func testSafetyJudgePromptUsesMaliciousCommandPolicy() {
        let prompt = AgentInjectionDefense.judgeSystemPrompt
        #expect(prompt.contains("normal development"))
        #expect(prompt.contains("starting Docker containers"))
        #expect(prompt.contains("reloading nginx"))
        #expect(prompt.contains("delete broad paths"))
        #expect(prompt.contains("steal or print secrets"))
        #expect(prompt.contains("When in doubt, output NO"))
    }

    @Test("safety judge hydrates key from the matching-provider library entry")
    @MainActor
    func testSafetyJudgeHydratesKeyFromMatchingProviderEntry() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()

        // The judge runs on DeepSeek; the library owns a live DeepSeek key.
        let deepseek = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-live-deepseek",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        appState.agentProviderLibrary = AgentProviderLibrary(
            entries: [deepseek],
            activeID: deepseek.id
        )
        // Force the live config's key empty AFTER the library is set, so we
        // exercise the hydration path (the bootstrap / provider-switch window
        // where `agentConfiguration` and the library briefly disagree) rather
        // than the already-in-sync happy path.
        appState.agentConfiguration = AgentConfiguration(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKey: ""
        )

        let judge = appState.configurationForSafetyJudge()
        #expect(judge.apiKey == "sk-live-deepseek")
    }

    @Test("safety judge never donates a different provider's key")
    @MainActor
    func testSafetyJudgeDoesNotDonateCrossProviderKey() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()

        // The library holds ONLY an OpenAI key; the judge runs on DeepSeek.
        // The OpenAI secret must never be borrowed for a DeepSeek request
        // (the DeepSeek-key-copied-to-OpenAI-entry class of bug, in reverse).
        let openai = AgentProviderEntry(
            providerID: AgentProviderPreset.openAIID,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-openai-secret",
            flashPrimary: "gpt-4.1-mini",
            proPrimary: "gpt-4.1"
        )
        appState.agentProviderLibrary = AgentProviderLibrary(
            entries: [openai],
            activeID: openai.id
        )
        appState.agentConfiguration = AgentConfiguration(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKey: ""
        )

        let judge = appState.configurationForSafetyJudge()
        // Under XCTest the some.im fallback is disabled, so the judge config
        // stays the direct DeepSeek one with no borrowed key.
        #expect(judge.apiKey.isEmpty)
        #expect(judge.providerID == AgentProviderPreset.deepSeekID)
    }

    @Test("approval mode controls write-tier auto approval")
    @MainActor
    func testApprovalModeControlsWriteTierAutoApproval() async throws {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_approval_modes_\(UUID().uuidString)", isDirectory: true)
        let gitRoot = testRoot.appendingPathComponent("git-workspace", isDirectory: true)
        let noGitRoot = testRoot.appendingPathComponent("plain-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: gitRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noGitRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        func runGit(_ arguments: [String]) throws {
            let result = AppState.runGitCommand(arguments: arguments, in: gitRoot)
            try #require(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        }
        try runGit(["init"])
        try runGit(["config", "user.email", "tests@example.invalid"])
        try runGit(["config", "user.name", "WillDeep Tests"])
        try "baseline\n".write(
            to: gitRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"])
        try runGit(["commit", "-m", "baseline"])

        let askEveryTime = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("ls")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .requestEveryTime
        )
        #expect(askEveryTime == nil)

        let smart = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("ls")],
            risk: .write,
            rootDirectory: noGitRoot,
            approvalMode: .smart
        )
        #expect(smart == .staticAllowlist)

        let zmodemPathSelection = await appState.autoApprovalSource(
            toolName: "terminal_send_command",
            arguments: [
                "command": .string("rz"),
                "zmodem_upload_paths": .array([.string("build/app.tar.gz")]),
            ],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .smart
        )
        #expect(zmodemPathSelection == nil)

        let workspace = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("swift test")],
            risk: .write,
            rootDirectory: noGitRoot,
            approvalMode: .workspaceAccess
        )
        #expect(workspace == .workspaceAccess)

        let untrustedMCP = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("third-party"),
                "tool": .string("create_issue"),
            ],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .workspaceAccess
        )
        #expect(untrustedMCP == nil)

        // Workspace Access authorizes workspace writes, not external network
        // effects. Smart review is responsible for judging web/curl actions.
        let workspaceFetch = await appState.autoApprovalSource(
            toolName: "web_fetch",
            arguments: ["url": .string("https://docs.example.com/guide")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .workspaceAccess
        )
        #expect(workspaceFetch == nil)

        let workspaceCurl = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("curl https://example.com/status")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .workspaceAccess
        )
        #expect(workspaceCurl == nil)

        // A destructive typed-confirmation command still pauses in
        // Workspace Access — the hard safety gate must survive the hoist.
        let workspaceDestructive = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("rm -rf /tmp/willdeep-test-workspace")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .workspaceAccess
        )
        #expect(workspaceDestructive == nil)

        let goBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("go build -o bin/app . 2>&1")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .smart
        )
        #expect(goBuild == .staticAllowlist)

        let noGitBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("go build -o bin/app . 2>&1")],
            risk: .write,
            rootDirectory: noGitRoot,
            approvalMode: .smart
        )
        #expect(noGitBuild == .staticAllowlist)

        let gitDelegatedAgent = await appState.autoApprovalSource(
            toolName: "claude_code",
            arguments: ["prompt": .string("update the project")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .smart
        )
        #expect(gitDelegatedAgent == .staticAllowlist)

        let noGitDelegatedAgent = await appState.autoApprovalSource(
            toolName: "claude_code",
            arguments: ["prompt": .string("update the project")],
            risk: .write,
            rootDirectory: noGitRoot,
            approvalMode: .smart
        )
        #expect(noGitDelegatedAgent == .staticAllowlist)

        let yarnBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("yarn run build")],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .smart
        )
        #expect(yarnBuild == .staticAllowlist)

        let heredocGeneration = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("""
            cd \(gitRoot.path) && python3 << 'PYEOF'
            from pathlib import Path
            Path("Generated.swift").write_text("let value = 1\\n")
            PYEOF
            """)],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .smart
        )
        #expect(heredocGeneration == .staticAllowlist)

        let outsideWorkspaceGeneration = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("""
            cd \(gitRoot.path) && cat > /tmp/outside.txt << 'EOF'
            generated
            EOF
            """)],
            risk: .write,
            rootDirectory: gitRoot,
            approvalMode: .smart
        )
        #expect(outsideWorkspaceGeneration == nil)
    }

    @Test("git baseline detection remains available for recovery diagnostics")
    func testRecoverableGitBaselineDetection() throws {
        #expect(AppState.findGitRepositoryRoot(startingAt: URL(fileURLWithPath: "/")) == nil)

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_git_baseline_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(!AppState.hasRecoverableGitBaseline(startingAt: workspace))
        #expect(AppState.runGitCommand(arguments: ["init"], in: workspace).succeeded)
        #expect(!AppState.hasRecoverableGitBaseline(startingAt: workspace))

        #expect(AppState.runGitCommand(
            arguments: ["config", "user.email", "tests@example.invalid"],
            in: workspace
        ).succeeded)
        #expect(AppState.runGitCommand(
            arguments: ["config", "user.name", "WillDeep Tests"],
            in: workspace
        ).succeeded)
        try "baseline\n".write(
            to: workspace.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        #expect(AppState.runGitCommand(arguments: ["add", "README.md"], in: workspace).succeeded)
        #expect(AppState.runGitCommand(arguments: ["commit", "-m", "baseline"], in: workspace).succeeded)
        #expect(AppState.hasRecoverableGitBaseline(startingAt: workspace))
    }

    @Test("legacy agent session JSON defaults to smart approval")
    @MainActor
    func testLegacyAgentSessionDefaultsToSmartApproval() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "title": "Legacy",
          "createdAt": "2026-06-11T00:00:00Z",
          "updatedAt": "2026-06-11T00:00:00Z",
          "messages": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: Data(json.utf8))
        #expect(session.approvalMode == .smart)
    }

    @Test("claude_code tool is registered as write risk with safe modes")
    func testClaudeCodeToolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "claude_code")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .write)
        #expect(descriptor?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        // bypassPermissions must never be forwardable.
        #expect(!AgentToolRunner.claudeCodePermissionModes.contains("bypassPermissions"))
    }

    @Test("claude_code command line quotes the prompt safely")
    func testClaudeCodeCommandLineComposition() {
        let command = AgentToolRunner.claudeCodeCommandLine(
            executable: "/usr/local/bin/claude",
            prompt: "fix the bug in O'Brien's parser; rm nothing",
            permissionMode: "acceptEdits",
            model: "sonnet"
        )
        #expect(command.hasPrefix("'/usr/local/bin/claude' -p "))
        #expect(command.contains("'fix the bug in O'\\''Brien'\\''s parser; rm nothing'"))
        #expect(command.contains("--output-format text"))
        #expect(command.contains("--permission-mode acceptEdits"))
        #expect(command.contains("--model 'sonnet'"))

        let noModel = AgentToolRunner.claudeCodeCommandLine(
            executable: "/x/claude",
            prompt: "hi",
            permissionMode: "plan",
            model: nil
        )
        #expect(!noModel.contains("--model"))

        let unattended = AgentToolRunner.claudeCodeCommandLine(
            executable: "/x/claude",
            prompt: "implement",
            permissionMode: "bypassPermissions",
            model: nil
        )
        #expect(unattended.contains("--dangerously-skip-permissions"))
        #expect(!unattended.contains("--permission-mode"))
    }

    @Test("claude_code executable discovery prefers the native install path")
    func testClaudeCodeExecutableDiscovery() {
        let home = NSHomeDirectory()
        let found = AgentToolRunner.claudeCodeExecutablePath(
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" || $0 == "\(home)/.local/bin/claude" }
        )
        #expect(found == "\(home)/.local/bin/claude")

        let missing = AgentToolRunner.claudeCodeExecutablePath(
            environment: ["PATH": "/usr/local/bin"],
            isExecutable: { _ in false }
        )
        #expect(missing == nil)
    }

    @Test("claude_code always-allow signature is scoped by permission mode")
    func testClaudeCodeAuthorizationSignature() {
        let planSignature = AgentToolAuthorization.signature(
            toolName: "claude_code",
            arguments: ["permission_mode": .string("plan")]
        )
        #expect(planSignature == "claude_code:plan")

        let defaultSignature = AgentToolAuthorization.signature(
            toolName: "claude_code",
            arguments: [:]
        )
        #expect(defaultSignature == "claude_code:acceptEdits")
    }

    @Test("codex_cli, cursor_agent, and cline_cli tools are registered as write risk")
    func testExternalAgentToolRegistration() {
        let codex = AgentToolRegistry.descriptor(for: "codex_cli")
        #expect(codex != nil)
        #expect(codex?.risk == .write)
        #expect(codex?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(codex?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        #expect(!AgentToolRunner.codexCLIPermissionModes.contains("danger-full-access"))

        let cursor = AgentToolRegistry.descriptor(for: "cursor_agent")
        #expect(cursor != nil)
        #expect(cursor?.risk == .write)
        #expect(cursor?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(cursor?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        #expect(!AgentToolRunner.cursorAgentPermissionModes.contains("yolo"))

        let cline = AgentToolRegistry.descriptor(for: "cline_cli")
        #expect(cline != nil)
        #expect(cline?.risk == .write)
        #expect(cline?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(cline?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        #expect(!AgentToolRunner.clineCLIPermissionModes.contains("yolo"))
    }

    @Test("codex_cli command line uses sandboxed non-interactive exec")
    func testCodexCLICommandLineComposition() {
        let command = AgentToolRunner.codexCLICommandLine(
            executable: "/Applications/Codex.app/Contents/Resources/codex",
            prompt: "fix O'Brien parser",
            permissionMode: "workspaceWrite",
            model: "gpt-5",
            workspacePath: "/tmp/Work Dir"
        )
        #expect(command.hasPrefix("'/Applications/Codex.app/Contents/Resources/codex' -a never exec "))
        #expect(command.contains("--sandbox workspace-write"))
        #expect(!command.contains("--ask-for-approval"))
        #expect(command.contains("-a never"))
        #expect(command.contains("--cd '/tmp/Work Dir'"))
        #expect(command.contains("--model 'gpt-5'"))
        #expect(command.contains("'fix O'\\''Brien parser'"))
        #expect(!command.contains("dangerously-bypass"))

        let plan = AgentToolRunner.codexCLICommandLine(
            executable: "/x/codex",
            prompt: "plan",
            permissionMode: "plan",
            model: nil,
            workspacePath: nil
        )
        #expect(plan.contains("--sandbox read-only"))
        #expect(!plan.contains("--model"))
    }

    @Test("cursor_agent command line uses print mode and sandbox")
    func testCursorAgentCommandLineComposition() {
        let command = AgentToolRunner.cursorAgentCommandLine(
            executable: "/usr/local/bin/cursor",
            prompt: "fix O'Brien parser",
            permissionMode: "plan",
            model: "sonnet-4",
            workspacePath: "/tmp/Work Dir"
        )
        #expect(command.hasPrefix("'/usr/local/bin/cursor' agent "))
        #expect(command.contains("--print"))
        #expect(command.contains("--output-format text"))
        #expect(command.contains("--sandbox enabled"))
        #expect(command.contains("--trust"))
        #expect(command.contains("--mode plan"))
        #expect(command.contains("--workspace '/tmp/Work Dir'"))
        #expect(command.contains("--model 'sonnet-4'"))
        #expect(command.contains("'fix O'\\''Brien parser'"))
        #expect(!command.contains("--yolo"))
        #expect(!command.contains("--force"))

        let write = AgentToolRunner.cursorAgentCommandLine(
            executable: "/x/cursor",
            prompt: "implement",
            permissionMode: "default",
            model: nil,
            workspacePath: nil
        )
        #expect(!write.contains("--mode"))
        #expect(!write.contains("--model"))
    }

    @Test("cline_cli command line uses json one-shot mode and cwd")
    func testClineCLICommandLineComposition() {
        let command = AgentToolRunner.clineCLICommandLine(
            executable: "/usr/local/bin/cline",
            prompt: "fix O'Brien parser",
            permissionMode: "plan",
            model: "anthropic/claude-sonnet-4-6",
            workspacePath: "/tmp/Work Dir"
        )
        #expect(command.hasPrefix("'/usr/local/bin/cline' --json"))
        #expect(command.contains("--plan"))
        #expect(command.contains("--cwd '/tmp/Work Dir'"))
        #expect(command.contains("--model 'anthropic/claude-sonnet-4-6'"))
        #expect(command.contains("'fix O'\\''Brien parser'"))
        #expect(!command.contains("--yolo"))

        let act = AgentToolRunner.clineCLICommandLine(
            executable: "/x/cline",
            prompt: "implement",
            permissionMode: "act",
            model: nil,
            workspacePath: nil
        )
        #expect(!act.contains("--plan"))
        #expect(!act.contains("--model"))
    }

    @Test("external agent always-allow signatures are scoped by permission mode")
    func testExternalAgentAuthorizationSignatures() {
        #expect(AgentToolAuthorization.signature(
            toolName: "codex_cli",
            arguments: ["permission_mode": .string("plan")]
        ) == "codex_cli:plan")
        #expect(AgentToolAuthorization.signature(
            toolName: "codex_cli",
            arguments: [:]
        ) == "codex_cli:workspaceWrite")
        #expect(AgentToolAuthorization.signature(
            toolName: "cursor_agent",
            arguments: ["permission_mode": .string("ask")]
        ) == "cursor_agent:ask")
        #expect(AgentToolAuthorization.signature(
            toolName: "cursor_agent",
            arguments: [:]
        ) == "cursor_agent:default")
        #expect(AgentToolAuthorization.signature(
            toolName: "cline_cli",
            arguments: ["permission_mode": .string("plan")]
        ) == "cline_cli:plan")
        #expect(AgentToolAuthorization.signature(
            toolName: "cline_cli",
            arguments: [:]
        ) == "cline_cli:act")
    }

    @Test("lark-cli tool is registered and scoped behind Feishu approval")
    func testLarkCLIToolRiskClassification() {
        let descriptor = AgentToolRegistry.descriptor(for: "lark_cli")
        #expect(descriptor?.risk == .write)
        #expect(AgentToolRegistry.risk(for: "lark_cli", arguments: [
            "arguments": .array([.string("auth"), .string("status")])
        ]) == .read)
        #expect(AgentToolRegistry.risk(for: "lark_cli", arguments: [
            "arguments": .array([.string("schema"), .string("im.messages.list")])
        ]) == .read)
        #expect(AgentToolRegistry.risk(for: "lark_cli", arguments: [
            "arguments": .array([.string("im"), .string("+messages-send"), .string("--text"), .string("hello")])
        ]) == .write)
        #expect(AgentToolRegistry.risk(for: "lark_cli", arguments: [
            "arguments": .array([.string("im"), .string("messages"), .string("delete")])
        ]) == .danger)
        #expect(AgentToolAuthorization.signature(toolName: "lark_cli", arguments: [
            "arguments": .array([.string("docs"), .string("+create")])
        ]) == "lark_cli:docs:+create")
    }

    @Test("lark-cli command preview, URL extraction, and connector defaults are stable")
    func testLarkCLICommandPreviewURLAndConnectorDefaults() throws {
        let preview = AgentLarkCLI.commandPreview(arguments: [
            "docs",
            "+create",
            "--content",
            "Weekly's report",
        ])
        #expect(preview.contains("'Weekly'\\''s report'"))
        #expect(AgentLarkCLI.installNpxArguments == ["--yes", "@larksuite/cli@latest", "install"])
        #expect(AgentLarkCLI.installCommand == "npx --yes @larksuite/cli@latest install")

        let url = try #require(AgentLarkCLI.firstURL(in: "open https://example.com/setup?code=abc to continue"))
        #expect(url.absoluteString == "https://example.com/setup?code=abc")
        #expect(CollaborationConnectorPlatform.feishu.defaultAuthMode == .officialLarkCLI)

        let normalized = CollaborationConnectorConfig(
            platform: .dingtalk,
            authMode: .officialLarkCLI
        ).normalized
        #expect(normalized.authMode == .officialMCP)
    }

    @Test("MCP drafts preserve stdio command and environment prefill metadata")
    func testMCPDraftPreservesPrefillMetadata() throws {
        let draft = AgentLearningMCPDraft(
            capability: "DingTalk official MCP tools",
            serverName: "dingtalk",
            installHint: "npx -y dingtalk-mcp@latest",
            searchQuery: "open-dingtalk dingtalk-mcp",
            transport: .stdio,
            command: "npx",
            args: ["-y", "dingtalk-mcp@latest"],
            env: [
                "DINGTALK_Client_ID": "cid",
                "DINGTALK_Client_Secret": ""
            ],
            url: nil,
            headers: nil,
            startupTimeout: 60,
            reason: "Use official MCP instead of an unavailable DingTalk CLI."
        )

        let decoded = try JSONDecoder().decode(
            AgentLearningMCPDraft.self,
            from: JSONEncoder().encode(draft)
        )
        #expect(decoded.transport == .stdio)
        #expect(decoded.command == "npx")
        #expect(decoded.args == ["-y", "dingtalk-mcp@latest"])
        #expect(decoded.env?["DINGTALK_Client_ID"] == "cid")
        #expect(decoded.startupTimeout == 60)
        #expect(CollaborationConnectorPlatform.dingtalk.defaultAuthMode == .officialMCP)
    }

    @Test("subagent tool surface is read-only and cannot nest or ask")
    @MainActor
    func testSubagentToolSurfaceIsRestricted() {
        let allowed = AgentSubagentRunner.allowedToolNames
        #expect(!allowed.contains("spawn_agent"))
        #expect(!allowed.contains("claude_code"))
        #expect(!allowed.contains("codex_cli"))
        #expect(!allowed.contains("cursor_agent"))
        #expect(!allowed.contains("cline_cli"))
        #expect(!allowed.contains("ask_user"))
        #expect(!allowed.contains("call_mcp_tool"))
        #expect(!allowed.contains("kill_job"))
        #expect(allowed.contains("read_file"))
        #expect(allowed.contains("grep_files"))

        // Every allowed name must resolve to a registered descriptor —
        // a typo here would silently shrink the child's tool surface.
        let descriptors = AgentSubagentRunner.toolDescriptors
        #expect(Set(descriptors.map(\.name)) == allowed)
    }

    @Test("subagent report notice carries handle, label and report body")
    func testSubagentReportNotice() {
        var run = AgentSubagentRun(
            id: UUID(),
            shortID: "ab12cd",
            label: "explore-auth",
            prompt: "find the auth flow",
            parentRuntimeID: UUID(),
            model: "test-model",
            startedAt: Date()
        )
        run.status = .completed
        run.finishedAt = run.startedAt.addingTimeInterval(5)
        run.report = "Auth lives in Auth.swift"
        run.roundCount = 2
        run.toolInvocationCount = 3

        let notice = AppState.subagentReportNotice(for: run)
        #expect(notice.contains("agent_ab12cd"))
        #expect(notice.contains("explore-auth"))
        #expect(notice.contains("Auth lives in Auth.swift"))
        #expect(notice.contains("<subagent-report>"))
    }

    @Test("background subagent failure is queued as a pending report")
    @MainActor
    func testBackgroundSubagentFailureQueuesReport() async throws {
        let registry = AgentSubagentRegistry()
        let parentID = UUID()
        // Empty API key → AgentClient throws immediately, no network.
        let configuration = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            flashModel: "",
            proModel: "",
            routingMode: .pro,
            apiKey: ""
        )

        let run = try registry.startBackground(
            prompt: "do something",
            label: "doomed",
            configuration: configuration,
            workspaceURL: nil,
            parentRuntimeID: parentID
        )
        #expect(run.status == .running)

        // Wait for the child task to fail and queue its report.
        var reports: [AgentSubagentRun] = []
        for _ in 0..<200 {
            reports = registry.consumePendingReports(forParentRuntime: parentID)
            if !reports.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(reports.count == 1)
        #expect(reports.first?.status == .failed)
        // Consuming is destructive — a second pull must be empty.
        #expect(registry.consumePendingReports(forParentRuntime: parentID).isEmpty)
    }

    @Test("subagent finish fires onRunFinished and pendingReportCount is non-destructive")
    @MainActor
    func testSubagentFinishFiresWakeupHook() async throws {
        let registry = AgentSubagentRegistry()
        let parentID = UUID()
        var hookRuns: [AgentSubagentRun] = []
        registry.onRunFinished = { hookRuns.append($0) }
        let configuration = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            flashModel: "",
            proModel: "",
            routingMode: .pro,
            apiKey: ""
        )
        _ = try registry.startBackground(
            prompt: "do something",
            label: "doomed",
            configuration: configuration,
            workspaceURL: nil,
            parentRuntimeID: parentID
        )
        for _ in 0..<200 {
            if !hookRuns.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The hook fires exactly when the report is queued, so a resume
        // triggered by it must observe a non-zero pending count.
        #expect(hookRuns.count == 1)
        #expect(hookRuns.first?.parentRuntimeID == parentID)
        #expect(registry.pendingReportCount(forParentRuntime: parentID) == 1)
        // Peeking is non-destructive; consuming drains it.
        #expect(registry.pendingReportCount(forParentRuntime: parentID) == 1)
        #expect(registry.consumePendingReports(forParentRuntime: parentID).count == 1)
        #expect(registry.pendingReportCount(forParentRuntime: parentID) == 0)
    }

    @Test("media task terminal transition fires onTaskFinished and queues a completion")
    @MainActor
    func testMediaTaskFinishFiresWakeupHook() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-task-wakeup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let registry = AgentMediaTaskRegistry(fileURL: scratch)
        let runtimeID = UUID()
        var hookTasks: [AgentMediaTask] = []
        registry.onTaskFinished = { hookTasks.append($0) }

        let task = registry.create(
            provider: .someIM,
            kind: .videoGeneration,
            title: "wakeup probe",
            runtimeID: runtimeID,
            status: .processing
        )
        #expect(hookTasks.isEmpty)
        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 0)

        registry.update(id: task.id, status: .failed, statusMessage: "boom")
        #expect(hookTasks.count == 1)
        #expect(hookTasks.first?.id == task.id)
        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 1)
        #expect(registry.consumePendingCompletions(forRuntime: runtimeID).count == 1)
        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 0)

        // A second terminal-to-terminal update must not re-queue.
        registry.update(id: task.id, statusMessage: "still failed")
        #expect(hookTasks.count == 1)
        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 0)
    }

    @Test("agent context window recognizes modern large-context models")
    func testAgentContextWindowModernModels() {
        // gpt-5.5 (and -pro) is a ~1M window; only plain gpt-5 stays 400K.
        #expect(AppState.agentContextWindow(model: "gpt-5.5", providerID: "openai") == 1_050_000)
        #expect(AppState.agentContextWindow(model: "gpt-5", providerID: "openai") == 400_000)
        #expect(AppState.agentContextWindow(model: "gpt-4.1", providerID: "openai") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "custom-model", providerID: "custom") == 128_000)
        // deepseek is version-aware: v4 (pro/flash) is a 1M window, the
        // current v3.1/v3.2/reasoner/chat line is 128k, legacy stays 64k.
        #expect(AppState.agentContextWindow(model: "deepseek-v4-pro", providerID: "deepseek") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "deepseek-v4-flash", providerID: "deepseek") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "deepseek-chat", providerID: "deepseek") == 128_000)
        #expect(AppState.agentContextWindow(model: "deepseek-reasoner", providerID: "deepseek") == 128_000)
        #expect(AppState.agentContextWindow(model: "deepseek-coder", providerID: "deepseek") == 64_000)
    }

    @Test("agent configuration routes auto and compression through flash")
    func testAgentConfigurationRoutesAutoAndCompressionThroughFlash() {
        var configuration = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "legacy-model",
            flashModel: "deepseek-chat",
            proModel: "deepseek-reasoner",
            routingMode: .auto,
            apiKey: ""
        ).normalized

        #expect(configuration.model(for: .interactive) == "deepseek-chat")
        #expect(configuration.model(for: .compression) == "deepseek-chat")

        configuration.routingMode = .pro
        #expect(configuration.normalized.model(for: .interactive) == "deepseek-reasoner")
    }

    @Test("agent image description configuration defaults to DashScope vision")
    func testAgentImageDescriptionConfigurationDefaultsToDashScopeVision() {
        let configuration = AgentConfiguration.default.normalized

        #expect(configuration.providerID == "deepseek")
        #expect(configuration.supportsImageInput == false)
        #expect(configuration.imageDescription.providerID == "dashscope")
        #expect(configuration.imageDescription.model == "qwen3-vl-plus")
        #expect(configuration.imageDescription.agentConfiguration.supportsImageInput == true)
        #expect(AgentProviderPreset.preset(id: "deepseek")?.supportsImageInput == false)
        #expect(AgentProviderPreset.preset(id: "dashscope")?.defaultVisionModel == "qwen3-vl-plus")
    }

    @Test("agent token estimate includes tool schemas without exploding short chats")
    func testAgentTokenEstimateIncludesTools() {
        // Keep a narrow ceiling above the current complete registry so this
        // catches accidental schema explosions without rejecting intentional
        // additions to the built-in tool surface. Raised alongside the
        // character-class estimator: tool schemas are symbol- and
        // whitespace-dense, exactly the text the old口径 under-counted, so the
        // same registry now prices ~30% higher without having grown.
        let maximumExpectedToolSchemaTokens = 48_000
        let messages = [AgentMessage(role: .user, content: "hi")]
        let withoutTools = AppState.estimateAgentTokens(messages: messages, tools: [])
        let withTools = AppState.estimateAgentTokens(messages: messages, tools: AgentToolRegistry.all)

        #expect(withTools > withoutTools)
        #expect(withTools < maximumExpectedToolSchemaTokens)
    }

    @Test("agent token estimate bills whitespace and symbol-dense text")
    func testAgentTokenEstimateCharacterClasses() {
        // Prose-like ASCII letters stay at the classic ~4 chars/token.
        #expect(AppState.estimateTextTokens("abcd") == 1)
        // Whitespace is no longer free: indentation and newlines dominate
        // code and terminal output, and pricing them at zero is a large part
        // of why a full 1M window used to read as 54%.
        #expect(AppState.estimateTextTokens("a b\nc\td") == 2)
        #expect(AppState.estimateTextTokens("你\u{3000}好") == 3)

        // Tool-call ids, UUIDs, and paths are symbol-dense; a real tokenizer
        // splits them far more finely than prose of the same length.
        let dense = "call_00_JHrT6ia9tttWsQbHglDu8236"
        let prose = String(repeating: "a", count: dense.count)
        #expect(AppState.estimateTextTokens(dense) > AppState.estimateTextTokens(prose))
    }

    /// The gauge must prefer the provider's own `prompt_tokens` when it is
    /// higher than the local heuristic — the regression that let a session
    /// report 54% while the provider rejected it at 155% of the window.
    @Test("context usage anchors on real provider prompt tokens")
    func testProviderAnchoredUsedTokens() {
        let anchored = AgentMessage(role: .assistant, content: "ok", promptTokens: 900_000)
        let messages = [
            AgentMessage(role: .user, content: "hi"),
            anchored,
            AgentMessage(role: .user, content: "more")
        ]
        let used = AppState.providerAnchoredUsedTokens(
            messages: messages,
            contextSummaryThroughMessageID: nil
        )
        #expect(used != nil)
        // Anchor plus a local estimate of everything appended since.
        #expect((used ?? 0) > 900_000)
        // Nothing but the anchor and two short messages — no runaway.
        #expect((used ?? 0) < 900_100)

        // No real reading at all → caller falls back to the local estimate.
        #expect(
            AppState.providerAnchoredUsedTokens(
                messages: [AgentMessage(role: .user, content: "hi")],
                contextSummaryThroughMessageID: nil
            ) == nil
        )

        // A compression landing at or after the reading invalidates it;
        // otherwise the gauge would stay pinned high and hide the very
        // compression that just freed the window.
        #expect(
            AppState.providerAnchoredUsedTokens(
                messages: messages,
                contextSummaryThroughMessageID: anchored.id
            ) == nil
        )
    }

    @Test("agent tool-round safety limit supports long multi-step work")
    func testAgentToolRoundSafetyLimit() {
        #expect(AppState.maxAgentToolRounds == 256)
    }

    @Test("MCP and skill tools are registered")
    func testMCPAndSkillToolsAreRegistered() {
        #expect(AgentToolRegistry.descriptor(for: "list_skills")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "read_skill")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "list_mcp_servers")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "list_mcp_tools")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "search_mcp_servers")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "call_mcp_tool")?.risk == .write)
    }

    @Test("collapseOldToolResults keeps tool-result bytes stable across later turns")
    func testCollapseOldToolResults() {
        var messages: [AgentMessage] = []
        messages.append(AgentMessage(role: .user, content: "Find foo earlier"))
        for index in 0..<5 {
            messages.append(AgentMessage(role: .assistant, content: "step \(index)"))
            messages.append(AgentMessage(
                role: .tool,
                content: String(repeating: "x", count: 3_000),
                toolCallID: "call_\(index)"
            ))
        }
        messages.append(AgentMessage(role: .user, content: "Now continue from the latest result"))
        messages.append(AgentMessage(role: .assistant, content: "", toolCalls: [
            AgentMessageToolCall(externalID: "call_current", toolName: "read_file", argumentsJSON: "{}")
        ]))
        messages.append(AgentMessage(
            role: .tool,
            content: String(repeating: "y", count: 3_000),
            toolCallID: "call_current"
        ))

        let collapsed = AppState.collapseOldToolResults(in: messages, keepRecentToolMessages: 2)
        let afterAnotherTurn = AppState.collapseOldToolResults(
            in: messages + [AgentMessage(role: .user, content: "One more request")],
            keepRecentToolMessages: 2
        )
        let toolMessages = collapsed.filter { $0.role == .tool }
        let laterToolMessages = afterAnotherTurn.filter { $0.role == .tool }
        #expect(toolMessages.count == 6)

        let summarizedCount = toolMessages.filter {
            $0.content.hasPrefix("[tool result summarized for model context")
        }.count
        #expect(summarizedCount == 6)
        #expect(toolMessages.map(\.content) == laterToolMessages.map(\.content))
    }

    @Test("agent tool runner refuses paths outside the workspace")
    @MainActor
    func testReadFileRefusesEscapedPath() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_sandbox_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        await #expect(throws: AgentToolError.self) {
            try await AgentToolRunner.run(
                name: "read_file",
                arguments: ["path": .string("../../../etc/hosts")],
                context: context
            )
        }
    }
}
