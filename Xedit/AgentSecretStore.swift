//
//  AgentSecretStore.swift
//  WillDeep
//
//  Local-only secret placeholders for Agent chat. The model sees stable
//  `${secret:...}` references; the real value stays in Keychain and is only
//  resolved at local tool-execution boundaries.
//

import Foundation

struct AgentSecretResolution: Equatable {
    var value: AgentJSONValue
    var secretValues: [String]
}

enum AgentSecretStore {
    nonisolated static let placeholderPrefix = "${secret:"
    nonisolated private static let keychainAccountPrefix = "agent-secret/"
    nonisolated private static let encodedValuePrefix = "base64:"

    nonisolated static func saveSecret(_ secret: String, label: String) -> String? {
        guard !secret.isEmpty else { return nil }
        let identifier = randomIdentifier()
        let encoded = Data(secret.utf8).base64EncodedString()
        AgentCredentialStore.save("\(encodedValuePrefix)\(encoded)", account: account(for: identifier))
        return placeholder(identifier: identifier)
    }

    nonisolated static func placeholder(identifier: String, transform: String? = nil) -> String {
        let suffix = transform.flatMap { $0.isEmpty ? nil : "|\($0)" } ?? ""
        return "\(placeholderPrefix)\(identifier)\(suffix)}"
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
            payload: redact(result.payload, secretValues: secretValues)
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
