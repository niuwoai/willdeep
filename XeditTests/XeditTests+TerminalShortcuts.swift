//
//  XeditTests+TerminalShortcuts.swift
//  WillDeepTests
//
//  Terminal shortcut recording/persistence and terminal tool routing, split
//  out of XeditTests.swift when that file crossed the 3000-line hard limit
//  enforced by scripts/complexity_guard.rb.
//
//  Deliberately an `extension` on the same suite type rather than a new
//  `@Suite`: the tests keep their `XeditTests/WillDeepTests/<name>()`
//  identifiers, so `-only-testing` filters and the suite's `.serialized`
//  trait carry over unchanged.
//

import Testing
import Foundation
@testable import WillDeep

extension WillDeepTests {
    @Test("Agent terminal mutations stay visible and saved shortcut playback stays user-only")
    func testAgentTerminalAutomationBoundary() async throws {
        for toolName in [
            "terminal_send_command",
            "terminal_send_control",
            "terminal_select_tab",
            "terminal_create_shortcut",
            "terminal_edit_shortcut",
        ] {
            #expect(AgentTerminalAutomationPolicy.requiresVisiblePanel(toolName: toolName))
        }
        for toolName in [
            "terminal_snapshot",
            "terminal_list_tabs",
            "terminal_list_shortcuts",
        ] {
            #expect(!AgentTerminalAutomationPolicy.requiresVisiblePanel(toolName: toolName))
        }

        for forbiddenName in [
            "terminal_play_shortcut",
            "terminal_replay_shortcut",
            "terminal_run_shortcut",
        ] {
            #expect(AgentTerminalAutomationPolicy.forbidsShortcutReplay(toolName: forbiddenName))
            #expect(AgentToolRegistry.descriptor(for: forbiddenName) == nil)
            await #expect(throws: AgentToolError.self) {
                _ = try await AgentToolRunner.run(
                    name: forbiddenName,
                    arguments: [:],
                    context: AgentToolContext(rootDirectory: nil)
                )
            }
        }

        let listDescriptor = try #require(
            AgentToolRegistry.descriptor(for: "terminal_list_shortcuts")
        )
        #expect(listDescriptor.description.contains("user-run only"))
        #expect(listDescriptor.description.contains("press Run"))
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
    @Test("stale terminal controller cannot overwrite a saved shortcut edit")
    func testStaleTerminalControllerRefreshesBeforePreparingEditFile() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-stale-controller-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let shortcutID = UUID()
        let original = TerminalShortcut(
            id: shortcutID,
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [TerminalShortcutEvent(delayMilliseconds: 0, bytes: Array("pwd\n".utf8))],
            hasProtectedInput: false
        )
        TerminalShortcutStore.save([original])

        // Mirrors the retained Agent/headless AppState and the Editor window:
        // both controllers start from the same snapshot, then only the Editor
        // controller observes and persists the user's saved JSON edit.
        let staleAgentController = AgentInteractiveTerminalController()
        let editorController = AgentInteractiveTerminalController()
        let editURL = try #require(editorController.prepareShortcutFileForEditing(id: shortcutID))
        let originalJSON = try String(contentsOf: editURL, encoding: .utf8)
        let editedJSON = originalJSON.replacingOccurrences(of: "\"Before\"", with: "\"After\"")
        try editedJSON.write(to: editURL, atomically: true, encoding: .utf8)
        #expect(editorController.reloadShortcutFromEditFile(id: shortcutID, url: editURL))
        #expect(staleAgentController.shortcuts.first?.title == "Before")
        #expect(TerminalShortcutStore.load().first?.title == "After")

        // Reopening from the stale Agent controller must use the canonical
        // store instead of writing its old in-memory value back to the file.
        let reopenedURL = try #require(staleAgentController.prepareShortcutFileForEditing(id: shortcutID))
        let reopenedJSON = try String(contentsOf: reopenedURL, encoding: .utf8)
        #expect(reopenedJSON.contains("After"))
        #expect(!reopenedJSON.contains("Before"))
        #expect(staleAgentController.shortcuts.first?.title == "After")
    }

    @MainActor
    @Test("terminal shortcut native editor saves JSON and protected values without plaintext persistence")
    func testTerminalShortcutNativeEditorSavesJSONAndProtectedValues() throws {
        let shortcutsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-shortcut-native-editor-\(UUID().uuidString)", isDirectory: true)
        TerminalShortcutStore._setTestDirectoryOverride(shortcutsDirectory)
        defer {
            TerminalShortcutStore._setTestDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: shortcutsDirectory)
        }

        let shortcutID = UUID()
        let eventID = UUID()
        let account = TerminalShortcutStore.protectedInputAccount(shortcutID: shortcutID, eventID: eventID)
        let shortcut = TerminalShortcut(
            id: shortcutID,
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [
                TerminalShortcutEvent(
                    id: eventID,
                    delayMilliseconds: 0,
                    bytes: [],
                    requiresEchoOff: true,
                    protectedBytesReference: account,
                    protectedPlaceholder: "SSH password"
                ),
                TerminalShortcutEvent(delayMilliseconds: 0, bytes: [13])
            ],
            hasProtectedInput: true
        )
        TerminalShortcutStore.save([shortcut])

        let controller = AgentInteractiveTerminalController()
        let source = try TerminalShortcutStore.editableJSON(for: shortcut)
        let edited = source.replacingOccurrences(of: "\"Before\"", with: "\"After\"")
        let secret = "native-editor-secret"
        try controller.saveShortcutEdit(
            id: shortcutID,
            json: edited,
            protectedValues: [eventID: secret]
        )

        #expect(TerminalShortcutStore.load().first?.title == "After")
        #expect(controller.shortcuts.first?.title == "After")
        #expect(TerminalShortcutProtectedVault.load(account: account) == Array(secret.utf8))
        let persistedJSON = try String(contentsOf: TerminalShortcutStore.fileURL, encoding: .utf8)
        #expect(!persistedJSON.contains(secret))
        #expect(TerminalShortcutStore.load().first?.events.first?.protectedBytesReference == account)
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
    @Test("closing the active SSH tab blocks implicit fallback to a local shell")
    func testClosingActiveSSHTabBlocksImplicitLocalFallback() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        let local = controller.openLocalTab(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        let ssh = controller.openSSHTab(
            runtime: RuntimeDescriptor(
                displayName: "Test SSH",
                host: "127.0.0.1",
                username: "nobody",
                defaultWorkspacePath: "/tmp"
            ),
            originAgentSessionID: sessionID,
            settings: settings,
            skin: nil
        )
        defer { controller.closeTab(id: local.id) }

        #expect(controller.activeTabID == ssh.id)
        controller.closeTab(id: ssh.id)
        #expect(controller.activeTabID == local.id)

        do {
            _ = try controller.sendApprovedCommand(
                "echo should-not-run-locally",
                sessionID: sessionID
            )
            Issue.record("expected a closed SSH route to block implicit local fallback")
        } catch let error as AgentToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("previously active SSH terminal"))
            #expect(message.contains("did not fall back to a local shell"))
            #expect(message.contains("Nothing was executed"))
        }
        #expect(controller.tabs.count == 1)
        #expect(local.recentCommands.isEmpty)

        _ = try controller.selectTab(id: local.id)
        #expect(try controller.rawSnapshot(sessionID: sessionID).tabID == local.id)
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
        // The login shell's rc files run as foreground children of this pty,
        // and dispatch is (correctly) refused while they do. Wait for the
        // prompt instead of a fixed sleep — under a full-load run the startup
        // easily outlives any constant.
        let readyState = await AgentTerminalTestSupport.waitForShellReady(tab)
        #expect(readyState == .shellReady, "login shell never reached its prompt: \(readyState.rawValue)")

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
        // 回执已写明命令，跟随快照不再重复「最近命令」和固定规则说明。
        #expect(!result.payload.contains("Recent AI/auto commands"))
        #expect(!result.payload.contains("Terminal context rules"))
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
}
