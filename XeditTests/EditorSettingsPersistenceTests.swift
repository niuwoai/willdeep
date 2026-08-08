import Foundation
import Testing
@testable import WillDeep

/// The editor toggles (line numbers / current-line highlight) kept
/// "forgetting" their state across launches: with two live AppStates, the
/// adopting instance's async echo save could re-post a stale snapshot,
/// which reverted the editing instance's newer value AND cancelled its
/// pending save. Persistence is now synchronous in the property's didSet
/// and notification adoption never re-saves.
@MainActor
struct EditorSettingsPersistenceTests {
    private func withCleanStore(_ body: () throws -> Void) rethrows {
        let original = EditorSettingsStore.load()
        defer { EditorSettingsStore.save(original) }
        try body()
    }

    @Test("a toggle change is persisted synchronously")
    func toggleChangePersistsImmediately() {
        withCleanStore {
            var baseline = EditorSettings.default
            baseline.showsLineNumbers = false
            baseline.highlightsCurrentLine = false
            EditorSettingsStore.save(baseline)

            let appState = AppState()
            var next = appState.editorSettings
            next.showsLineNumbers = true
            appState.editorSettings = next.normalized()

            // No queue drain: the value must already be on disk. A pending
            // async save was droppable at app quit.
            #expect(EditorSettingsStore.load().showsLineNumbers == true)
        }
    }

    @Test("rapid successive toggles across two AppStates keep both changes")
    func crossInstanceEchoDoesNotRevertNewerEdits() {
        withCleanStore {
            var baseline = EditorSettings.default
            baseline.showsLineNumbers = false
            baseline.highlightsCurrentLine = false
            EditorSettingsStore.save(baseline)

            // Two long-lived instances, like the main editor window plus
            // the Settings window's fallback AppState.
            let main = AppState()
            let settings = AppState()

            var first = settings.editorSettings
            first.showsLineNumbers = true
            settings.editorSettings = first.normalized()

            var second = settings.editorSettings
            second.highlightsCurrentLine = true
            settings.editorSettings = second.normalized()

            let stored = EditorSettingsStore.load()
            #expect(stored.showsLineNumbers == true)
            #expect(stored.highlightsCurrentLine == true)
            // Both instances converge on the newest value; the old echo
            // pipeline could snap `settings` back to the first snapshot.
            #expect(settings.editorSettings.highlightsCurrentLine == true)
            #expect(main.editorSettings.showsLineNumbers == true)
            #expect(main.editorSettings.highlightsCurrentLine == true)
        }
    }

    @Test("adopting a broadcast value does not rewrite the store")
    func adoptionDoesNotEcho() {
        withCleanStore {
            var baseline = EditorSettings.default
            baseline.showsLineNumbers = false
            EditorSettingsStore.save(baseline)

            let adopter = AppState()
            var external = baseline
            external.showsLineNumbers = true
            // Simulate another process/instance broadcasting a change.
            EditorSettingsStore.save(external.normalized())

            #expect(adopter.editorSettings.showsLineNumbers == true)

            // The adopter must not have written anything of its own: the
            // store still carries exactly the broadcast value.
            #expect(EditorSettingsStore.load().showsLineNumbers == true)
        }
    }
}
