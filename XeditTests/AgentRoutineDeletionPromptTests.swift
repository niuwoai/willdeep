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
        // The key is localized (en/es/fr/ja/zh-Hans), and the test host's
        // locale decides which value comes back — so assert the warning via
        // per-language markers instead of pinning the English source text.
        let permanentMarkers = [
            "cannot be undone", "no se puede deshacer", "irréversible",
            "取り消せません", "无法撤销",
        ]
        let stopMarkers = [
            "stop running", "dejará de ejecutarse", "cessera de s'exécuter",
            "実行を停止", "将停止运行",
        ]
        let lowered = message.lowercased()
        #expect(permanentMarkers.contains { lowered.contains($0.lowercased()) })
        #expect(stopMarkers.contains { lowered.contains($0.lowercased()) })
    }

    @Test("confirm and cancel are distinct labels")
    func buttonsAreDistinct() {
        #expect(L10n.Automation.deleteConfirm != L10n.Automation.deleteCancel)
        #expect(!L10n.Automation.deleteConfirm.isEmpty)
        #expect(!L10n.Automation.deleteCancel.isEmpty)
    }
}
