import Foundation
import Testing
@testable import WillDeep

/// The CoreGraphics key names what is *disabled*, so the mapping is
/// inverted — exactly the kind of thing that gets flipped by accident and
/// then ships as a toggle that does the opposite of its label.
@Suite
struct AgentFontSmoothingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("the toggle writes the inverted CoreGraphics key")
    func writesInvertedKey() {
        let name = "com.willdeep.tests.font-smoothing.write"
        let defaults = scratchDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        AgentFontSmoothing.apply(enabled: true, to: defaults)
        #expect(defaults.bool(forKey: AgentFontSmoothing.defaultsKey) == false)

        AgentFontSmoothing.apply(enabled: false, to: defaults)
        #expect(defaults.bool(forKey: AgentFontSmoothing.defaultsKey) == true)
    }

    /// The key CoreGraphics reads is the documented one. Getting this string
    /// wrong produces a switch that persists a preference nothing ever acts
    /// on — and it would look like it worked.
    @Test("the key is the one CoreGraphics reads")
    func usesTheDocumentedKey() {
        #expect(AgentFontSmoothing.defaultsKey == "CGFontRenderingFontSmoothingDisabled")
    }

    /// Smoothing on is what text looked like before macOS turned it off for
    /// layer-backed views, so an install that has never touched the setting
    /// gets it.
    @Test("smoothing defaults to on when nothing was ever saved")
    func defaultsToOn() {
        let name = "com.willdeep.tests.font-smoothing.default"
        let defaults = scratchDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        AgentSettingsStore._setTestDefaultsOverride(defaults)
        defer { AgentSettingsStore._setTestDefaultsOverride(nil) }

        #expect(AgentSettingsStore.loadFontSmoothingEnabled())

        AgentSettingsStore.saveFontSmoothingEnabled(false)
        #expect(!AgentSettingsStore.loadFontSmoothingEnabled())

        AgentSettingsStore.saveFontSmoothingEnabled(true)
        #expect(AgentSettingsStore.loadFontSmoothingEnabled())
    }
}
