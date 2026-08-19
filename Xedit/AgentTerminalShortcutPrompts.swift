//
//  AgentTerminalShortcutPrompts.swift
//  WillDeep
//
//  Protected-prompt models for terminal shortcut playback. Split out of
//  AgentToolCallViews.swift, which had grown past the repository's hard
//  file-size limit.
//

import SwiftUI

/// Internal rather than private because `AgentToolCallCard` reads it; it was
/// file-private only because it used to live in the same file.
enum TerminalShortcutProtectedInputState: Equatable {
    case pending(TerminalShortcutProtectedPromptSet)
    case filled(TerminalShortcutProtectedPromptSet)
}

struct TerminalShortcutProtectedPromptSet: Identifiable, Equatable {
    let shortcutID: UUID
    let title: String
    let prompts: [TerminalShortcutProtectedPrompt]

    var id: UUID { shortcutID }

    static func parse(payload: String) -> TerminalShortcutProtectedPromptSet? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["id"] as? String,
              let shortcutID = UUID(uuidString: rawID) else {
            return nil
        }
        let title = (object["title"] as? String) ?? L10n.AgentTerminal.shortcutDefaultTitle
        guard let events = object["events"] as? [[String: Any]] else {
            return nil
        }
        let prompts = events.compactMap { event -> TerminalShortcutProtectedPrompt? in
            guard (event["kind"] as? String) == "protected_placeholder",
                  (event["needs_value"] as? Bool) == true,
                  let eventIndex = event["index"] as? Int else {
                return nil
            }
            let rawLabel = (event["placeholder"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = rawLabel?.isEmpty == false
                ? rawLabel!
                : L10n.AgentTerminal.shortcutPasswordDefaultLabel("\(eventIndex + 1)")
            return TerminalShortcutProtectedPrompt(eventIndex: eventIndex, label: label)
        }
        guard !prompts.isEmpty else { return nil }
        return TerminalShortcutProtectedPromptSet(shortcutID: shortcutID, title: title, prompts: prompts)
    }
}

struct TerminalShortcutProtectedPrompt: Identifiable, Equatable {
    let eventIndex: Int
    let label: String

    var id: Int { eventIndex }
}
