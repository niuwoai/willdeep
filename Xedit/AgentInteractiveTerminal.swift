//
//  AgentInteractiveTerminal.swift
//  WillDeep
//
//  Interactive Agent-mode terminal. Rebuilt on SwiftTerm
//  (LocalProcessTerminalView) so each tab is a real VT100/ANSI terminal
//  emulator — colors, cursor addressing, and full-screen TUIs (vim,
//  htop, less) render correctly, and user typing behaves like Terminal /
//  Ghostty. Supports multiple tabs, defaults to a LOCAL login shell (no
//  SSH required), remembers which Agent session opened each tab, and
//  reaps tabs that sit idle for too long.
//
//  Agent tools (terminal_snapshot / terminal_send_command /
//  terminal_send_control) operate on the active tab through the same
//  controller surface as before.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
import SwiftTerm

// MARK: - Runtime terminal profile (unchanged surface; used by SSH tabs)

struct RuntimeTerminalProfile: Codable, Equatable {
    var startupDirectory: String
    var startupCommands: [String]
    var jumpCommands: [String]
    var autoRunOnConnect: Bool
    var commandDelayMilliseconds: Int
    var idleTimeoutSeconds: Int
    var serviceNames: [String]

    static let `default` = RuntimeTerminalProfile(
        startupDirectory: "",
        startupCommands: [],
        jumpCommands: [],
        autoRunOnConnect: false,
        commandDelayMilliseconds: 450,
        idleTimeoutSeconds: 5,
        serviceNames: ["nginx", "mysql", "postgresql", "redis", "docker"]
    )

    var normalized: RuntimeTerminalProfile {
        var copy = self
        copy.startupDirectory = copy.startupDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.startupCommands = Self.cleanedCommands(copy.startupCommands)
        copy.jumpCommands = Self.cleanedCommands(copy.jumpCommands)
        copy.commandDelayMilliseconds = min(max(copy.commandDelayMilliseconds, 100), 10_000)
        copy.idleTimeoutSeconds = min(max(copy.idleTimeoutSeconds, 1), 120)
        copy.serviceNames = Array(Set(copy.serviceNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        return copy
    }

    var queuedConnectCommands: [String] {
        var commands: [String] = []
        if !startupDirectory.isEmpty {
            commands.append("cd \(AgentToolRunner.shellQuoted(startupDirectory))")
        }
        commands.append(contentsOf: startupCommands)
        commands.append(contentsOf: jumpCommands)
        return commands
    }

    private static func cleanedCommands(_ commands: [String]) -> [String] {
        commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Cheap main-actor metadata handed to the agent-tool layer. The actual
/// screen text is read OFF the main actor from `mirror` — a head-less
/// `Terminal` fed on a background queue — so `terminal_snapshot` no longer
/// depends on the (possibly starved) visible model being current. Redaction
/// and trimming also run off the main actor (see `AgentTerminalTools.snapshot`).
struct AgentTerminalRawSnapshot: Sendable {
    let isRunning: Bool
    let runtimeName: String
    let runtimeTarget: String
    let recentCommands: [String]
    /// Off-main source of the visible screen text.
    let mirror: AgentTerminalSnapshotMirror
    /// Live geometry of the visible terminal, so the mirror can be squared
    /// up before capture even if a resize hasn't reflowed it yet.
    let cols: Int
    let rows: Int
}

enum AgentTerminalControl: String, CaseIterable {
    case ctrlC = "ctrl_c"
    case enter
    case escape

    var bytes: [UInt8] {
        switch self {
        case .ctrlC: return [3]
        case .enter: return [13]
        case .escape: return [27]
        }
    }

    var displayName: String {
        switch self {
        case .ctrlC: return "Ctrl-C"
        case .enter: return "Enter"
        case .escape: return "Esc"
        }
    }
}

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

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.lastRecordedInputAt = startedAt
    }

    func record(data: [UInt8], echoEnabled: Bool, now: Date = Date()) {
        guard !data.isEmpty else { return }

        if echoEnabled {
            // Echo is back on: any password line in progress is complete.
            flushPendingProtectedInput(now: now)
            appendEvent(bytes: data, echoEnabled: true, now: now)
            return
        }

        // Echo off => protected input. Accumulate keystrokes, and treat Enter
        // (CR/LF) as the line terminator that finalizes one protected event.
        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                flushPendingProtectedInput(now: now)
                // The Enter keypress itself is not a secret; record it as a
                // normal event so replay still submits the password line.
                appendEvent(bytes: [byte], echoEnabled: true, now: now)
            } else if totalRecordedBytes + pendingProtectedBytes.count < maxRecordedBytes {
                if pendingProtectedBytes.isEmpty {
                    pendingProtectedStartedAt = now
                }
                pendingProtectedBytes.append(byte)
            }
        }
    }

    /// Finalize the buffered protected keystrokes into a single event.
    private func flushPendingProtectedInput(now: Date) {
        defer {
            pendingProtectedBytes.removeAll(keepingCapacity: true)
            pendingProtectedStartedAt = nil
        }
        guard !pendingProtectedBytes.isEmpty else { return }
        appendEvent(
            bytes: pendingProtectedBytes,
            echoEnabled: false,
            now: pendingProtectedStartedAt ?? now,
            anchor: now
        )
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
        finishedAt: Date = Date()
    ) -> TerminalShortcut? {
        // Flush a password line the user never submitted (e.g. recording stopped
        // mid-prompt) so it is not silently dropped.
        flushPendingProtectedInput(now: finishedAt)
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
    private static let key = "com.willdeep.terminalShortcuts.v1"
    private static let maxShortcuts = 24
    private static let fileName = "shortcuts.json"
    private static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("terminal-shortcuts", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
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

    static func isStoreFile(_ url: URL) -> Bool {
        url.standardizedFileURL.path == fileURL.standardizedFileURL.path
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

    private static func protectedInputAccount(shortcutID: UUID, eventID: UUID) -> String {
        "terminal-shortcut/\(shortcutID.uuidString)/\(eventID.uuidString)"
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

    private static func loadFromUserDefaults() -> [TerminalShortcut] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcuts = try? decoder.decode([TerminalShortcut].self, from: data) else {
            return []
        }
        return shortcuts
    }

    private static func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

// MARK: - Tab kind

enum AgentTerminalTabKind: Equatable {
    case localShell
    case ssh(runtimeID: UUID, displayName: String, target: String)

    var isSSH: Bool { if case .ssh = self { return true }; return false }
}

// MARK: - SwiftTerm view subclass that reports user activity

/// Callbacks the owning `AgentTerminalTab` needs from the terminal view.
/// Replaces SwiftTerm's `LocalProcessTerminalViewDelegate` because the view
/// is no longer a `LocalProcessTerminalView` (see the class note below), so
/// its `source:` type would no longer fit.
protocol AgentTerminalProcessDelegate: AnyObject {
    func sizeChanged(source: AgentLocalProcessTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: AgentLocalProcessTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: AgentLocalProcessTerminalView, directory: String?)
    func processTerminated(source: AgentLocalProcessTerminalView, exitCode: Int32?)
}

/// A `TerminalView` that owns its own `LocalProcess` — deliberately NOT a
/// `LocalProcessTerminalView`.
///
/// Why not the stock subclass: `LocalProcessTerminalView` hard-wires its
/// `LocalProcess` to `DispatchQueue.main`, and its `process` is
/// `internal(set)`, so a subclass cannot swap in a background delivery
/// queue. That main-thread delivery is exactly what makes
/// `terminal_snapshot` return stale content: when the main thread is busy
/// (mid-render while streaming a reply) the PTY→model parse is starved.
///
/// So we hand-roll the ~thin process glue `LocalProcessTerminalView` gave
/// us, but point the `LocalProcess` at a private background serial queue
/// (`snapshotMirror.queue`). On that queue `dataReceived`:
///   1. feeds a head-less mirror `Terminal` (fresh, snapshot reads this), and
///   2. marshals the *visible* terminal's model+display feed back to the
///      main thread — because the visible NSView reads its model on the main
///      thread when it draws, so feeding it off-main would race the drawing.
/// The visible terminal therefore behaves exactly as before; only the
/// snapshot path is decoupled from main-thread starvation.
///
/// `paste` is `open` in SwiftTerm so we hook it for activity; `keyDown` is
/// only `public` (not overridable cross-module), so typed-keystroke activity
/// is instead inferred from echoed output via the controller's buffer-hash
/// sampling — plus the active (visible) tab is always exempt from the idle
/// reaper, which is the only tab the user can actually be typing into.
final class AgentLocalProcessTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    /// Owned PTY process, delivering bytes on `snapshotMirror.queue`.
    private(set) var process: LocalProcess!
    /// Head-less model fed off the main thread; the source of truth for
    /// `terminal_snapshot`.
    let snapshotMirror: AgentTerminalSnapshotMirror
    weak var processDelegate: AgentTerminalProcessDelegate?

    var onUserActivity: (() -> Void)?
    var shouldRecordInput: (() -> Bool)?
    var onSendToProcess: ((_ data: [UInt8], _ echoEnabled: Bool) -> Void)?
    private lazy var zmodemBridge = TerminalZModemBridge(terminalView: self)
    private var cachedEchoEnabled: Bool?
    private var cachedEchoCheckedAt: TimeInterval = 0
    private var pendingEchoBytes: [UInt8] = []
    private let maxEchoCacheAge: TimeInterval = 1.0
    private let maxPendingEchoBytes = 2_048
    /// True while a ZMODEM transfer is in flight. Written on main (from the
    /// bridge decision), read on the delivery queue (in `dataReceived`) to
    /// pause mirror feeding — the raw protocol bytes would otherwise corrupt
    /// the mirror screen, and a snapshot mid-transfer is meaningless anyway.
    /// Lock-guarded because the two accessors run on different threads.
    private let zmodemLock = NSLock()
    private var _zmodemActive = false
    private var zmodemActive: Bool {
        get { zmodemLock.lock(); defer { zmodemLock.unlock() }; return _zmodemActive }
        set { zmodemLock.lock(); _zmodemActive = newValue; zmodemLock.unlock() }
    }

    /// Scrollback kept by the mirror. Matches SwiftTerm's default so the
    /// mirror and the visible terminal reflow identically.
    private static let mirrorScrollback = 500

    override init(frame: CGRect) {
        let seed = AgentLocalProcessTerminalView.seedGeometry(for: frame)
        snapshotMirror = AgentTerminalSnapshotMirror(
            cols: seed.cols,
            rows: seed.rows,
            scrollback: AgentLocalProcessTerminalView.mirrorScrollback,
            label: "com.willdeep.agent.terminal.snapshot-mirror"
        )
        super.init(frame: frame)
        terminalDelegate = self
        // Deliver PTY bytes on the mirror's queue, NOT the main thread.
        process = LocalProcess(delegate: self, dispatchQueue: snapshotMirror.queue)
        // Match the mirror to the visible terminal's real geometry once the
        // view has computed it from the frame + font.
        let live = getTerminal()
        snapshotMirror.resize(cols: live.cols, rows: live.rows)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func seedGeometry(for frame: CGRect) -> (cols: Int, rows: Int) {
        // Pre-`super.init` we can't ask the view for its cell grid, so seed
        // with a sane default; the init tail resizes the mirror to the real
        // geometry, and every `sizeChanged` keeps it in step thereafter.
        (cols: 80, rows: 24)
    }

    override func paste(_ sender: Any) {
        onUserActivity?()
        super.paste(sender)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserActivity?()
        if shouldRecordInput?() == true {
            let bytes = Array(data)
            let echoEnabled = cachedTerminalEchoEnabled()
            onSendToProcess?(bytes, echoEnabled)
            if echoEnabled {
                rememberExpectedEcho(bytes)
            }
        }
        process.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if process.running {
            var size = getWindowSize()
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        }
        // Keep the mirror's wrapping in step with what the user sees.
        snapshotMirror.resize(cols: newCols, rows: newRows)
        processDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle(source: self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: self, directory: directory)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let str = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([str as NSString])
    }

    // MARK: LocalProcessDelegate

    /// Runs on `snapshotMirror.queue` — NOT the main thread. Feeding the
    /// mirror here is the whole fix: it can never be starved by main-thread
    /// rendering, so the snapshot stays fresh. Everything main-affine (the
    /// @MainActor ZMODEM bridge, echo bookkeeping shared with `send`, and the
    /// visible terminal's model+display) is marshaled back to main, ordered.
    func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        if !zmodemActive {
            snapshotMirror.feedOnQueue(bytes)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let consumed = self.zmodemBridge.handleRemoteBytes(bytes)
            self.zmodemActive = self.zmodemBridge.isActive
            if consumed { return }
            if self.shouldRecordInput?() == true, !self.isExpectedEcho(bytes[...]) {
                self.invalidateTerminalEchoCache()
            }
            self.feed(byteArray: bytes[...])
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processDelegate?.processTerminated(source: self, exitCode: exitCode)
        }
    }

    func getWindowSize() -> winsize {
        let f = self.frame
        let live = getTerminal()
        return winsize(
            ws_row: UInt16(live.rows),
            ws_col: UInt16(live.cols),
            ws_xpixel: UInt16(f.width),
            ws_ypixel: UInt16(f.height)
        )
    }

    // MARK: Process control (mirrors the old LocalProcessTerminalView surface)

    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        process.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    func terminate() {
        process.terminate()
    }

    var terminalEchoEnabled: Bool {
        guard process.running else { return false }
        var attributes = termios()
        guard tcgetattr(process.childfd, &attributes) == 0 else { return false }
        return (attributes.c_lflag & tcflag_t(ECHO)) != 0
    }

    func invalidateTerminalEchoCache() {
        cachedEchoEnabled = nil
        cachedEchoCheckedAt = 0
        pendingEchoBytes.removeAll(keepingCapacity: true)
    }

    private func cachedTerminalEchoEnabled() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedEchoEnabled, now - cachedEchoCheckedAt <= maxEchoCacheAge {
            return cachedEchoEnabled
        }
        let fresh = terminalEchoEnabled
        cachedEchoEnabled = fresh
        cachedEchoCheckedAt = now
        return fresh
    }

    private func rememberExpectedEcho(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pendingEchoBytes.append(contentsOf: bytes)
        if pendingEchoBytes.count > maxPendingEchoBytes {
            pendingEchoBytes.removeFirst(pendingEchoBytes.count - maxPendingEchoBytes)
        }
    }

    private func isExpectedEcho(_ slice: ArraySlice<UInt8>) -> Bool {
        guard !slice.isEmpty, !pendingEchoBytes.isEmpty else { return false }
        let bytes = Array(slice)
        guard pendingEchoBytes.starts(with: bytes) else { return false }
        pendingEchoBytes.removeFirst(bytes.count)
        return true
    }
}

// MARK: - One terminal tab

@MainActor
final class AgentTerminalTab: ObservableObject, Identifiable, AgentTerminalProcessDelegate {
    let id = UUID()
    /// Which Agent session opened this tab. nil for tabs the user opened
    /// manually with no active session context.
    let originAgentSessionID: UUID?
    let kind: AgentTerminalTabKind
    let terminalView: AgentLocalProcessTerminalView

    @Published var title: String
    @Published private(set) var isRunning = false
    @Published private(set) var recentCommands: [String] = []
    @Published private(set) var activeRecordingStartedAt: Date?
    @Published private(set) var isPlayingShortcut = false
    @Published private(set) var shortcutPlaybackState: TerminalShortcutPlaybackState?

    /// Last moment the tab saw user input or fresh process output. Drives
    /// the idle reaper. Not @Published — sampled by a timer, not the UI.
    private(set) var lastActivity = Date()
    private var lastBufferHash = 0
    private let maxRecentCommands = 20
    private var recorder: TerminalShortcutRecorder?

    init(
        kind: AgentTerminalTabKind,
        originAgentSessionID: UUID?,
        title: String,
        settings: EditorTerminalSettings
    ) {
        self.kind = kind
        self.originAgentSessionID = originAgentSessionID
        self.title = title
        self.terminalView = AgentLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        applyAppearance(settings, skin: nil)
        terminalView.processDelegate = self
        terminalView.onUserActivity = { [weak self] in
            self?.lastActivity = Date()
        }
        terminalView.shouldRecordInput = { [weak self] in
            guard let self else { return false }
            return self.recorder != nil && !self.isPlayingShortcut
        }
        terminalView.onSendToProcess = { [weak self] data, echoEnabled in
            self?.recordInputIfNeeded(data: data, echoEnabled: echoEnabled)
        }
    }

    func applyAppearance(_ settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        TerminalAppearance.apply(to: terminalView, settings: settings.normalized(), skin: skin)
    }

    // MARK: Launch

    func start(
        settings: EditorTerminalSettings,
        workingDirectory: String?,
        profile: RuntimeTerminalProfile?,
        skin: TerminalSkinColors?
    ) {
        terminalView.invalidateTerminalEchoCache()
        applyAppearance(settings, skin: skin)
        let env = Self.environmentArray(settings: settings)
        switch kind {
        case .localShell:
            let shell = Self.loginShellPath()
            // No workspace → open the shell in the user's home, never the app
            // process cwd (which is "/" for a bundled app). A fresh terminal
            // should land in the current workspace or ~, not the filesystem root.
            let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-" + (shell as NSString).lastPathComponent,
                currentDirectory: cwd
            )
        case .ssh(_, _, let target):
            guard let descriptor = sshDescriptor() else {
                isRunning = false
                return
            }
            var args = ["-tt", "-p", "\(descriptor.port)"]
            if let identity = descriptor.identityFilePath, !identity.isEmpty {
                args += ["-i", Self.expandedPath(identity)]
            }
            args.append(target)
            terminalView.startProcess(
                executable: "/usr/bin/ssh",
                args: args,
                environment: env,
                currentDirectory: workingDirectory
            )
            if let profile = profile?.normalized, profile.autoRunOnConnect {
                drainConnectCommands(profile.queuedConnectCommands, delayMs: profile.commandDelayMilliseconds)
            }
        }
        isRunning = true
        lastActivity = Date()
    }

    private func sshDescriptor() -> RuntimeDescriptor? {
        guard case .ssh(let runtimeID, _, _) = kind else { return nil }
        return AgentRuntimeStore.descriptor(id: runtimeID)?.normalized
    }

    private func drainConnectCommands(_ commands: [String], delayMs: Int) {
        guard !commands.isEmpty else { return }
        Task { [weak self] in
            let delay = UInt64(max(100, delayMs)) * 1_000_000
            for command in commands {
                try? await Task.sleep(nanoseconds: delay)
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.recordCommand(command)
                    self.terminalView.send(txt: command + "\n")
                }
            }
        }
    }

    func terminate() {
        guard isRunning else { return }
        cancelRecording()
        finishShortcutPlayback(status: .cancelled(reason: "terminal_stopped"))
        terminalView.terminate()
        isRunning = false
    }

    var isRecording: Bool { recorder != nil }

    func startRecording() {
        guard recorder == nil else { return }
        let now = Date()
        recorder = TerminalShortcutRecorder(startedAt: now)
        activeRecordingStartedAt = now
    }

    func stopRecording(defaultTitle: String? = nil) -> TerminalShortcut? {
        let finishedAt = Date()
        defer {
            recorder = nil
            activeRecordingStartedAt = nil
        }
        let title = defaultTitle ?? "Terminal Shortcut \(Self.shortcutTitleFormatter.string(from: finishedAt))"
        return recorder?.finish(title: title, finishedAt: finishedAt)
    }

    func cancelRecording() {
        recorder = nil
        activeRecordingStartedAt = nil
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
        guard isRunning,
              shortcut.isPlayable,
              !shortcut.hasPendingProtectedInput,
              !isRecording,
              !isPlayingShortcut else { return }
        isPlayingShortcut = true
        let startedAt = Date()
        let totalDelay = shortcut.playbackDurationMilliseconds
        shortcutPlaybackState = TerminalShortcutPlaybackState(
            shortcutID: shortcut.id,
            title: shortcut.title,
            currentEventIndex: 0,
            totalEvents: shortcut.eventCount,
            startedAt: startedAt,
            estimatedFinishedAt: startedAt.addingTimeInterval(Double(totalDelay) / 1000),
            totalDelayMilliseconds: totalDelay,
            status: .running
        )
        Task { [weak self] in
            var protectedBytesCache: [String: [UInt8]] = [:]
            var completedNormally = true
            for (index, event) in shortcut.events.enumerated() {
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.shortcutPlaybackState?.currentEventIndex = index + 1
                }
                if event.delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(event.delayMilliseconds) * 1_000_000)
                }
                let shouldContinue = await MainActor.run {
                    guard let self, self.isRunning else { return false }
                    if event.requiresEchoOff, self.terminalView.terminalEchoEnabled {
                        self.finishShortcutPlayback(status: .cancelled(reason: "echo_enabled"))
                        return false
                    }
                    return true
                }
                if shouldContinue == false {
                    completedNormally = false
                    break
                }
                let bytes = event.resolvedBytes(cache: &protectedBytesCache)
                guard !bytes.isEmpty else { continue }
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.terminalView.send(bytes)
                }
            }
            await MainActor.run {
                guard let self else { return }
                if completedNormally {
                    self.finishShortcutPlayback(status: .finished)
                } else if self.isPlayingShortcut {
                    self.finishShortcutPlayback(status: .cancelled(reason: "interrupted"))
                }
            }
        }
    }

    private func finishShortcutPlayback(status: TerminalShortcutPlaybackState.Status) {
        isPlayingShortcut = false
        guard shortcutPlaybackState != nil else { return }
        shortcutPlaybackState?.status = status
        shortcutPlaybackState?.currentEventIndex = shortcutPlaybackState?.totalEvents ?? 0
    }

    // MARK: Agent-tool surface

    func sendApprovedCommand(_ command: String, secretRedactionValues: [String] = []) throws -> AgentToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolError.missingArgument("command") }
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending commands.")
        }
        let visibleCommand = AgentSecretStore.redact(trimmed, secretValues: secretRedactionValues)
        recordCommand(visibleCommand)
        lastActivity = Date()
        terminalView.send(txt: trimmed + "\n")
        let payload = """
        Sent command to Agent Terminal tab \"\(title)\".
        Command: \(visibleCommand)
        """
        return AgentToolResult(summary: "terminal: \(visibleCommand.prefix(80))", payload: payload)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending control input.")
        }
        lastActivity = Date()
        terminalView.send(control.bytes)
        let payload = "Sent \(control.displayName) to Agent Terminal tab \"\(title)\"."
        return AgentToolResult(summary: "terminal: \(control.displayName)", payload: payload)
    }

    /// The off-main snapshot mirror plus the visible terminal's live grid
    /// size. The screen text itself is read from the mirror off the main
    /// actor by `AgentTerminalTools.snapshot`, so a busy main thread can no
    /// longer make the snapshot stale.
    func snapshotSource() -> (mirror: AgentTerminalSnapshotMirror, cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminalView.snapshotMirror, terminal.cols, terminal.rows)
    }

    private func recordCommand(_ command: String) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > maxRecentCommands {
            recentCommands.removeLast(recentCommands.count - maxRecentCommands)
        }
    }

    private func recordInputIfNeeded(data: [UInt8], echoEnabled: Bool) {
        guard !isPlayingShortcut else { return }
        recorder?.record(data: data, echoEnabled: echoEnabled)
    }

    // MARK: Idle bookkeeping

    var runtimeTarget: String {
        if case .ssh(_, _, let target) = kind { return target }
        return "local"
    }

    func idleSeconds(now: Date) -> TimeInterval {
        now.timeIntervalSince(lastActivity)
    }

    /// Sample the visible buffer; if it changed since last sample the tab
    /// produced output → it's active. Returns true if activity bumped.
    @discardableResult
    func refreshActivityFromBuffer(now: Date) -> Bool {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return false }
        let bottom = terminal.buffer.yDisp + rows - 1
        let startRow = max(0, bottom - rows + 1)
        let text = terminal.getText(
            start: Position(col: 0, row: startRow),
            end: Position(col: cols - 1, row: bottom)
        )
        let hash = text.hashValue
        if hash != lastBufferHash {
            lastBufferHash = hash
            lastActivity = now
            return true
        }
        return false
    }

    // MARK: AgentTerminalProcessDelegate

    func sizeChanged(source: AgentLocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: AgentLocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep the user/origin label as the primary title; the OSC title
        // is noisy. Only adopt it for local tabs that still carry the
        // generic default name.
        if kind == .localShell, self.title.hasPrefix("Shell") {
            self.title = String(trimmed.prefix(40))
        }
    }

    func hostCurrentDirectoryUpdate(source: AgentLocalProcessTerminalView, directory: String?) {}

    func processTerminated(source: AgentLocalProcessTerminalView, exitCode: Int32?) {
        isRunning = false
        finishShortcutPlayback(status: .cancelled(reason: "terminal_exited"))
    }

    // MARK: Helpers

    private static func loginShellPath() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private static func environmentArray(settings: EditorTerminalSettings) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["WILLDEEP_AGENT_TERMINAL"] = "1"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        for (key, value) in settings.environment {
            environment[key] = value
        }
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    private static func expandedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static let shortcutTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Controller: owns tabs + idle reaper + agent-tool surface

@MainActor
final class AgentInteractiveTerminalController: ObservableObject {
    @Published private(set) var tabs: [AgentTerminalTab] = []
    @Published var activeTabID: UUID?
    /// Default runtime for new SSH tabs.
    @Published var selectedRuntimeID: UUID?
    @Published private(set) var shortcuts: [TerminalShortcut] = TerminalShortcutStore.load()

    /// Supplies parameters to open a local shell tab on demand when an
    /// agent tool wants to drive the terminal but the user hasn't opened
    /// one yet. Wired by AppState so the controller can reach live
    /// terminal settings and the active session's workspace. Returns nil
    /// only if there's no AppState to ask.
    var defaultLocalTabProvider: (() -> (settings: EditorTerminalSettings, workingDirectory: String?, originAgentSessionID: UUID?, skin: TerminalSkinColors?)?)?

    /// Tabs idle longer than this are auto-terminated and removed. The
    /// currently-visible tab is exempt so we never close what the user is
    /// looking at.
    private let idleTimeout: TimeInterval = 300
    private var idleTimer: Timer?
    private var localShellCounter = 0
    private var tabChangePublishScheduled = false

    init() {
        startIdleReaper()
    }

    deinit {
        idleTimer?.invalidate()
    }

    var activeTab: AgentTerminalTab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    var recordingTabID: UUID? {
        tabs.first(where: \.isRecording)?.id
    }

    var isRecording: Bool {
        recordingTabID != nil
    }

    var activeShortcutPlaybackState: TerminalShortcutPlaybackState? {
        activeTab?.shortcutPlaybackState
    }

    var runtimeOptions: [RuntimeDescriptor] {
        AgentRuntimeStore.loadDescriptors().filter { $0.transport == .ssh }
    }

    func selectRuntimeIfNeeded() {
        if selectedRuntimeID == nil {
            selectedRuntimeID = runtimeOptions.first?.id
        }
    }

    // MARK: Tab lifecycle

    @discardableResult
    func openLocalTab(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) -> AgentTerminalTab {
        localShellCounter += 1
        let tab = AgentTerminalTab(
            kind: .localShell,
            originAgentSessionID: originAgentSessionID,
            title: "Shell \(localShellCounter)",
            settings: settings
        )
        tab.start(settings: settings, workingDirectory: workingDirectory, profile: nil, skin: skin)
        register(tab)
        return tab
    }

    @discardableResult
    func openSSHTab(
        runtime: RuntimeDescriptor,
        originAgentSessionID: UUID?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) -> AgentTerminalTab {
        let normalized = runtime.normalized
        let tab = AgentTerminalTab(
            kind: .ssh(runtimeID: normalized.id, displayName: normalized.displayName, target: normalized.sshTarget),
            originAgentSessionID: originAgentSessionID,
            title: normalized.displayName,
            settings: settings
        )
        tab.start(
            settings: settings,
            workingDirectory: nil,
            profile: normalized.terminalProfile,
            skin: skin
        )
        register(tab)
        return tab
    }

    private func register(_ tab: AgentTerminalTab) {
        // Re-publish each tab's changes so the side panel updates live.
        let cancellable = tab.objectWillChange.sink { [weak self] _ in
            self?.scheduleTabChangePublish()
        }
        tabSubscriptions[tab.id] = cancellable
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func scheduleTabChangePublish() {
        guard !tabChangePublishScheduled else { return }
        tabChangePublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabChangePublishScheduled = false
            self.objectWillChange.send()
        }
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabSubscriptions[id]?.cancel()
        tabSubscriptions[id] = nil
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }

    func startRecordingActiveTab() {
        guard recordingTabID == nil,
              let tab = activeTab,
              tab.isRunning else { return }
        tab.startRecording()
    }

    func stopRecording() {
        guard let tab = tabs.first(where: \.isRecording),
              let shortcut = tab.stopRecording() else {
            tabs.first(where: \.isRecording)?.cancelRecording()
            return
        }
        upsertShortcut(shortcut)
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
        guard !isRecording else { return }
        activeTab?.playShortcut(shortcut)
    }

    func prepareShortcutsFileForEditing() {
        TerminalShortcutStore.save(shortcuts)
    }

    @discardableResult
    func reloadShortcutsFromDisk() -> Bool {
        do {
            shortcuts = try TerminalShortcutStore.loadEditableShortcuts()
            return true
        } catch {
            print("AgentInteractiveTerminalController: failed to reload edited shortcuts: \(error)")
            return false
        }
    }

    func renameShortcut(id: UUID, title: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        var shortcut = shortcuts[index]
        shortcut.title = title
        shortcut.updatedAt = Date()
        shortcuts[index] = shortcut.normalized
        persistShortcuts()
    }

    @discardableResult
    func createShortcut(
        title: String,
        events createEvents: [TerminalShortcutCreateEvent],
        now: Date = Date()
    ) throws -> TerminalShortcut {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        guard !createEvents.isEmpty else {
            throw AgentToolError.invalidArgument("Terminal shortcut creation requires at least one event.")
        }

        let events = try createEvents.map { createEvent in
            let delay = min(max(createEvent.delayMilliseconds, 0), 300_000)
            if createEvent.kind == .protectedPlaceholder {
                let placeholder = createEvent.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !placeholder.isEmpty else {
                    throw AgentToolError.invalidArgument("Terminal shortcut protected placeholders cannot be empty.")
                }
                return TerminalShortcutEvent(
                    delayMilliseconds: delay,
                    bytes: [],
                    requiresEchoOff: true,
                    protectedPlaceholder: String(placeholder.prefix(80))
                )
            }
            let bytes = try Self.shortcutBytes(for: createEvent)
            guard !bytes.isEmpty else {
                throw AgentToolError.invalidArgument("Terminal shortcut events cannot be empty.")
            }
            return TerminalShortcutEvent(
                delayMilliseconds: delay,
                bytes: bytes
            )
        }
        let duration = events.reduce(0) { $0 + max(0, $1.delayMilliseconds) }
        let shortcut = TerminalShortcut(
            id: UUID(),
            title: trimmed,
            createdAt: now,
            updatedAt: now,
            durationMilliseconds: duration,
            events: events,
            hasProtectedInput: events.contains { $0.requiresEchoOff }
        ).normalized
        shortcuts.insert(shortcut, at: 0)
        persistShortcuts()
        return shortcut
    }

    @discardableResult
    func editShortcut(
        id: UUID,
        title: String?,
        operations: [TerminalShortcutEditOperation]
    ) throws -> TerminalShortcut {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else {
            throw AgentToolError.invalidArgument("Unknown terminal shortcut id: \(id.uuidString).")
        }

        var shortcut = shortcuts[index]
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                shortcut.title = trimmed
            }
        }

        for operation in operations {
            guard shortcut.events.indices.contains(operation.eventIndex) else {
                throw AgentToolError.invalidArgument("Terminal shortcut event index \(operation.eventIndex) is out of range.")
            }

            switch operation.kind {
            case .setDelay:
                guard let delay = operation.delayMilliseconds else {
                    throw AgentToolError.missingArgument("delay_ms")
                }
                shortcut.events[operation.eventIndex].delayMilliseconds = min(max(delay, 0), 300_000)
            case .deleteEvent:
                shortcut.events.remove(at: operation.eventIndex)
            case .replaceVisibleText:
                try editVisibleEventText(
                    shortcut: &shortcut,
                    eventIndex: operation.eventIndex,
                    find: operation.find,
                    replacement: operation.replacement ?? ""
                )
            case .setVisibleText:
                guard let text = operation.text else {
                    throw AgentToolError.missingArgument("text")
                }
                try setVisibleEventText(shortcut: &shortcut, eventIndex: operation.eventIndex, text: text)
            case .deleteVisibleText:
                try editVisibleEventText(
                    shortcut: &shortcut,
                    eventIndex: operation.eventIndex,
                    find: operation.find,
                    replacement: ""
                )
            }
        }

        shortcut.updatedAt = Date()
        shortcut.hasProtectedInput = shortcut.events.contains { $0.requiresEchoOff }
        let normalized = shortcut.normalized
        guard normalized.isPlayable else {
            throw AgentToolError.invalidArgument("Terminal shortcut edits removed all playable events.")
        }
        shortcuts[index] = normalized
        persistShortcuts()
        return normalized
    }

    func deleteShortcut(id: UUID) {
        shortcuts
            .filter { $0.id == id }
            .forEach(TerminalShortcutStore.deleteProtectedInputs)
        shortcuts.removeAll { $0.id == id }
        persistShortcuts()
    }

    private func upsertShortcut(_ shortcut: TerminalShortcut) {
        shortcuts
            .filter { $0.id == shortcut.id }
            .forEach(TerminalShortcutStore.deleteProtectedInputs)
        shortcuts.removeAll { $0.id == shortcut.id }
        shortcuts.insert(shortcut.normalized, at: 0)
        persistShortcuts()
    }

    private func persistShortcuts() {
        let normalized = Array(shortcuts.map(\.normalized).filter(\.isPlayable).prefix(24))
        TerminalShortcutStore.save(normalized)
        shortcuts = TerminalShortcutStore.load()
    }

    @discardableResult
    func fillProtectedInputs(
        shortcutID: UUID,
        valuesByEventIndex: [Int: String]
    ) throws -> TerminalShortcut {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcutID }) else {
            throw AgentToolError.invalidArgument("Unknown terminal shortcut id: \(shortcutID.uuidString).")
        }
        guard !valuesByEventIndex.isEmpty else {
            throw AgentToolError.missingArgument("protected input values")
        }

        var shortcut = shortcuts[index]
        for (eventIndex, value) in valuesByEventIndex {
            guard shortcut.events.indices.contains(eventIndex) else {
                throw AgentToolError.invalidArgument("Terminal shortcut event index \(eventIndex) is out of range.")
            }
            guard shortcut.events[eventIndex].requiresEchoOff else {
                throw AgentToolError.invalidArgument("Terminal shortcut event \(eventIndex) is not a protected input placeholder.")
            }
            guard !value.isEmpty else {
                throw AgentToolError.invalidArgument("Protected input for event \(eventIndex) cannot be empty.")
            }
            shortcut.events[eventIndex].transientProtectedBytes = Array(value.utf8)
        }

        shortcut.updatedAt = Date()
        shortcut.hasProtectedInput = shortcut.events.contains { $0.requiresEchoOff }
        shortcuts[index] = shortcut.normalized
        persistShortcuts()

        guard let updated = shortcuts.first(where: { $0.id == shortcutID }) else {
            throw AgentToolError.notFound(shortcutID.uuidString)
        }
        return updated
    }

    private static func shortcutBytes(for createEvent: TerminalShortcutCreateEvent) throws -> [UInt8] {
        switch createEvent.kind {
        case .command:
            let command = createEvent.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                throw AgentToolError.invalidArgument("Terminal shortcut command events cannot be empty.")
            }
            return Array((command + "\n").utf8)
        case .text:
            return TerminalShortcutTextCodec.bytes(fromEscapedText: createEvent.value)
        case .control:
            switch createEvent.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "enter":
                return [13]
            case "tab":
                return [9]
            case "escape", "esc":
                return [27]
            case "backspace":
                return [127]
            case "ctrl_c", "ctrl-c":
                return [3]
            default:
                throw AgentToolError.invalidArgument("control must be one of: enter, tab, escape, backspace, ctrl_c.")
            }
        case .protectedPlaceholder:
            throw AgentToolError.invalidArgument("Protected placeholders are not visible byte events.")
        }
    }

    private func editVisibleEventText(
        shortcut: inout TerminalShortcut,
        eventIndex: Int,
        find: String?,
        replacement: String
    ) throws {
        guard let find, !find.isEmpty else {
            throw AgentToolError.missingArgument("find")
        }
        var text = try visibleEventText(shortcut.events[eventIndex], eventIndex: eventIndex)
        guard text.contains(find) else {
            throw AgentToolError.invalidArgument("Terminal shortcut event \(eventIndex) does not contain the requested visible text.")
        }
        text = text.replacingOccurrences(of: find, with: replacement)
        try setVisibleEventText(shortcut: &shortcut, eventIndex: eventIndex, text: text)
    }

    private func setVisibleEventText(
        shortcut: inout TerminalShortcut,
        eventIndex: Int,
        text: String
    ) throws {
        _ = try visibleEventText(shortcut.events[eventIndex], eventIndex: eventIndex)
        shortcut.events[eventIndex].bytes = TerminalShortcutTextCodec.bytes(fromEscapedText: text)
    }

    private func visibleEventText(_ event: TerminalShortcutEvent, eventIndex: Int) throws -> String {
        guard !event.requiresEchoOff else {
            throw AgentToolError.invalidArgument("Terminal shortcut event \(eventIndex) is protected echo-off input and cannot expose or rewrite secret bytes.")
        }
        return String(decoding: event.bytes, as: UTF8.self)
    }

    /// Make sure the panel always has at least one live tab to show; opens
    /// a local shell rooted at `workingDirectory` if there are none.
    func ensureAtLeastOneTab(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) {
        if tabs.isEmpty {
            openLocalTab(
                originAgentSessionID: originAgentSessionID,
                workingDirectory: workingDirectory,
                settings: settings,
                skin: skin
            )
        }
    }

    func applyAppearanceToAll(_ settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        for tab in tabs {
            tab.applyAppearance(settings, skin: skin)
        }
    }

    private var tabSubscriptions: [UUID: AnyCancellable] = [:]

    // MARK: Idle reaper

    private func startIdleReaper() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func tickIdle() {
        guard !tabs.isEmpty else { return }
        let now = Date()
        var doomed: [UUID] = []
        for tab in tabs {
            tab.refreshActivityFromBuffer(now: now)
            // Never reap the tab the user is currently viewing.
            if tab.id == activeTabID { continue }
            if tab.idleSeconds(now: now) > idleTimeout {
                doomed.append(tab.id)
            }
        }
        for id in doomed {
            closeTab(id: id)
        }
    }

    // MARK: Agent-tool surface (operate on the active tab)

    /// Cheap main-actor metadata for the `terminal_snapshot` tool, plus the
    /// off-main mirror the tool reads the actual screen from. Throws a clear,
    /// actionable error when there is no terminal to read — instead of
    /// silently returning an empty "disconnected" snapshot the agent can't
    /// tell apart from a terminal that simply produced no output. The screen
    /// text, redaction and trimming all run off the main actor in
    /// `AgentTerminalTools.snapshot`.
    func rawSnapshot() throws -> AgentTerminalRawSnapshot {
        guard let tab = activeTab else {
            throw AgentToolError.invalidArgument(
                "No Agent Terminal tab is open, so there is nothing to read. Open the Agent Terminal side panel, or use the terminal send_command tool (it starts a shell automatically) before calling terminal_snapshot."
            )
        }
        let source = tab.snapshotSource()
        return AgentTerminalRawSnapshot(
            isRunning: tab.isRunning,
            runtimeName: tab.title,
            runtimeTarget: tab.runtimeTarget,
            recentCommands: tab.recentCommands,
            mirror: source.mirror,
            cols: source.cols,
            rows: source.rows
        )
    }

    func sendApprovedCommand(_ command: String, secretRedactionValues: [String] = []) throws -> AgentToolResult {
        let tab = try activeTabForToolUse()
        return try tab.sendApprovedCommand(command, secretRedactionValues: secretRedactionValues)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        let tab = try activeTabForToolUse()
        return try tab.sendApprovedControl(control)
    }

    /// The tab an agent tool should act on: the active one, or — if the
    /// user hasn't opened the terminal yet — a freshly opened local shell
    /// so the agent can drive the terminal without the user first
    /// clicking around. Falls back to a clear error only when there's no
    /// way to open one.
    private func activeTabForToolUse() throws -> AgentTerminalTab {
        if let tab = activeTab { return tab }
        guard let config = defaultLocalTabProvider?() else {
            throw AgentToolError.invalidArgument("Open the Agent Terminal side panel first so a shell is available.")
        }
        return openLocalTab(
            originAgentSessionID: config.originAgentSessionID,
            workingDirectory: config.workingDirectory,
            settings: config.settings,
            skin: config.skin
        )
    }
}

// MARK: - Secret redaction (unchanged)

enum AgentTerminalRedactor {
    private static let patterns: [String] = [
        #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{12,}"#,
        #"(?i)\b[A-Z0-9_]*(api[_-]?key|token|secret|password|jwt)[A-Z0-9_]*\s*[:=]\s*['"]?[^'"\s]{3,}"#,
        #"(?i)\b(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{3,}"#,
        #"(?i)\b(sk-[A-Za-z0-9_-]{16,})\b"#,
        #"(?i)\b([A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})\b"#
    ]

    static func redact(_ text: String) -> String {
        var output = text
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: [.regularExpression]
            )
        }
        return output
    }
}
