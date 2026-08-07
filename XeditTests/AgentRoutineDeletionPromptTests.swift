import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentRoutineDeletionPromptTests {
    @Test("the confirmation names the automation being deleted")
    func namedRoutineIsQuoted() {
        let name = AgentRoutineDeletionPrompt.displayName(rawName: "Daily PR summary")

        #expect(name == "Daily PR summary")
        #expect(L10n.Automation.deleteAlertMessage(name).contains("Daily PR summary"))
    }

    @Test("an unnamed automation still reads as a sentence")
    func unnamedRoutineFallsBack() {
        // Without this the dialog would say “” will stop running — the user
        // could not tell what they were about to destroy.
        for raw in ["", "   ", "\n\t"] {
            #expect(AgentRoutineDeletionPrompt.displayName(rawName: raw) == L10n.Automation.defaultName)
        }
    }

    @Test("surrounding whitespace is trimmed rather than quoted")
    func nameIsTrimmed() {
        #expect(AgentRoutineDeletionPrompt.displayName(rawName: "  Nightly build \n") == "Nightly build")
    }

    @Test("the message states that deletion cannot be undone")
    func messageWarnsItIsPermanent() {
        let message = L10n.Automation.deleteAlertMessage("Nightly build")

        // The point of the gate: the user learns the cost before confirming.
        #expect(message.lowercased().contains("cannot be undone"))
        #expect(message.contains("stop running"))
    }

    @Test("confirm and cancel are distinct labels")
    func buttonsAreDistinct() {
        #expect(L10n.Automation.deleteConfirm != L10n.Automation.deleteCancel)
        #expect(!L10n.Automation.deleteConfirm.isEmpty)
        #expect(!L10n.Automation.deleteCancel.isEmpty)
    }
}
