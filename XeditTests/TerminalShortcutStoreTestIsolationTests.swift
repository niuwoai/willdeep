//
//  TerminalShortcutStoreTestIsolationTests.swift
//  WillDeepTests
//
//  The unit-test host is a Debug WillDeep.app with the installed app's bundle
//  id, so until 2026-09-26 `TerminalShortcutStore.directory` resolved to the
//  installed app's real `~/Library/Application Support/WillDeep/
//  terminal-shortcuts` whenever a test had not installed an override. Every
//  test that built the interactive terminal manager loaded the user's
//  `shortcuts.json`, and a save path without the override would have rewritten
//  it together with the protected vault's key and data files. These tests pin
//  down that a test process can no longer reach that folder.
//
//  Every case is synchronous on the main actor and puts back any directory
//  override and fallback file it touches before returning, so suites
//  suspended at an `await` never observe the changes.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct TerminalShortcutStoreTestIsolationTests {
    // Everything the store and the protected vault write into the directory.
    private static let storeFileNames = ["shortcuts.json", "protected-vault.key", "protected-vault.json"]

    private struct FileStamp: Equatable {
        var size: Int?
        var modified: Date?
    }

    /// Size and modification date of the real folder's files. Stat only: the
    /// tests never read or write the user's shortcuts.
    private static func realFolderStamps() -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        for name in storeFileNames {
            let path = TerminalShortcutStore.applicationSupportDirectory.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            stamps[name] = FileStamp(
                size: (attributes[.size] as? NSNumber)?.intValue,
                modified: attributes[.modificationDate] as? Date
            )
        }
        return stamps
    }

    private static func realApplicationSupportPath() throws -> String {
        try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).standardizedFileURL.path
    }

    private static func isInsideRealApplicationSupport(_ url: URL) throws -> Bool {
        let realSupport = try realApplicationSupportPath()
        let path = url.standardizedFileURL.path
        return path == realSupport || path.hasPrefix(realSupport + "/")
    }

    /// Runs `body` with no directory override installed, then puts back the
    /// fallback directory's files and the override that was there before.
    /// Touches no file unless the fallback is outside Application Support, so
    /// a regression fails here instead of snapshotting the user's folder.
    private static func withFallbackDirectory(_ body: (URL) throws -> Void) throws {
        let previous = TerminalShortcutStore._setTestDirectoryOverride(nil)
        // Also drops the vault key cached from the fallback directory.
        defer { TerminalShortcutStore._setTestDirectoryOverride(previous) }
        let fallback = TerminalShortcutStore.directory
        let fallbackIsReal = try isInsideRealApplicationSupport(fallback)
        try #require(!fallbackIsReal)

        let saved = storeFileNames.map { try? Data(contentsOf: fallback.appendingPathComponent($0)) }
        defer {
            for (name, data) in zip(storeFileNames, saved) {
                let url = fallback.appendingPathComponent(name)
                if let data {
                    try? data.write(to: url, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        try body(fallback)
    }

    @Test("with no override installed, the store resolves to a per-process temp directory, never Application Support")
    func directoryFallsBackOutsideApplicationSupport() throws {
        // Path resolution only, no file I/O.
        let previous = TerminalShortcutStore._setTestDirectoryOverride(nil)
        defer { TerminalShortcutStore._setTestDirectoryOverride(previous) }

        let resolved = TerminalShortcutStore.directory.standardizedFileURL
        #expect(AppDefaults.isRunningUnderXCTest)
        let directoryIsReal = try Self.isInsideRealApplicationSupport(resolved)
        let fileIsReal = try Self.isInsideRealApplicationSupport(TerminalShortcutStore.fileURL)
        #expect(!directoryIsReal)
        #expect(!fileIsReal)
        #expect(resolved.path != TerminalShortcutStore.applicationSupportDirectory.standardizedFileURL.path)
        #expect(resolved.lastPathComponent.hasPrefix(TerminalShortcutStore.xctestDirectoryPrefix))
        #expect(resolved.deletingLastPathComponent().path
            == FileManager.default.temporaryDirectory.standardizedFileURL.path)
        // One directory for the whole process, not a fresh one per access.
        #expect(TerminalShortcutStore.directory == TerminalShortcutStore.directory)
    }

    @Test("a save without an override lands in the fallback directory and leaves the real folder alone")
    func saveWithoutOverrideLeavesRealFolderAlone() throws {
        let before = Self.realFolderStamps()
        let password = Array("isolation-fixture-password".utf8)
        let shortcut = TerminalShortcut(
            id: UUID(),
            title: "Isolation fixture",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 1_000,
            events: [
                TerminalShortcutEvent(delayMilliseconds: 0, bytes: Array("ssh user@example.com\n".utf8)),
                TerminalShortcutEvent(
                    delayMilliseconds: 500,
                    bytes: [],
                    requiresEchoOff: true,
                    transientProtectedBytes: password
                ),
            ],
            hasProtectedInput: true
        )

        try Self.withFallbackDirectory { fallback in
            TerminalShortcutStore.save([shortcut])

            for name in Self.storeFileNames {
                #expect(FileManager.default.fileExists(atPath: fallback.appendingPathComponent(name).path))
            }
            let loaded = try #require(TerminalShortcutStore.load().first { $0.id == shortcut.id })
            let protectedEvent = try #require(loaded.events.first { $0.requiresEchoOff })
            #expect(protectedEvent.resolvedBytes() == password)
        }
        #expect(Self.realFolderStamps() == before)
    }
}
