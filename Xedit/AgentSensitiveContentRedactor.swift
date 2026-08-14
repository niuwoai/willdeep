//
//  AgentSensitiveContentRedactor.swift
//  WillDeep
//
//  Conservative local detection/redaction for attachment context before it
//  leaves the Mac. Local previews and citation windows keep the original.
//

import Foundation

nonisolated struct AgentSensitiveContentFinding: Equatable, Sendable {
    let kind: String
    let count: Int
}

nonisolated struct AgentDocumentSendPreview: Equatable, Sendable, Identifiable {
    /// Stable identity so the composer can present this via `.sheet(item:)`
    /// instead of `.sheet(isPresented:)`. The bool-plus-separate-`@State`
    /// form raced: the sheet body built its `if let preview` before the
    /// `preview` assignment was observed, so the modal opened empty.
    let id = UUID()
    let text: String
    let findings: [AgentSensitiveContentFinding]
}

nonisolated enum AgentSensitiveContentRedactor {
    private struct Rule: Sendable {
        let kind: String
        let regex: NSRegularExpression
    }

    /// Credential-shaped values that must never be persisted or sent without
    /// an explicit redaction pass. Accept both `sk-...` and `sk_...`; several
    /// providers use the underscore form and alphabetic-only bodies are valid.
    private static let credentialRules: [Rule] = [
        rule("private-key", #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#),
        rule("api-key", #"\b(?:sk[-_][A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b"#),
        rule("bearer-token", #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"#),
        rule("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
    ]

    private static let rules: [Rule] = credentialRules + [
        rule("email", #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, options: [.caseInsensitive]),
        rule("cn-phone", #"(?<!\d)1[3-9]\d{9}(?!\d)"#),
        rule("cn-id", #"(?<!\d)\d{17}[0-9Xx](?!\d)"#),
    ]

    static func findings(in text: String) -> [AgentSensitiveContentFinding] {
        rules.compactMap { rule in
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let count = rule.regex.numberOfMatches(in: text, range: range)
            return count > 0 ? AgentSensitiveContentFinding(kind: rule.kind, count: count) : nil
        }
    }

    static func redact(_ text: String) -> String {
        redact(text, using: rules)
    }

    /// Persistence uses credential-only redaction: it must scrub keys and
    /// tokens without destroying ordinary conversation data such as an email
    /// address or phone number that the operator intentionally discussed.
    static func redactCredentials(_ text: String) -> String {
        redact(text, using: credentialRules)
    }

    private static func redact(_ text: String, using rules: [Rule]) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[REDACTED:\(rule.kind.uppercased())]"
            )
        }
        return result
    }

    private static func rule(
        _ kind: String,
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> Rule {
        Rule(kind: kind, regex: try! NSRegularExpression(pattern: pattern, options: options))
    }
}
