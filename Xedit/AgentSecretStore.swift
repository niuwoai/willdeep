//
//  AgentSecretStore.swift
//  WillDeep
//
//  Local-only secret placeholders for Agent chat. The model sees stable
//  `${secret:...}` references; the real value stays in Keychain and is only
//  resolved at local tool-execution boundaries.
//

import Foundation
import LocalAuthentication

struct AgentSecretResolution: Equatable {
    var value: AgentJSONValue
    var secretValues: [String]
}

struct AgentSecretInput: Equatable {
    var label: String
    var secret: String
}

struct AgentSavedSecret: Codable, Equatable, Identifiable {
    var identifier: String
    var label: String
    var updatedAt: Date

    var id: String { identifier }
    var placeholder: String { AgentSecretStore.placeholder(identifier: identifier) }
}

struct AgentSecretPlaceholderMatch: Equatable {
    var range: NSRange
    var identifier: String
}

enum AgentSecretStore {
    nonisolated static let maxBatchInsertCount = 3
    nonisolated static let placeholderPrefix = "${secret:"
    nonisolated static let maxAliasLength = 48
    nonisolated private static let keychainAccountPrefix = "agent-secret/"
    nonisolated private static let indexAccount = "agent-secret-index-v1"
    nonisolated private static let encodedValuePrefix = "base64:"

    nonisolated static func saveSecret(_ secret: String, label: String) -> String? {
        guard !secret.isEmpty else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = normalizedAlias(trimmedLabel)
        let encoded = Data(secret.utf8).base64EncodedString()
        AgentCredentialStore.save("\(encodedValuePrefix)\(encoded)", account: account(for: identifier))
        upsertIndexEntry(
            AgentSavedSecret(
                identifier: identifier,
                label: trimmedLabel.isEmpty ? identifier : trimmedLabel,
                updatedAt: Date()
            )
        )
        return placeholder(identifier: identifier)
    }

    nonisolated static func saveSecrets(_ inputs: [AgentSecretInput]) -> [String] {
        inputs
            .lazy
            .filter { !$0.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(maxBatchInsertCount)
            .compactMap { saveSecret($0.secret, label: $0.label) }
    }

    nonisolated static func placeholder(identifier: String, transform: String? = nil) -> String {
        let suffix = transform.flatMap { $0.isEmpty ? nil : "|\($0)" } ?? ""
        return "\(placeholderPrefix)\(identifier)\(suffix)}"
    }

    nonisolated static func normalizedAlias(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var needsSeparator = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !result.isEmpty, !result.hasSuffix("-") {
                    result.append("-")
                }
                result.append(String(scalar).lowercased())
                needsSeparator = false
            } else {
                needsSeparator = !result.isEmpty
            }
        }
        let capped = String(result.prefix(maxAliasLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return capped.isEmpty ? "secret-\(String(randomIdentifier().prefix(8)))" : capped
    }

    nonisolated static func savedSecrets() -> [AgentSavedSecret] {
        let indexed = loadIndex().filter { !loadSecret(identifier: $0.identifier).isEmpty }
        let indexedIdentifiers = Set(indexed.map(\.identifier))
        let legacy = AgentCredentialStore.accounts(matchingPrefix: keychainAccountPrefix)
            .map { String($0.dropFirst(keychainAccountPrefix.count)) }
            .filter { !indexedIdentifiers.contains($0) && !loadSecret(identifier: $0).isEmpty }
            .map {
                AgentSavedSecret(identifier: $0, label: "", updatedAt: .distantPast)
            }
        return (indexed + legacy).sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
    }

    /// Removes both the stored value and its index entry. Legacy entries
    /// created before the index existed have no index row; deleting the
    /// Keychain item is what makes them disappear from the list.
    nonisolated static func deleteSecret(identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AgentCredentialStore.delete(account: account(for: trimmed))
        let remaining = loadIndex().filter { $0.identifier != trimmed }
        saveIndex(remaining)
    }

    /// Renames the *display label* only.
    ///
    /// The identifier is baked into every `${secret:...}` placeholder already
    /// sitting in saved conversations, so renaming must never touch it —
    /// otherwise a rename silently breaks history. Returns false when the
    /// identifier has no stored value (nothing to rename).
    @discardableResult
    nonisolated static func renameSecret(identifier: String, label: String) -> Bool {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty,
              !trimmedLabel.isEmpty,
              !loadSecret(identifier: trimmedIdentifier).isEmpty else {
            return false
        }
        // Keep the original timestamp: the list is ordered by recency of the
        // *value*, and a rename would otherwise reshuffle the whole list.
        let existing = loadIndex().first { $0.identifier == trimmedIdentifier }
        upsertIndexEntry(
            AgentSavedSecret(
                identifier: trimmedIdentifier,
                label: trimmedLabel,
                updatedAt: existing?.updatedAt ?? Date()
            )
        )
        return true
    }

    /// Reveals a user-owned saved value only after macOS authenticates the
    /// device owner. `.deviceOwnerAuthentication` lets the OS choose Touch ID
    /// when available and fall back to the login password on older hardware.
    static func revealSecretForCopy(
        identifier: String,
        reason: String
    ) async -> String? {
        let context = LAContext()
        context.localizedCancelTitle = L10n.Automation.cancel
        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard authenticated else { return nil }
            let value = loadSecret(identifier: identifier)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    nonisolated static func placeholderMatches(in text: String) -> [AgentSecretPlaceholderMatch] {
        var matches: [AgentSecretPlaceholderMatch] = []
        var searchStart = text.startIndex
        while let start = text.range(of: placeholderPrefix, range: searchStart..<text.endIndex) {
            guard let close = text[start.upperBound...].firstIndex(of: "}") else { break }
            let rawBody = String(text[start.upperBound..<close])
            let identifier = rawBody.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            if !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let closedRange = start.lowerBound...close
                matches.append(
                    AgentSecretPlaceholderMatch(
                        range: NSRange(closedRange, in: text),
                        identifier: identifier
                    )
                )
            }
            searchStart = text.index(after: close)
        }
        return matches
    }

    nonisolated static func containsPlaceholder(_ value: String) -> Bool {
        value.contains(placeholderPrefix)
    }

    nonisolated static func resolve(_ arguments: [String: AgentJSONValue]) -> AgentSecretResolution {
        let resolved = resolve(.object(arguments))
        return AgentSecretResolution(value: resolved.value, secretValues: resolved.secretValues)
    }

    nonisolated static func resolve(_ value: AgentJSONValue) -> AgentSecretResolution {
        switch value {
        case .null, .bool, .number:
            return AgentSecretResolution(value: value, secretValues: [])
        case .string(let string):
            let resolved = resolvePlaceholders(in: string)
            return AgentSecretResolution(value: .string(resolved.text), secretValues: resolved.secretValues)
        case .array(let values):
            var secrets: [String] = []
            let mapped = values.map { item -> AgentJSONValue in
                let resolved = resolve(item)
                secrets.append(contentsOf: resolved.secretValues)
                return resolved.value
            }
            return AgentSecretResolution(value: .array(mapped), secretValues: uniqueNonEmpty(secrets))
        case .object(let dict):
            var secrets: [String] = []
            var mapped: [String: AgentJSONValue] = [:]
            for (key, item) in dict {
                let resolved = resolve(item)
                mapped[key] = resolved.value
                secrets.append(contentsOf: resolved.secretValues)
            }
            return AgentSecretResolution(value: .object(mapped), secretValues: uniqueNonEmpty(secrets))
        }
    }

    nonisolated static func resolvePlaceholders(in text: String) -> (text: String, secretValues: [String]) {
        var output = text
        var secrets: [String] = []
        var searchStart = output.startIndex
        while let start = output.range(of: placeholderPrefix, range: searchStart..<output.endIndex) {
            guard let close = output[start.upperBound...].firstIndex(of: "}") else { break }
            let rawBody = String(output[start.upperBound..<close])
            let parts = rawBody.split(separator: "|", maxSplits: 1).map(String.init)
            guard let identifier = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !identifier.isEmpty else {
                searchStart = output.index(after: close)
                continue
            }
            let transform = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = loadSecret(identifier: identifier)
            guard !secret.isEmpty else {
                searchStart = output.index(after: close)
                continue
            }
            secrets.append(secret)
            let replacement = transformed(secret, transform: transform)
            output.replaceSubrange(start.lowerBound...close, with: replacement)
            searchStart = output.index(start.lowerBound, offsetBy: replacement.count)
        }
        return (output, uniqueNonEmpty(secrets))
    }

    nonisolated static func redact(_ text: String, secretValues: [String]) -> String {
        var output = redactPlaceholders(in: text)
        for secret in uniqueNonEmpty(secretValues).sorted(by: { $0.count > $1.count }) {
            output = output.replacingOccurrences(of: secret, with: "[secret]")
            let encoded = urlEncoded(secret)
            if encoded != secret {
                output = output.replacingOccurrences(of: encoded, with: "[secret]")
            }
            if let queryAllowed = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               queryAllowed != secret,
               queryAllowed != encoded {
                output = output.replacingOccurrences(of: queryAllowed, with: "[secret]")
            }
            if let data = secret.data(using: .utf8) {
                let base64 = data.base64EncodedString()
                if base64.count >= 8 {
                    output = output.replacingOccurrences(of: base64, with: "[secret]")
                }
            }
        }
        return output
    }

    nonisolated static func redact(_ result: AgentToolResult, secretValues: [String]) -> AgentToolResult {
        AgentToolResult(
            summary: redact(result.summary, secretValues: secretValues),
            payload: redact(result.payload, secretValues: secretValues),
            references: result.references.map { reference in
                AgentSourceReference(
                    title: reference.title.map { redact($0, secretValues: secretValues) },
                    url: redact(reference.url, secretValues: secretValues),
                    toolName: reference.toolName
                )
            },
            // Image metadata never contains the resolved command secrets that
            // this pass is responsible for scrubbing. Preserve the attachments
            // when rebuilding the value; otherwise every image-producing tool
            // reports success while its screenshot silently disappears before
            // the tool message is persisted or rendered.
            images: result.images,
            commandExitCode: result.commandExitCode
        )
    }

    nonisolated static func redactPlaceholders(in text: String) -> String {
        var output = text
        var searchStart = output.startIndex
        while let start = output.range(of: placeholderPrefix, range: searchStart..<output.endIndex) {
            guard let close = output[start.upperBound...].firstIndex(of: "}") else { break }
            output.replaceSubrange(start.lowerBound...close, with: "[secret]")
            searchStart = output.index(start.lowerBound, offsetBy: "[secret]".count)
        }
        return output
    }

    nonisolated private static func account(for identifier: String) -> String {
        "\(keychainAccountPrefix)\(identifier)"
    }

    nonisolated private static func loadIndex() -> [AgentSavedSecret] {
        let raw = AgentCredentialStore.load(account: indexAccount)
        guard let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([AgentSavedSecret].self, from: data) else {
            return []
        }
        return entries
    }

    nonisolated private static func upsertIndexEntry(_ entry: AgentSavedSecret) {
        var entries = loadIndex().filter { $0.identifier != entry.identifier }
        entries.append(entry)
        saveIndex(entries)
    }

    nonisolated private static func saveIndex(_ entries: [AgentSavedSecret]) {
        guard let data = try? JSONEncoder().encode(entries),
              let raw = String(data: data, encoding: .utf8) else { return }
        AgentCredentialStore.save(raw, account: indexAccount)
    }

    nonisolated private static func loadSecret(identifier: String) -> String {
        let stored = AgentCredentialStore.load(account: account(for: identifier))
        guard stored.hasPrefix(encodedValuePrefix) else { return stored }
        let encoded = String(stored.dropFirst(encodedValuePrefix.count))
        guard let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    nonisolated private static func transformed(_ secret: String, transform: String?) -> String {
        switch transform?.lowercased() {
        case nil, "", "raw":
            return secret
        case "base64":
            return secret.data(using: .utf8)?.base64EncodedString() ?? secret
        case "urlencode":
            return urlEncoded(secret)
        default:
            return secret
        }
    }

    nonisolated private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated private static func randomIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    nonisolated private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
