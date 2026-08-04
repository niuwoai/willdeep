//
//  AgentShellCommandParser.swift
//  WillDeep
//
//  A conservative, operator-preserving parser for the shell subset used by
//  Agent authorization. It is intentionally not a full shell interpreter:
//  unsupported or malformed syntax returns nil and therefore falls back to
//  approval. Keeping connectors lets policy distinguish a normal sequence
//  from a pipeline, where `cd` runs in a subshell and must not change the
//  working directory used to inspect the next pipeline member.
//

import Foundation

nonisolated enum AgentShellConnector: String, Equatable, Sendable {
    case sequence
    case and
    case or
    case pipeline
    case background
}

nonisolated struct AgentShellSegment: Equatable, Sendable {
    let text: String
    let connectorFromPrevious: AgentShellConnector?
    let connectorToNext: AgentShellConnector?

    var runsInPipeline: Bool {
        connectorFromPrevious == .pipeline || connectorToNext == .pipeline
    }
}

nonisolated struct AgentShellCommandChain: Equatable, Sendable {
    let segments: [AgentShellSegment]
    let hasTrailingBackgroundJob: Bool

    var requiresBackgroundJudgment: Bool {
        hasTrailingBackgroundJob || segments.contains {
            $0.connectorFromPrevious == .background || $0.connectorToNext == .background
        }
    }
}

nonisolated enum AgentShellCommandParser {
    static func parse(_ command: String) -> AgentShellCommandChain? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var texts: [String] = []
        var connectors: [AgentShellConnector] = []
        var current = ""
        var activeQuote: Character?
        var escaped = false
        var skippingComment = false
        var hasTrailingBackgroundJob = false
        var index = command.startIndex

        func appendCurrent(connector: AgentShellConnector?) -> Bool {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return false }
            texts.append(value)
            current = ""
            if let connector {
                connectors.append(connector)
            }
            return true
        }

        while index < command.endIndex {
            let character = command[index]

            if skippingComment {
                if character == "\n" {
                    skippingComment = false
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !appendCurrent(connector: .sequence) {
                        return nil
                    }
                }
                index = command.index(after: index)
                continue
            }

            if escaped {
                if character == "\n" {
                    // A backslash-newline pair is a shell line continuation:
                    // neither byte belongs to the logical command. The
                    // backslash was retained on the previous iteration so
                    // escaped operators still remain visibly escaped.
                    if current.last == "\\" {
                        current.removeLast()
                    }
                } else {
                    current.append(character)
                }
                escaped = false
                index = command.index(after: index)
                continue
            }

            if character == "\\", activeQuote != "'" {
                escaped = true
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                }
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if character == "#", isCommentBoundary(current) {
                skippingComment = true
                index = command.index(after: index)
                continue
            }

            let nextIndex = command.index(after: index)
            let nextCharacter = nextIndex < command.endIndex ? command[nextIndex] : nil

            if character == "&", current.last == ">" {
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "&", nextCharacter == ">" {
                current.append(character)
                index = nextIndex
                continue
            }

            if character == "&", nextCharacter == "&" {
                guard appendCurrent(connector: .and) else { return nil }
                index = command.index(after: nextIndex)
                continue
            }
            if character == "|", nextCharacter == "|" {
                guard appendCurrent(connector: .or) else { return nil }
                index = command.index(after: nextIndex)
                continue
            }
            if character == "|" {
                guard appendCurrent(connector: .pipeline) else { return nil }
                if nextCharacter == "&" {
                    index = command.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }
            if character == ";" || character == "\n" {
                let hasContent = !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasContent, !appendCurrent(connector: .sequence) {
                    return nil
                }
                index = nextIndex
                continue
            }
            if character == "&" {
                guard appendCurrent(connector: .background) else { return nil }
                hasTrailingBackgroundJob = true
                index = nextIndex
                continue
            }

            current.append(character)
            index = nextIndex
        }

        guard activeQuote == nil, !escaped else { return nil }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            texts.append(tail)
            hasTrailingBackgroundJob = false
        } else if connectors.last != .background {
            while connectors.last == .sequence {
                connectors.removeLast()
            }
        }

        guard !texts.isEmpty else { return nil }
        guard connectors.count == texts.count - 1
                || (connectors.count == texts.count && connectors.last == .background) else {
            return nil
        }

        if connectors.count == texts.count, connectors.last == .background {
            connectors.removeLast()
            hasTrailingBackgroundJob = true
        }

        let segments = texts.enumerated().map { offset, text in
            AgentShellSegment(
                text: text,
                connectorFromPrevious: offset > 0 ? connectors[offset - 1] : nil,
                connectorToNext: offset < connectors.count ? connectors[offset] : nil
            )
        }
        return AgentShellCommandChain(
            segments: segments,
            hasTrailingBackgroundJob: hasTrailingBackgroundJob
        )
    }

    /// Shell metacharacters inside quotes are data. Command substitution is
    /// still active inside double quotes, so only single-quoted contents are
    /// ignored by `containsExecutableSubstitution`.
    static func containsExecutableSubstitution(_ command: String) -> Bool {
        var activeQuote: Character?
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if escaped {
                escaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\", activeQuote != "'" {
                escaped = true
                index = command.index(after: index)
                continue
            }
            if character == "'", activeQuote != "\"" {
                activeQuote = activeQuote == "'" ? nil : "'"
                index = command.index(after: index)
                continue
            }
            if character == "\"", activeQuote != "'" {
                activeQuote = activeQuote == "\"" ? nil : "\""
                index = command.index(after: index)
                continue
            }
            if activeQuote != "'" {
                let next = command.index(after: index)
                if character == "`" || (next < command.endIndex
                    && ((character == "$" && command[next] == "(")
                        || (character == "<" && command[next] == "("))) {
                    return true
                }
            }
            index = command.index(after: index)
        }
        return activeQuote != nil || escaped
    }

    static func unquotedText(_ command: String) -> String? {
        var output = ""
        var activeQuote: Character?
        var escaped = false
        for character in command {
            if escaped {
                if activeQuote == nil {
                    output.append(" ")
                }
                escaped = false
                continue
            }
            if character == "\\", activeQuote != "'" {
                escaped = true
                if activeQuote == nil {
                    output.append(" ")
                }
                continue
            }
            if character == "'", activeQuote != "\"" {
                activeQuote = activeQuote == "'" ? nil : "'"
                output.append(" ")
                continue
            }
            if character == "\"", activeQuote != "'" {
                activeQuote = activeQuote == "\"" ? nil : "\""
                output.append(" ")
                continue
            }
            output.append(activeQuote == nil ? character : " ")
        }
        guard activeQuote == nil, !escaped else { return nil }
        return output
    }

    private static func isCommentBoundary(_ current: String) -> Bool {
        guard let last = current.last else { return true }
        return last.isWhitespace
    }
}
