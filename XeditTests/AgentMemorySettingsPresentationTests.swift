import Testing
@testable import WillDeep

@Suite("Agent memory settings presentation")
@MainActor
struct AgentMemorySettingsPresentationTests {
    @Test("Memory metadata labels use localized resources")
    func metadataLabelsAreLocalized() {
        let labels = [
            L10n.Settings.Memory.lifetimeName(.transient),
            L10n.Settings.Memory.lifetimeName(.longTerm),
            L10n.Settings.Memory.scopeName(.global),
            L10n.Settings.Memory.scopeName(.project),
            L10n.Settings.Memory.sourceName(.automatic),
            L10n.Settings.Memory.sourceName(.manual),
        ]

        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test("Memory text editors retain readable content padding")
    func textEditorContentPadding() {
        #expect(AgentMemorySettingsMetrics.textEditorContentPadding == 8)
    }
}
