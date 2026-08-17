//
//  AgentAttentionSettings.swift
//  WillDeep
//
//  Shared notification-sound and webhook preferences. The values live in
//  ~/.willdeep/config.toml so the macOS app and willdeep-rs use one schema.
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

nonisolated enum AgentNotificationSound: String, CaseIterable, Identifiable, Sendable {
    case none
    case systemDefault = "system-default"
    case glass
    case ping
    case pop
    case submarine
    case custom

    var id: String { rawValue }

    @MainActor
    var displayName: String {
        switch self {
        case .none: return L10n.AgentNotifications.Settings.soundNone
        case .systemDefault: return L10n.AgentNotifications.Settings.soundSystemDefault
        case .glass: return "Glass"
        case .ping: return "Ping"
        case .pop: return "Pop"
        case .submarine: return "Submarine"
        case .custom: return L10n.AgentNotifications.Settings.soundCustom
        }
    }

    var systemFileName: String? {
        switch self {
        case .glass: return "Glass.aiff"
        case .ping: return "Ping.aiff"
        case .pop: return "Pop.aiff"
        case .submarine: return "Submarine.aiff"
        case .none, .systemDefault, .custom: return nil
        }
    }
}

nonisolated struct AgentAttentionPreferences: Equatable, Sendable {
    var sound: AgentNotificationSound = .systemDefault
    var customSoundFile: String = ""
    var customSoundDisplayName: String = ""
    var webhookEnabled = false
    var webhookURL = ""
    var webhookOnTaskCompleted = true
    var webhookOnAttentionRequired = true
}

private struct AgentAttentionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(nsColor: .textBackgroundColor))
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.78 : 1))
            )
    }
}

nonisolated enum AgentAttentionPreferencesStore {
    private static let sectionName = "notifications"

    static func defaultConfigURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["WILLDEEP_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("config.toml")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    static func load(from url: URL = defaultConfigURL()) -> AgentAttentionPreferences {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return AgentAttentionPreferences()
        }
        let values = notificationValues(in: text)
        var preferences = AgentAttentionPreferences()
        preferences.sound = values["sound"]
            .flatMap(unquoted)
            .flatMap(AgentNotificationSound.init(rawValue:))
            ?? preferences.sound
        preferences.customSoundFile = values["custom_sound_file"].flatMap(unquoted) ?? ""
        preferences.customSoundDisplayName = values["custom_sound_display_name"].flatMap(unquoted) ?? ""
        preferences.webhookEnabled = values["webhook_enabled"].flatMap(parseBool) ?? false
        preferences.webhookURL = values["webhook_url"].flatMap(unquoted) ?? ""
        preferences.webhookOnTaskCompleted = values["webhook_on_task_completed"].flatMap(parseBool) ?? true
        preferences.webhookOnAttentionRequired = values["webhook_on_attention_required"].flatMap(parseBool) ?? true
        return preferences
    }

    static func save(
        _ preferences: AgentAttentionPreferences,
        to url: URL = defaultConfigURL()
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "version = 1\n"
        let updated = replacingNotificationSection(in: existing, with: preferences)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func replacingNotificationSection(
        in text: String,
        with preferences: AgentAttentionPreferences
    ) -> String {
        var lines = text.components(separatedBy: .newlines)
        while lines.last == "" { lines.removeLast() }
        let header = "[\(sectionName)]"
        let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == header }
        let end = start.flatMap { sectionStart in
            lines.indices.dropFirst(sectionStart + 1).first { index in
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
            }
        }
        let block = notificationBlock(preferences)
        if let start {
            lines.replaceSubrange(start..<(end ?? lines.endIndex), with: block)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: block)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func notificationBlock(_ preferences: AgentAttentionPreferences) -> [String] {
        [
            "[\(sectionName)]",
            "sound = \(quoted(preferences.sound.rawValue))",
            "custom_sound_file = \(quoted(preferences.customSoundFile))",
            "custom_sound_display_name = \(quoted(preferences.customSoundDisplayName))",
            "webhook_enabled = \(preferences.webhookEnabled)",
            "webhook_url = \(quoted(preferences.webhookURL))",
            "webhook_on_task_completed = \(preferences.webhookOnTaskCompleted)",
            "webhook_on_attention_required = \(preferences.webhookOnAttentionRequired)",
        ]
    }

    private static func notificationValues(in text: String) -> [String: String] {
        var inside = false
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inside = trimmed == "[\(sectionName)]"
                continue
            }
            guard inside, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let pieces = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            values[pieces[0].trimmingCharacters(in: .whitespaces)] =
                pieces[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func unquoted(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

@MainActor
enum AgentNotificationSoundManager {
    private static let systemSoundRoot = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    private enum ImportError: LocalizedError {
        case emptyAudio
        case tooLong

        var errorDescription: String? {
            switch self {
            case .emptyAudio:
                return L10n.AgentNotifications.Settings.audioEmpty
            case .tooLong:
                return L10n.AgentNotifications.Settings.audioTooLong
            }
        }
    }

    static func importCustomSound(from source: URL) throws -> (fileName: String, displayName: String) {
        let supported = ["mp3", "aiff", "aif", "wav", "caf", "m4a"]
        let fileExtension = source.pathExtension.lowercased()
        guard supported.contains(fileExtension) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        let destinationName = "WillDeep-Custom-Alert.caf"
        let destination = try soundsDirectory().appendingPathComponent(destinationName)
        try convertToNotificationCAF(source: source, destination: destination)
        return (destinationName, source.lastPathComponent)
    }

    static func notificationSound(for preferences: AgentAttentionPreferences) -> UNNotificationSound? {
        switch preferences.sound {
        case .none:
            return nil
        case .systemDefault:
            return .default
        case .custom:
            guard !preferences.customSoundFile.isEmpty,
                  let url = try? soundsDirectory().appendingPathComponent(preferences.customSoundFile),
                  FileManager.default.fileExists(atPath: url.path) else {
                return .default
            }
            return UNNotificationSound(named: UNNotificationSoundName(preferences.customSoundFile))
        case .glass, .ping, .pop, .submarine:
            guard let copiedName = try? installSystemSound(preferences.sound) else {
                return .default
            }
            return UNNotificationSound(named: UNNotificationSoundName(copiedName))
        }
    }

    static func preview(_ preferences: AgentAttentionPreferences) {
        switch preferences.sound {
        case .none:
            return
        case .systemDefault:
            NSSound.beep()
        case .custom:
            guard let url = try? soundsDirectory().appendingPathComponent(preferences.customSoundFile),
                  let sound = NSSound(contentsOf: url, byReference: true) else {
                NSSound.beep()
                return
            }
            sound.play()
        case .glass, .ping, .pop, .submarine:
            guard let sourceName = preferences.sound.systemFileName,
                  let sound = NSSound(contentsOf: systemSoundRoot.appendingPathComponent(sourceName), byReference: true) else {
                NSSound.beep()
                return
            }
            sound.play()
        }
    }

    private static func installSystemSound(_ sound: AgentNotificationSound) throws -> String {
        guard let sourceName = sound.systemFileName else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destinationName = "WillDeep-\(sourceName)"
        let destination = try soundsDirectory().appendingPathComponent(destinationName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(
                at: systemSoundRoot.appendingPathComponent(sourceName),
                to: destination
            )
        }
        return destinationName
    }

    private static func soundsDirectory() throws -> URL {
        let library = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func convertToNotificationCAF(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0, input.processingFormat.sampleRate > 0 else {
            throw ImportError.emptyAudio
        }
        let duration = Double(input.length) / input.processingFormat.sampleRate
        guard duration <= 30 else {
            throw ImportError.tooLong
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: input.processingFormat.settings
        )
        let frameCapacity: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ImportError.emptyAudio
        }
        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            let frameCount = min(frameCapacity, AVAudioFrameCount(remaining))
            try input.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}

nonisolated enum AgentAttentionWebhookEventKind: String, Sendable {
    case taskCompleted = "task_completed"
    case attentionRequired = "attention_required"
    case test = "test"
}

nonisolated enum AgentWebhookSource: String, Sendable {
    case willDeep = "willdeep"
    case claudeCode = "claude-code"
    case codex
    case unknown
}

nonisolated enum AgentWebhookDetectionConfidence: String, Sendable {
    case high
    case medium
    case low
}

nonisolated struct AgentWebhookFormatDetection: Equatable, Sendable {
    let source: AgentWebhookSource
    let confidence: AgentWebhookDetectionConfidence
    let hasConflict: Bool
}

/// Recognizes the stable, distinctive parts of WillDeep, Claude Code, and
/// Codex hook requests. Headers are considered first, then the JSON body.
/// Shared fields such as `hook_event_name: Stop` are deliberately not enough
/// to guess a vendor because both Claude Code and Codex use them.
nonisolated enum AgentWebhookFormatDetector {
    static func detect(headers: [String: String], body: Data) -> AgentWebhookFormatDetection {
        var normalizedHeaders: [String: String] = [:]
        for (name, value) in headers {
            normalizedHeaders[name.lowercased()] = value
        }
        let explicitHeaderSource = source(
            from: normalizedHeaders["x-agent-source"]
                ?? normalizedHeaders["x-webhook-source"]
        )
        let userAgentSource = source(fromUserAgent: normalizedHeaders["user-agent"])
        let headerSource = explicitHeaderSource ?? userAgentSource
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let payloadSource = payload.flatMap(source(fromPayload:))

        if let headerSource {
            return AgentWebhookFormatDetection(
                source: headerSource,
                confidence: explicitHeaderSource == nil ? .medium : .high,
                hasConflict: payloadSource.map { $0 != headerSource } ?? false
            )
        }
        if let payloadSource {
            return AgentWebhookFormatDetection(
                source: payloadSource,
                confidence: .high,
                hasConflict: false
            )
        }
        return AgentWebhookFormatDetection(source: .unknown, confidence: .low, hasConflict: false)
    }

    static func executorSource(_ executor: String?) -> AgentWebhookSource {
        source(from: executor) ?? .willDeep
    }

    private static func source(from value: String?) -> AgentWebhookSource? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else { return nil }
        if normalized.contains("willdeep") { return .willDeep }
        if normalized.contains("claude") || normalized.contains("anthropic") { return .claudeCode }
        if normalized.contains("codex") || normalized == "openai" { return .codex }
        return nil
    }

    private static func source(fromUserAgent value: String?) -> AgentWebhookSource? {
        source(from: value)
    }

    private static func source(fromPayload payload: [String: Any]) -> AgentWebhookSource? {
        if string(payload["schema_version"])?.hasPrefix("willdeep.") == true
            || source(from: string(payload["source"])) == .willDeep
            || source(from: string(payload["application"])) == .willDeep {
            return .willDeep
        }

        if string(payload["type"]) == "agent-turn-complete"
            || payload["thread-id"] != nil
            || payload["turn-id"] != nil
            || source(from: string(payload["client"])) == .codex {
            return .codex
        }

        if payload["notification_type"] != nil
            || payload["background_tasks"] != nil
            || payload["session_crons"] != nil {
            return .claudeCode
        }

        let hookEventName = string(payload["hook_event_name"])
        if hookEventName == "Notification"
            || hookEventName == "TaskCompleted"
            || hookEventName == "StopFailure"
            || hookEventName == "TeammateIdle"
            || hookEventName == "Elicitation" {
            return .claudeCode
        }
        if payload["model"] != nil, payload["turn_id"] != nil {
            return .codex
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}

nonisolated struct AgentAttentionWebhookEvent: Encodable, Sendable {
    let schemaVersion: String
    let source: String
    let event: String
    let type: String
    let hookEventName: String
    let occurredAt: String
    let application: String
    let appVersion: String
    let runtimeID: String?
    let sessionID: String?
    let threadID: String?
    let sessionTitle: String?
    let executor: String?
    let executorKind: String
    let status: String
    let taskID: String?
    let attentionKind: String?
    let notificationType: String?
    let message: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case event
        case type
        case hookEventName = "hook_event_name"
        case occurredAt = "occurred_at"
        case application
        case appVersion = "app_version"
        case runtimeID = "runtime_id"
        case sessionID = "session_id"
        case threadID = "thread-id"
        case sessionTitle = "session_title"
        case executor
        case executorKind = "executor_kind"
        case status
        case taskID = "task_id"
        case attentionKind = "attention_kind"
        case notificationType = "notification_type"
        case message
        case summary
    }
}

enum AgentAttentionWebhookClient {
    nonisolated enum DeliveryError: LocalizedError {
        case invalidURL
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(
                    localized: "agent-notification.settings.webhook-invalid-url",
                    defaultValue: "Enter a valid HTTP or HTTPS webhook URL."
                )
            case .rejected(let status): return "HTTP \(status)"
            }
        }
    }

    static func enqueue(
        kind: AgentAttentionWebhookEventKind,
        runtimeID: UUID?,
        sessionTitle: String?,
        executor: String?,
        status: String,
        taskID: String? = nil,
        attentionKind: String? = nil,
        summary: String? = nil
    ) {
        let preferences = AgentAttentionPreferencesStore.load()
        guard preferences.webhookEnabled,
              shouldDeliver(kind: kind, preferences: preferences) else { return }
        let event = makeEvent(
            kind: kind,
            runtimeID: runtimeID,
            sessionTitle: sessionTitle,
            executor: executor,
            status: status,
            taskID: taskID,
            attentionKind: attentionKind,
            summary: summary
        )
        Task.detached(priority: .utility) {
            try? await deliver(event, to: preferences.webhookURL)
        }
    }

    static func sendTest(to url: String) async throws {
        let event = makeEvent(
            kind: .test,
            runtimeID: nil,
            sessionTitle: nil,
            executor: nil,
            status: "test",
            taskID: nil,
            attentionKind: nil,
            summary: "WillDeep webhook test"
        )
        try await deliver(event, to: url)
    }

    nonisolated static func validatedURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else {
            throw DeliveryError.invalidURL
        }
        return url
    }

    nonisolated private static func shouldDeliver(
        kind: AgentAttentionWebhookEventKind,
        preferences: AgentAttentionPreferences
    ) -> Bool {
        switch kind {
        case .taskCompleted: return preferences.webhookOnTaskCompleted
        case .attentionRequired: return preferences.webhookOnAttentionRequired
        case .test: return true
        }
    }

    nonisolated static func makeEvent(
        kind: AgentAttentionWebhookEventKind,
        runtimeID: UUID?,
        sessionTitle: String?,
        executor: String?,
        status: String,
        taskID: String?,
        attentionKind: String?,
        summary: String?
    ) -> AgentAttentionWebhookEvent {
        let executorKind = AgentWebhookFormatDetector.executorSource(executor)
        let runtimeIdentifier = runtimeID?.uuidString
        return AgentAttentionWebhookEvent(
            schemaVersion: "willdeep.webhook.v1",
            source: AgentWebhookSource.willDeep.rawValue,
            event: kind.rawValue,
            type: compatibilityType(for: kind),
            hookEventName: hookEventName(for: kind, executor: executorKind),
            occurredAt: ISO8601DateFormatter().string(from: Date()),
            application: "WillDeep",
            appVersion: AgentNetworkSupport.appVersionHeaderValue,
            runtimeID: runtimeIdentifier,
            sessionID: runtimeIdentifier,
            threadID: runtimeIdentifier,
            sessionTitle: sessionTitle,
            executor: executor,
            executorKind: executorKind.rawValue,
            status: status,
            taskID: taskID,
            attentionKind: attentionKind,
            notificationType: notificationType(for: kind, status: status),
            message: kind == .attentionRequired ? summary : nil,
            summary: summary
        )
    }

    nonisolated private static func compatibilityType(for kind: AgentAttentionWebhookEventKind) -> String {
        switch kind {
        case .taskCompleted: return "agent-turn-complete"
        case .attentionRequired: return "approval-requested"
        case .test: return "test"
        }
    }

    nonisolated private static func hookEventName(
        for kind: AgentAttentionWebhookEventKind,
        executor: AgentWebhookSource
    ) -> String {
        switch kind {
        case .taskCompleted: return "Stop"
        case .attentionRequired:
            return executor == .codex ? "PermissionRequest" : "Notification"
        case .test: return "Notification"
        }
    }

    nonisolated private static func notificationType(
        for kind: AgentAttentionWebhookEventKind,
        status: String
    ) -> String? {
        guard kind == .attentionRequired else { return nil }
        switch status {
        case AgentToolCallStatus.pendingApproval.rawValue,
             AgentToolCallStatus.awaitingConfirm.rawValue:
            return "permission_prompt"
        case AgentToolCallStatus.awaitingUserAnswer.rawValue:
            return "elicitation_dialog"
        default:
            return "idle_prompt"
        }
    }

    nonisolated static func request(for event: AgentAttentionWebhookEvent, to rawURL: String) throws -> URLRequest {
        let url = try validatedURL(rawURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event.appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(
            "some.im/WillDeep-\(event.appVersion) (macOS)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(event.source, forHTTPHeaderField: "X-Agent-Source")
        request.setValue(event.executorKind, forHTTPHeaderField: "X-Agent-Executor")
        request.setValue(event.schemaVersion, forHTTPHeaderField: "X-Webhook-Schema")
        request.setValue(event.event, forHTTPHeaderField: "X-Agent-Event")
        request.httpBody = try JSONEncoder().encode(event)
        return request
    }

    nonisolated private static func deliver(_ event: AgentAttentionWebhookEvent, to rawURL: String) async throws {
        let request = try request(for: event, to: rawURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let (_, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DeliveryError.rejected((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

struct AgentAttentionSettingsView: View {
    @State private var preferences = AgentAttentionPreferencesStore.load()
    @State private var statusMessage = ""
    @State private var isTestingWebhook = false

    var body: some View {
        Form {
            Section(L10n.AgentNotifications.Settings.soundSection) {
                Picker(L10n.AgentNotifications.Settings.soundLabel, selection: $preferences.sound) {
                    ForEach(AgentNotificationSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }

                HStack {
                    Button(L10n.AgentNotifications.Settings.previewSound) {
                        AgentNotificationSoundManager.preview(preferences)
                    }
                    if preferences.sound == .custom {
                        Button(L10n.AgentNotifications.Settings.chooseAudio) {
                            chooseCustomSound()
                        }
                        Text(preferences.customSoundDisplayName.isEmpty
                             ? L10n.AgentNotifications.Settings.noAudioSelected
                             : preferences.customSoundDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Text(L10n.AgentNotifications.Settings.soundHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.AgentNotifications.Settings.webhookSection) {
                Toggle(L10n.AgentNotifications.Settings.webhookEnabled, isOn: $preferences.webhookEnabled)
                TextField(
                    L10n.AgentNotifications.Settings.webhookURL,
                    text: $preferences.webhookURL,
                    prompt: Text("http://127.0.0.1:8787/willdeep")
                )
                .textFieldStyle(.roundedBorder)

                Toggle(
                    L10n.AgentNotifications.Settings.webhookOnTaskCompleted,
                    isOn: $preferences.webhookOnTaskCompleted
                )
                Toggle(
                    L10n.AgentNotifications.Settings.webhookOnAttentionRequired,
                    isOn: $preferences.webhookOnAttentionRequired
                )

                HStack {
                    Button(L10n.AgentNotifications.Settings.save) {
                        savePreferences()
                    }
                    .buttonStyle(AgentAttentionPrimaryButtonStyle())

                    Button(L10n.AgentNotifications.Settings.testWebhook) {
                        testWebhook()
                    }
                    .disabled(isTestingWebhook || preferences.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isTestingWebhook {
                        ProgressView().controlSize(.small)
                    }
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(L10n.AgentNotifications.Settings.webhookPrivacyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("~/.willdeep/config.toml · [notifications]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: savePreferences)
    }

    private func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["mp3", "aiff", "aif", "wav", "caf", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try AgentNotificationSoundManager.importCustomSound(from: url)
            preferences.sound = .custom
            preferences.customSoundFile = imported.fileName
            preferences.customSoundDisplayName = imported.displayName
            try AgentAttentionPreferencesStore.save(preferences)
            statusMessage = L10n.AgentNotifications.Settings.saved
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func savePreferences() {
        do {
            try AgentAttentionPreferencesStore.save(preferences)
            statusMessage = L10n.AgentNotifications.Settings.saved
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testWebhook() {
        savePreferences()
        isTestingWebhook = true
        Task {
            do {
                try await AgentAttentionWebhookClient.sendTest(to: preferences.webhookURL)
                statusMessage = L10n.AgentNotifications.Settings.webhookTestSucceeded
            } catch {
                statusMessage = error.localizedDescription
            }
            isTestingWebhook = false
        }
    }
}
