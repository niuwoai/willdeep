//
//  XeditTests.swift
//  WillDeepTests
//
//  Created by rocky on 2026/5/27.
//

import Testing
import Foundation
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
    @Test("goal running status bar only shows during an active goal turn")
    func testGoalRunningStatusBarVisibility() {
        let appState = AppState()
        appState.startNewAgentSession()

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
        appState.startNewAgentSession()
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
        appState.startNewAgentSession()
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
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
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
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
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

        // 首个正文 token 到达 → 指示器整体消失，预览跟着消失
        appState.agentMessages[1].content = "好的"
        #expect(appState.agentLiveThinkingPreview == nil)

        // turn 结束后即使 reasoning 还挂在消息上也不再预览
        appState.agentMessages[1].content = ""
        appState.isAgentResponding = false
        #expect(appState.agentLiveThinkingPreview == nil)
    }

    @Test("thinking preview tail collapses whitespace and keeps the newest characters")
    func testAgentThinkingPreviewTail() {
        // 短文本原样返回，只折叠换行
        #expect(AppState.agentThinkingPreviewTail("第一步\n第二步") == "第一步 第二步")

        // 超长 trace 截尾：保留最新内容，前置省略号
        let long = (1...100).map { "片段\($0)" }.joined(separator: "\n")
        let tail = AppState.agentThinkingPreviewTail(long)
        #expect(tail.hasPrefix("…"))
        #expect(tail.hasSuffix("片段100"))
        #expect(tail.count <= 161)
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
        #expect(modelHistory.first?.role == .system)
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
        #expect(descriptor?.parameters.contains(where: { $0.name == "model" }) == true)
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
        // autoApproveSafeCommands 的 didSet 会写 UserDefaults——沙箱化,
        // 防止测试翻转开发机上的真实设置。
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        appState.autoApproveSafeCommands = true
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

        // 主开关关掉 → 一切回到人工。
        appState.autoApproveSafeCommands = false
        let gated = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("github"),
                "tool": .string("list_issues"),
            ],
            risk: .write,
            rootDirectory: root
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

    @Test("goal mode auto-approves write tools but never danger tier")
    @MainActor
    func testGoalModeAutoApproval() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        // write 层 + goal 模式 → 自动放行，来源标记为 goalMode。
        let writeApproval = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("swift build")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal,
            approvalMode: .requestEveryTime
        )
        #expect(writeApproval == .goalMode)

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

        // normal 模式不受影响：没有命中其他自动路径时仍等用户。
        let normalApproval = await appState.autoApprovalSource(
            toolName: "claude_code",
            arguments: ["prompt": .string("do x")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .normal
        )
        #expect(normalApproval == nil)
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

    @Test("approval mode controls write-tier auto approval")
    @MainActor
    func testApprovalModeControlsWriteTierAutoApproval() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        appState.autoApproveSafeCommands = true
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        let askEveryTime = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("ls")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .requestEveryTime
        )
        #expect(askEveryTime == nil)

        let smart = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("ls")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .smart
        )
        #expect(smart == .staticAllowlist)

        let workspace = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("swift test")],
            risk: .write,
            rootDirectory: root,
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
            rootDirectory: root,
            approvalMode: .workspaceAccess
        )
        #expect(untrustedMCP == nil)

        let goBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("go build -o bin/app . 2>&1")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .smart
        )
        #expect(goBuild == .staticAllowlist)

        let yarnBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("yarn run build")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .smart
        )
        #expect(yarnBuild == .staticAllowlist)

        let heredocGeneration = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("""
            cd /tmp/willdeep-test-workspace && python3 << 'PYEOF'
            from pathlib import Path
            Path("Generated.swift").write_text("let value = 1\\n")
            PYEOF
            """)],
            risk: .write,
            rootDirectory: root,
            approvalMode: .smart
        )
        #expect(heredocGeneration == .staticAllowlist)

        let outsideWorkspaceGeneration = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("""
            cd /tmp/willdeep-test-workspace && cat > /tmp/outside.txt << 'EOF'
            generated
            EOF
            """)],
            risk: .write,
            rootDirectory: root,
            approvalMode: .smart
        )
        #expect(outsideWorkspaceGeneration == nil)
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

    @Test("external agent executable discovery and local catalog expose direct tools")
    func testExternalAgentDiscovery() {
        let codex = AgentToolRunner.codexCLIExecutablePath(
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }
        )
        #expect(codex == "/Applications/Codex.app/Contents/Resources/codex")

        let cursor = AgentToolRunner.cursorAgentExecutablePath(
            environment: ["PATH": "/usr/local/bin"],
            isExecutable: { $0 == "/usr/local/bin/cursor" }
        )
        #expect(cursor == "/usr/local/bin/cursor")

        let cline = AgentToolRunner.clineCLIExecutablePath(
            environment: ["PATH": "/usr/local/bin"],
            isExecutable: { $0 == "/usr/local/bin/cline" }
        )
        #expect(cline == "/usr/local/bin/cline")

        let entries = LocalAgentCLI.catalog
        #expect(entries.first(where: { $0.id == "codex-cli" })?.integration == .directTool("codex_cli"))
        #expect(entries.first(where: { $0.id == "cursor-cli" })?.integration == .directTool("cursor_agent"))
        #expect(entries.first(where: { $0.id == "cline-cli" })?.integration == .directTool("cline_cli"))
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
        let messages = [AgentMessage(role: .user, content: "hi")]
        let withoutTools = AppState.estimateAgentTokens(messages: messages, tools: [])
        let withTools = AppState.estimateAgentTokens(messages: messages, tools: AgentToolRegistry.all)

        #expect(withTools > withoutTools)
        #expect(withTools < 30_000)
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

    @Test("collapseOldToolResults protects current-round tool messages and summarizes older tool payloads")
    func testCollapseOldToolResults() {
        var messages: [AgentMessage] = []
        messages.append(AgentMessage(role: .user, content: "Find foo earlier"))
        for index in 0..<5 {
            messages.append(AgentMessage(role: .assistant, content: "step \(index)"))
            messages.append(AgentMessage(
                role: .tool,
                content: String(repeating: "x", count: 500),
                toolCallID: "call_\(index)"
            ))
        }
        messages.append(AgentMessage(role: .user, content: "Now continue from the latest result"))
        messages.append(AgentMessage(role: .assistant, content: "", toolCalls: [
            AgentMessageToolCall(externalID: "call_current", toolName: "read_file", argumentsJSON: "{}")
        ]))
        messages.append(AgentMessage(
            role: .tool,
            content: String(repeating: "y", count: 500),
            toolCallID: "call_current"
        ))

        let collapsed = AppState.collapseOldToolResults(in: messages, keepRecentToolMessages: 2)
        let toolMessages = collapsed.filter { $0.role == .tool }
        #expect(toolMessages.count == 6)

        let summarizedCount = toolMessages.filter {
            $0.content.hasPrefix("[tool result summarized for model context")
        }.count
        #expect(summarizedCount == 3)

        // The latest two old tool messages plus the current-round tool
        // result should remain at full length.
        let untouched = toolMessages.suffix(3)
        for message in untouched {
            #expect(message.content.count == 500)
        }
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
