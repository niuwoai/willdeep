//
//  AgentTerminalShortcuts.swift
//  WillDeep
//
//  Split out of AgentInteractiveTerminal.swift to keep files under the
//  repository size limit. The terminal-shortcut subsystem is self-contained:
//  the escaped-text codec, recorded events and shortcuts, the recorder,
//  on-disk store, and the Keychain-backed vault for protected bytes.
//

import CryptoKit
import Foundation
import Security

enum TerminalShortcutTextCodec {
    static func escapedText(from bytes: [UInt8]) -> String {
        var result = ""
        var plainBytes: [UInt8] = []

        func flushPlainBytes() {
            guard !plainBytes.isEmpty else { return }
            result += String(decoding: plainBytes, as: UTF8.self)
            plainBytes.removeAll(keepingCapacity: true)
        }

        for byte in bytes {
            switch byte {
            case 0x5C:
                flushPlainBytes()
                result += "\\\\"
            case 0x0A:
                flushPlainBytes()
                result += "\\n"
            case 0x0D:
                flushPlainBytes()
                result += "\\r"
            case 0x09:
                flushPlainBytes()
                result += "\\t"
            case 0x1B:
                flushPlainBytes()
                result += "\\e"
            case 0x7F:
                flushPlainBytes()
                result += "\\b"
            case 0x00...0x1F:
                flushPlainBytes()
                result += String(format: "\\x%02X", byte)
            default:
                plainBytes.append(byte)
            }
        }
        flushPlainBytes()
        return result
    }

    static func bytes(fromEscapedText text: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\u{0008}" {
                result.append(0x7F)
                index = text.index(after: index)
                continue
            }
            guard character == "\\" else {
                result.append(contentsOf: String(character).utf8)
                index = text.index(after: index)
                continue
            }

            let escapeStart = index
            index = text.index(after: index)
            guard index < text.endIndex else {
                result.append(0x5C)
                break
            }

            let escaped = text[index]
            switch escaped {
            case "\\":
                result.append(0x5C)
                index = text.index(after: index)
            case "n":
                result.append(0x0A)
                index = text.index(after: index)
            case "r":
                result.append(0x0D)
                index = text.index(after: index)
            case "t":
                result.append(0x09)
                index = text.index(after: index)
            case "e", "E":
                result.append(0x1B)
                index = text.index(after: index)
            case "b":
                result.append(0x7F)
                index = text.index(after: index)
            case "x":
                if let byte = hexByte(in: text, after: index) {
                    result.append(byte.value)
                    index = byte.nextIndex
                } else {
                    result.append(contentsOf: String(text[escapeStart...index]).utf8)
                    index = text.index(after: index)
                }
            default:
                result.append(0x5C)
                result.append(contentsOf: String(escaped).utf8)
                index = text.index(after: index)
            }
        }

        return result
    }

    private static func hexByte(in text: String, after escapeIndex: String.Index) -> (value: UInt8, nextIndex: String.Index)? {
        let firstIndex = text.index(after: escapeIndex)
        guard firstIndex < text.endIndex else { return nil }
        let secondIndex = text.index(after: firstIndex)
        guard secondIndex < text.endIndex else { return nil }
        let hex = String(text[firstIndex...secondIndex])
        guard let value = UInt8(hex, radix: 16) else { return nil }
        return (value, text.index(after: secondIndex))
    }
}

struct TerminalShortcutEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var delayMilliseconds: Int
    var bytes: [UInt8]
    var requiresEchoOff: Bool
    var protectedBytesReference: String?
    var protectedPlaceholder: String?
    var transientProtectedBytes: [UInt8]

    init(
        id: UUID = UUID(),
        delayMilliseconds: Int,
        bytes: [UInt8],
        requiresEchoOff: Bool = false,
        protectedBytesReference: String? = nil,
        protectedPlaceholder: String? = nil,
        transientProtectedBytes: [UInt8] = []
    ) {
        self.id = id
        self.delayMilliseconds = max(0, delayMilliseconds)
        self.requiresEchoOff = requiresEchoOff
        self.bytes = requiresEchoOff ? [] : bytes
        self.protectedBytesReference = protectedBytesReference
        let trimmedPlaceholder = protectedPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.protectedPlaceholder = trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder
        self.transientProtectedBytes = requiresEchoOff ? transientProtectedBytes : []
    }

    enum CodingKeys: String, CodingKey {
        case id, delayMilliseconds, text, bytes, requiresEchoOff, protectedBytesReference, protectedPlaceholder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        delayMilliseconds = try container.decode(Int.self, forKey: .delayMilliseconds)
        requiresEchoOff = try container.decodeIfPresent(Bool.self, forKey: .requiresEchoOff) ?? false
        if requiresEchoOff {
            bytes = []
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            bytes = TerminalShortcutTextCodec.bytes(fromEscapedText: text)
        } else {
            bytes = try container.decodeIfPresent([UInt8].self, forKey: .bytes) ?? []
        }
        protectedBytesReference = try container.decodeIfPresent(String.self, forKey: .protectedBytesReference)
        protectedPlaceholder = try container.decodeIfPresent(String.self, forKey: .protectedPlaceholder)
        transientProtectedBytes = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(delayMilliseconds, forKey: .delayMilliseconds)
        try container.encode(requiresEchoOff, forKey: .requiresEchoOff)
        if requiresEchoOff {
            try container.encode([UInt8](), forKey: .bytes)
        } else {
            try container.encode(TerminalShortcutTextCodec.escapedText(from: bytes), forKey: .text)
        }
        try container.encodeIfPresent(protectedBytesReference, forKey: .protectedBytesReference)
        try container.encodeIfPresent(protectedPlaceholder, forKey: .protectedPlaceholder)
    }

    var isPlayable: Bool {
        if requiresEchoOff {
            return !transientProtectedBytes.isEmpty ||
                protectedBytesReference?.isEmpty == false ||
                protectedPlaceholder?.isEmpty == false
        }
        return !bytes.isEmpty
    }

    var needsProtectedInputValue: Bool {
        guard requiresEchoOff else { return false }
        if !transientProtectedBytes.isEmpty { return false }
        guard let protectedBytesReference, !protectedBytesReference.isEmpty else { return true }
        return TerminalShortcutProtectedVault.load(account: protectedBytesReference) == nil
    }

    func resolvedBytes() -> [UInt8] {
        var cache: [String: [UInt8]] = [:]
        return resolvedBytes(cache: &cache)
    }

    func resolvedBytes(cache: inout [String: [UInt8]]) -> [UInt8] {
        guard requiresEchoOff else { return bytes }
        if !transientProtectedBytes.isEmpty { return transientProtectedBytes }
        guard let protectedBytesReference,
              !protectedBytesReference.isEmpty else { return [] }
        if let cached = cache[protectedBytesReference] {
            return cached
        }
        if let resolved = TerminalShortcutProtectedVault.load(account: protectedBytesReference) {
            cache[protectedBytesReference] = resolved
            return resolved
        }
        let encoded = AgentCredentialStore.load(account: protectedBytesReference)
        guard let data = Data(base64Encoded: encoded) else { return [] }
        let resolved = Array(data)
        TerminalShortcutProtectedVault.save(resolved, account: protectedBytesReference)
        cache[protectedBytesReference] = resolved
        return resolved
    }
}

struct TerminalShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationMilliseconds: Int
    var events: [TerminalShortcutEvent]
    var hasProtectedInput: Bool

    var eventCount: Int { events.count }
    var isPlayable: Bool { !events.isEmpty }
    var pendingProtectedInputCount: Int {
        events.filter(\.needsProtectedInputValue).count
    }
    var hasPendingProtectedInput: Bool {
        pendingProtectedInputCount > 0
    }
    var playbackDurationMilliseconds: Int {
        events.reduce(0) { partial, event in
            partial + max(0, event.delayMilliseconds)
        }
    }

    var normalized: TerminalShortcut {
        var copy = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = trimmed.isEmpty ? "Terminal Shortcut" : String(trimmed.prefix(80))
        copy.durationMilliseconds = max(0, durationMilliseconds)
        copy.events = events.filter(\.isPlayable)
        return copy
    }
}

struct TerminalShortcutEditOperation: Equatable {
    enum Kind: String {
        case setDelay = "set_delay"
        case deleteEvent = "delete_event"
        case replaceVisibleText = "replace_visible_text"
        case setVisibleText = "set_visible_text"
        case deleteVisibleText = "delete_visible_text"
    }

    var kind: Kind
    var eventIndex: Int
    var delayMilliseconds: Int?
    var text: String?
    var find: String?
    var replacement: String?
}

struct TerminalShortcutCreateEvent: Equatable {
    enum Kind: String {
        case command
        case text
        case control
        case protectedPlaceholder = "protected_placeholder"
    }

    var kind: Kind
    var delayMilliseconds: Int
    var value: String
}

struct TerminalShortcutPlaybackState: Equatable {
    enum Status: Equatable {
        case running
        case finished
        case cancelled(reason: String)
    }

    var shortcutID: UUID
    var title: String
    var currentEventIndex: Int
    var totalEvents: Int
    var startedAt: Date
    var estimatedFinishedAt: Date
    var totalDelayMilliseconds: Int
    var status: Status

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func elapsedMilliseconds(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt) * 1000))
    }

    func remainingMilliseconds(now: Date) -> Int {
        guard isRunning else { return 0 }
        return max(0, Int(estimatedFinishedAt.timeIntervalSince(now) * 1000))
    }
}

final class TerminalShortcutRecorder {
    private let startedAt: Date
    private var lastRecordedInputAt: Date
    private(set) var events: [TerminalShortcutEvent] = []
    private(set) var hasProtectedInput = false
    private var totalRecordedBytes = 0

    private let maxEvents = 4_000
    private let maxRecordedBytes = 64 * 1024

    /// Buffer of consecutive echo-off (protected) keystrokes that have not yet
    /// been finalized into an event. A password prompt hides every character, so
    /// each keystroke arrives as its own `record` call; we coalesce them here and
    /// only emit a single protected event once the user presses Enter (or echo is
    /// restored). This keeps "one password = one protected input" instead of one
    /// per character.
    private var pendingProtectedBytes: [UInt8] = []
    private var pendingProtectedStartedAt: Date?
    /// Where the pending echo-off line began on screen; nil when unknown.
    private var pendingLineAnchor: TerminalShortcutLineAnchor?
    /// An echo-off line whose Enter reached the shell, held until the screen
    /// shows whether it ran and what it said. Shell line editors turn ECHO
    /// off too, so this is how a typed command (and whatever Tab completed
    /// it to) is told apart from a password.
    private var pendingSubmission: PendingSubmission?

    private struct PendingSubmission {
        var bytes: [UInt8]
        var startedAt: Date
        var terminator: UInt8
        var submittedAt: Date
        var anchor: TerminalShortcutLineAnchor
        var capture: TerminalShortcutLineCapture
    }

    var isAwaitingSubmittedLine: Bool { pendingSubmission != nil }

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.lastRecordedInputAt = startedAt
    }

    /// - Parameter screen: the visible grid *before* `data` reaches the
    ///   process, so it shows the effect of every earlier keystroke.
    func record(
        data: [UInt8],
        echoEnabled: Bool,
        now: Date = Date(),
        screen: TerminalShortcutScreen? = nil
    ) {
        guard !data.isEmpty else { return }
        settlePendingSubmission(screen: screen, isFinal: true)

        if echoEnabled {
            // Echo is back on: any password line in progress is complete.
            flushPendingProtectedInput(now: now)
            appendEvent(bytes: data, echoEnabled: true, now: now)
            return
        }

        // Echo off => protected input unless the screen later proves
        // otherwise. Accumulate keystrokes, and treat Enter (CR/LF) as the
        // line terminator that finalizes one event.
        let isLoneEnter = data.count == 1
        for (offset, byte) in data.enumerated() {
            if byte == 0x0D || byte == 0x0A {
                if isLoneEnter, beginSubmission(terminator: byte, now: now, screen: screen) {
                    continue
                }
                flushPendingProtectedInput(now: now)
                // The Enter keypress itself is not a secret; record it as a
                // normal event so replay still submits the password line.
                appendEvent(bytes: [byte], echoEnabled: true, now: now)
            } else if totalRecordedBytes + heldBytesCount < maxRecordedBytes {
                if pendingProtectedBytes.isEmpty {
                    pendingProtectedStartedAt = now
                    // Later bytes of a chunk are not on the pre-chunk screen.
                    pendingLineAnchor = offset == 0 ? screen.flatMap { TerminalShortcutLineAnchor(screen: $0) } : nil
                }
                pendingProtectedBytes.append(byte)
            }
        }
    }

    /// New output reached the screen. Settles a submitted line as soon as the
    /// shell has moved past it and repainted it without any autosuggestion.
    func screenDidUpdate(_ screen: TerminalShortcutScreen) {
        settlePendingSubmission(screen: screen, isFinal: false)
    }

    private var heldBytesCount: Int {
        pendingProtectedBytes.count + (pendingSubmission.map { $0.bytes.count + 1 } ?? 0)
    }

    private func beginSubmission(terminator: UInt8, now: Date, screen: TerminalShortcutScreen?) -> Bool {
        guard !pendingProtectedBytes.isEmpty,
              let anchor = pendingLineAnchor,
              let screen,
              let capture = TerminalShortcutLineResolver.capture(anchor: anchor, screen: screen) else {
            return false
        }
        pendingSubmission = PendingSubmission(
            bytes: pendingProtectedBytes,
            startedAt: pendingProtectedStartedAt ?? now,
            terminator: terminator,
            submittedAt: now,
            anchor: anchor,
            capture: capture
        )
        pendingProtectedBytes.removeAll(keepingCapacity: true)
        pendingProtectedStartedAt = nil
        pendingLineAnchor = nil
        return true
    }

    /// - Parameter isFinal: the next keystroke or the end of recording; the
    ///   screen will not get a better chance to show what happened.
    private func settlePendingSubmission(screen: TerminalShortcutScreen?, isFinal: Bool) {
        guard let submission = pendingSubmission else { return }
        let settlement = screen.map {
            TerminalShortcutLineResolver.settle(anchor: submission.anchor, capture: submission.capture, screen: $0)
        } ?? .unverifiable
        let typed = TerminalShortcutTypedLine(bytes: submission.bytes)
        let verifiedComplete: Bool?
        switch settlement {
        case .stillEditing:
            guard isFinal else { return }
            if typed.mayOpenPager {
                // Enter picked a completion from the pager instead of running
                // the line; keep editing it as one line.
                pendingSubmission = nil
                pendingProtectedBytes = submission.bytes + [submission.terminator]
                pendingProtectedStartedAt = submission.startedAt
                pendingLineAnchor = submission.anchor
                return
            }
            verifiedComplete = nil
        case .submitted(let restIsClean):
            verifiedComplete = restIsClean
        case .unverifiable:
            verifiedComplete = nil
        }
        pendingSubmission = nil
        let resolved = TerminalShortcutLineResolver.resolvedText(
            typed: typed,
            capture: submission.capture,
            verifiedComplete: verifiedComplete
        )
        appendLine(
            bytes: submission.bytes,
            resolvedText: resolved,
            startedAt: submission.startedAt,
            endedAt: submission.submittedAt
        )
        appendEvent(bytes: [submission.terminator], echoEnabled: true, now: submission.submittedAt)
    }

    /// Finalize the buffered keystrokes into a single event. With a screen
    /// (end of recording, line never submitted) the displayed text replaces
    /// the keystrokes when it provably is the whole line.
    private func flushPendingProtectedInput(now: Date, screen: TerminalShortcutScreen? = nil) {
        defer {
            pendingProtectedBytes.removeAll(keepingCapacity: true)
            pendingProtectedStartedAt = nil
            pendingLineAnchor = nil
        }
        guard !pendingProtectedBytes.isEmpty else { return }
        var resolved: String?
        if let screen,
           let anchor = pendingLineAnchor,
           let capture = TerminalShortcutLineResolver.capture(anchor: anchor, screen: screen) {
            resolved = TerminalShortcutLineResolver.resolvedText(
                typed: TerminalShortcutTypedLine(bytes: pendingProtectedBytes),
                capture: capture,
                verifiedComplete: capture.tailIsClean
            )
        }
        appendLine(
            bytes: pendingProtectedBytes,
            resolvedText: resolved,
            startedAt: pendingProtectedStartedAt ?? now,
            endedAt: now
        )
    }

    /// One echo-off line: the text the screen proved, or the raw keystrokes
    /// kept protected.
    private func appendLine(bytes: [UInt8], resolvedText: String?, startedAt: Date, endedAt: Date) {
        if let resolvedText {
            appendEvent(bytes: Array(resolvedText.utf8), echoEnabled: true, now: startedAt, anchor: endedAt)
        } else {
            appendEvent(bytes: bytes, echoEnabled: false, now: startedAt, anchor: endedAt)
        }
    }

    /// Appends one recorded event, honoring the event/byte budgets.
    /// - Parameters:
    ///   - now: reference time used to compute this event's leading delay.
    ///   - anchor: time to advance the "last input" cursor to (defaults to `now`);
    ///     for a coalesced protected line this is the moment Enter was pressed so
    ///     the following event's delay does not absorb the typing duration.
    private func appendEvent(bytes rawBytes: [UInt8], echoEnabled: Bool, now: Date, anchor: Date? = nil) {
        guard !rawBytes.isEmpty else { return }
        guard events.count < maxEvents, totalRecordedBytes < maxRecordedBytes else { return }

        let remainingBytes = maxRecordedBytes - totalRecordedBytes
        let safeBytes = Array(rawBytes.prefix(remainingBytes))
        guard !safeBytes.isEmpty else { return }

        let delay = max(0, Int(now.timeIntervalSince(lastRecordedInputAt) * 1000))
        if !echoEnabled {
            hasProtectedInput = true
        }
        events.append(
            TerminalShortcutEvent(
                delayMilliseconds: min(delay, 300_000),
                bytes: echoEnabled ? safeBytes : [],
                requiresEchoOff: !echoEnabled,
                transientProtectedBytes: echoEnabled ? [] : safeBytes
            )
        )
        totalRecordedBytes += safeBytes.count
        lastRecordedInputAt = anchor ?? now
    }

    func finish(
        title: String,
        id: UUID = UUID(),
        finishedAt: Date = Date(),
        screen: TerminalShortcutScreen? = nil
    ) -> TerminalShortcut? {
        settlePendingSubmission(screen: screen, isFinal: true)
        // Flush a line the user never submitted (e.g. recording stopped
        // mid-prompt) so it is not silently dropped.
        flushPendingProtectedInput(now: finishedAt, screen: screen)
        guard !events.isEmpty else { return nil }
        return TerminalShortcut(
            id: id,
            title: title,
            createdAt: startedAt,
            updatedAt: finishedAt,
            durationMilliseconds: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000)),
            events: events,
            hasProtectedInput: hasProtectedInput
        ).normalized
    }
}

enum TerminalShortcutStore {
    /// Where builds before the file store kept shortcuts; `load()` still
    /// migrates it.
    nonisolated static let key = "com.willdeep.terminalShortcuts.v1"
    private static let maxShortcuts = 24
    private static let fileName = "shortcuts.json"
    private static let editableDirectoryName = "editable"
    private static var directoryOverride: URL?

    #if DEBUG
    /// Directory-name prefix of the throwaway directory below.
    nonisolated static let xctestDirectoryPrefix = "willdeep-tests-terminal-shortcuts-"

    /// The unit-test host is a Debug WillDeep.app with the installed app's
    /// bundle id, so without an override `directory` is the installed app's
    /// real shortcuts folder. Every test that builds the interactive terminal
    /// manager loaded the user's `shortcuts.json` from there, and any save
    /// path that skipped `_setTestDirectoryOverride` would rewrite it, along
    /// with the protected vault's key and data files beside it. So under
    /// XCTest the store falls back to one throwaway directory per process,
    /// whether or not a test opted in. The legacy defaults key already goes
    /// through `AppDefaults.standard`; this is the file half.
    private static let xctestFallbackDirectory: URL? = {
        guard AppDefaults.isRunningUnderXCTest else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(xctestDirectoryPrefix + UUID().uuidString, isDirectory: true)
    }()
    #endif

    /// Where the shipping app keeps shortcuts and the protected vault.
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("terminal-shortcuts", isDirectory: true)
    }

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        #if DEBUG
        if let xctestFallbackDirectory { return xctestFallbackDirectory }
        #endif
        return applicationSupportDirectory
    }

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    private static var editableDirectory: URL {
        directory.appendingPathComponent(editableDirectoryName, isDirectory: true)
    }

    static func editableFileURL(for shortcutID: UUID) -> URL {
        editableDirectory.appendingPathComponent("\(shortcutID.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> [TerminalShortcut] {
        if let shortcuts = loadFromDisk() {
            return normalized(shortcuts)
        }
        let legacyShortcuts = loadFromUserDefaults()
        if !legacyShortcuts.isEmpty {
            save(legacyShortcuts)
        }
        return normalized(legacyShortcuts)
    }

    static func save(_ shortcuts: [TerminalShortcut]) {
        let prepared = normalized(shortcuts).map { prepareForPersistence($0) }
        do {
            try ensureDirectory()
            let data = try encoder.encode(prepared)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("TerminalShortcutStore: failed to save shortcuts: \(error)")
        }
    }

    static func loadEditableShortcuts() throws -> [TerminalShortcut] {
        let data = try Data(contentsOf: fileURL)
        return normalized(try decoder.decode([TerminalShortcut].self, from: data))
    }

    static func editableJSON(for shortcut: TerminalShortcut) throws -> String {
        let data = try encoder.encode(prepareForPersistence(shortcut))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }

    static func decodeEditableShortcut(_ text: String, expectedID: UUID) throws -> TerminalShortcut {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        var shortcut = try decoder.decode(TerminalShortcut.self, from: data).normalized
        guard shortcut.id == expectedID, shortcut.isPlayable else {
            throw CocoaError(.fileReadCorruptFile)
        }
        shortcut.hasProtectedInput = shortcut.events.contains(where: \.requiresEchoOff)
        return shortcut
    }

    @discardableResult
    static func prepareEditableFile(for shortcut: TerminalShortcut) throws -> URL {
        try ensureDirectory(editableDirectory)
        let url = editableFileURL(for: shortcut.id)
        let data = try encoder.encode(prepareForPersistence(shortcut))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func loadEditableShortcut(from url: URL, expectedID: UUID) throws -> TerminalShortcut {
        guard editableShortcutID(for: url) == expectedID else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let data = try Data(contentsOf: url)
        var shortcut = try decoder.decode(TerminalShortcut.self, from: data).normalized
        guard shortcut.id == expectedID, shortcut.isPlayable else {
            throw CocoaError(.fileReadCorruptFile)
        }
        shortcut.hasProtectedInput = shortcut.events.contains(where: \.requiresEchoOff)
        return shortcut
    }

    static func protectedInputAccount(shortcutID: UUID, eventID: UUID) -> String {
        "terminal-shortcut/\(shortcutID.uuidString)/\(eventID.uuidString)"
    }

    static func isStoreFile(_ url: URL) -> Bool {
        url.standardizedFileURL.path == fileURL.standardizedFileURL.path
    }

    static func editableShortcutID(for url: URL) -> UUID? {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent().path == editableDirectory.standardizedFileURL.path,
              standardized.pathExtension.lowercased() == "json" else {
            return nil
        }
        return UUID(uuidString: standardized.deletingPathExtension().lastPathComponent)
    }

    static func lineNumber(for shortcutID: UUID, in text: String) -> Int? {
        let needle = shortcutID.uuidString
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0.contains(needle) }) else { return nil }
        return index + 1
    }

    static func deleteProtectedInputs(for shortcut: TerminalShortcut) {
        for event in shortcut.events {
            if let account = event.protectedBytesReference, !account.isEmpty {
                TerminalShortcutProtectedVault.delete(account: account)
                AgentCredentialStore.delete(account: account)
            } else if event.requiresEchoOff {
                let account = protectedInputAccount(shortcutID: shortcut.id, eventID: event.id)
                TerminalShortcutProtectedVault.delete(account: account)
                AgentCredentialStore.delete(account: account)
            }
        }
    }

    private static func normalized(_ shortcuts: [TerminalShortcut]) -> [TerminalShortcut] {
        Array(
            shortcuts
                .map(\.normalized)
                .filter(\.isPlayable)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maxShortcuts)
        )
    }

    private static func prepareForPersistence(_ shortcut: TerminalShortcut) -> TerminalShortcut {
        var copy = shortcut.normalized
        var transientProtectedAccountsByPayload: [String: String] = [:]
        copy.events = copy.events.map { event in
            guard event.requiresEchoOff else { return event }
            var prepared = event
            if !event.transientProtectedBytes.isEmpty {
                let payload = Data(event.transientProtectedBytes).base64EncodedString()
                let account = transientProtectedAccountsByPayload[payload]
                    ?? event.protectedBytesReference
                    ?? protectedInputAccount(shortcutID: shortcut.id, eventID: event.id)
                transientProtectedAccountsByPayload[payload] = account
                TerminalShortcutProtectedVault.save(event.transientProtectedBytes, account: account)
                prepared.protectedBytesReference = account
            } else {
                prepared.protectedBytesReference = event.protectedBytesReference
                if prepared.protectedBytesReference == nil,
                   event.protectedPlaceholder?.isEmpty != false {
                    prepared.protectedBytesReference = protectedInputAccount(shortcutID: shortcut.id, eventID: event.id)
                }
            }
            prepared.transientProtectedBytes = []
            prepared.bytes = []
            return prepared
        }
        return copy
    }

    private static func loadFromDisk() -> [TerminalShortcut]? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([TerminalShortcut].self, from: data)
        } catch {
            print("TerminalShortcutStore: failed to load shortcuts at \(url.path): \(error)")
            return nil
        }
    }

    /// The legacy key is read from here, so a test process never migrates or
    /// clears the installed app's shortcuts.
    nonisolated static var defaults: UserDefaults { AppDefaults.standard }

    private static func loadFromUserDefaults() -> [TerminalShortcut] {
        guard let data = defaults.data(forKey: key),
              let shortcuts = try? decoder.decode([TerminalShortcut].self, from: data) else {
            return []
        }
        return shortcuts
    }

    private static func ensureDirectory(_ targetDirectory: URL? = nil) throws {
        let targetDirectory = targetDirectory ?? directory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: targetDirectory.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        TerminalShortcutProtectedVault.resetInMemoryKeyForTests()
        return previous
    }
}

enum TerminalShortcutProtectedVault {
    private static let keyFileName = "protected-vault.key"
    private static let dataFileName = "protected-vault.json"
    private static var cachedKeyData: Data?

    private struct Payload: Codable {
        var version: Int
        var entries: [String: String]
    }

    private static var keyURL: URL {
        TerminalShortcutStore.directory.appendingPathComponent(keyFileName)
    }

    private static var dataURL: URL {
        TerminalShortcutStore.directory.appendingPathComponent(dataFileName)
    }

    static func save(_ bytes: [UInt8], account: String) {
        guard !bytes.isEmpty, !account.isEmpty else {
            delete(account: account)
            return
        }
        do {
            var payload = try loadPayload()
            let sealed = try AES.GCM.seal(Data(bytes), using: key())
            guard let combined = sealed.combined else { return }
            payload.entries[account] = combined.base64EncodedString()
            try savePayload(payload)
        } catch {
            print("TerminalShortcutProtectedVault: failed to save protected input: \(error)")
        }
    }

    static func load(account: String) -> [UInt8]? {
        guard !account.isEmpty else { return nil }
        do {
            let payload = try loadPayload()
            guard let encoded = payload.entries[account],
                  let combined = Data(base64Encoded: encoded) else { return nil }
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let opened = try AES.GCM.open(sealed, using: key())
            return Array(opened)
        } catch {
            print("TerminalShortcutProtectedVault: failed to load protected input: \(error)")
            return nil
        }
    }

    static func existingAccounts() -> Set<String> {
        do {
            return Set(try loadPayload().entries.keys)
        } catch {
            print("TerminalShortcutProtectedVault: failed to list protected inputs: \(error)")
            return []
        }
    }

    static func delete(account: String) {
        guard !account.isEmpty else { return }
        do {
            var payload = try loadPayload()
            payload.entries.removeValue(forKey: account)
            try savePayload(payload)
        } catch {
            print("TerminalShortcutProtectedVault: failed to delete protected input: \(error)")
        }
    }

    private static func key() throws -> SymmetricKey {
        if let cachedKeyData, cachedKeyData.count == 32 {
            return SymmetricKey(data: cachedKeyData)
        }
        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
            cachedKeyData = existing
            return SymmetricKey(data: existing)
        }
        try ensureDirectory()
        var generated = Data(count: 32)
        let status = generated.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        try generated.write(to: keyURL, options: .atomic)
        try setOwnerOnlyPermissions(at: keyURL, mode: 0o600)
        cachedKeyData = generated
        return SymmetricKey(data: generated)
    }

    private static func loadPayload() throws -> Payload {
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            return Payload(version: 1, entries: [:])
        }
        let data = try Data(contentsOf: dataURL)
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    private static func savePayload(_ payload: Payload) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: dataURL, options: .atomic)
        try setOwnerOnlyPermissions(at: dataURL, mode: 0o600)
    }

    private static func ensureDirectory() throws {
        let directory = TerminalShortcutStore.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setOwnerOnlyPermissions(at: directory, mode: 0o700)
    }

    private static func setOwnerOnlyPermissions(at url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func resetInMemoryKeyForTests() {
        cachedKeyData = nil
    }
}
