//
//  AgentTranscriptModePresentation.swift
//  WillDeep
//
//  Composer modes change how the next turn executes; they must never change
//  which persisted conversation messages are presented. Keep this policy in a
//  small, testable boundary so future mode-specific UI cannot silently compact
//  or rewrite history again.
//

import Foundation

nonisolated enum AgentTranscriptModePresentation {
    static func modeInvariantMessages(from messages: [AgentMessage]) -> [AgentMessage] {
        messages
    }
}
