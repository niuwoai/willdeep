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

nonisolated struct AgentDocumentSendPreview: Equatable, Sendable {
    let text: String
    let findings: [AgentSensitiveContentFinding]
}

nonisolated enum AgentSensitiveContentRedactor {
    private struct Rule: Sendable {
        let kind: String
        let regex: NSRegularExpression
    }

    private static let rules: [Rule] = [
        rule("private-key", #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#),
        rule("api-key", #"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b"#),
        rule("bearer-token", #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"#),
        rule("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
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
