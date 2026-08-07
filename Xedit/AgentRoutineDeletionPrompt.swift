//
//  AgentRoutineDeletionPrompt.swift
//  WillDeep
//
//  Naming for the automation-deletion confirmation.
//
//  Split out as a pure function so the confirmation copy can be tested
//  without standing up the settings page: the whole point of the dialog is
//  that the user can tell *which* automation is about to be destroyed, and
//  an unnamed automation must not degrade that into an empty quotation.
//

import Foundation

nonisolated enum AgentRoutineDeletionPrompt {
    /// The name to show in the confirmation. Falls back to the standard
    /// untitled label so the sentence never reads as “” will stop running.
    static func displayName(for routine: AgentRoutine) -> String {
        displayName(rawName: routine.name)
    }

    static func displayName(rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.Automation.defaultName : trimmed
    }
}
