//
//  AgentFontSmoothing.swift
//  WillDeep
//
//  macOS 10.14 turned subpixel antialiasing off for layer-backed views, and
//  every SwiftUI window is layer-backed. On a non-Retina display that is the
//  difference between text that looks like the rest of the system and text
//  that looks thin and washed out; on Retina most people cannot tell. Apple's
//  documented opt-in is a single user default, `CGFontRenderingFontSmoothingDisabled`,
//  read out of the app's own domain.
//
//  Two honest limits, both surfaced in the settings copy rather than hidden:
//
//   - CoreGraphics reads the default lazily and caches it, so flipping the
//     switch does not repaint what is already on screen. A relaunch is what
//     makes it certain.
//   - It is a request, not a guarantee. Whether smoothing actually changes
//     any pixels depends on the display; on a Retina panel it may not.
//

import Foundation

enum AgentFontSmoothing {
    /// CoreGraphics reads this key out of the app's own defaults domain.
    /// The sense is inverted — the key names what is *disabled* — which is
    /// exactly the kind of thing that gets flipped by accident, so the
    /// mapping lives in one function with a test on it.
    static let defaultsKey = "CGFontRenderingFontSmoothingDisabled"

    static func apply(enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: defaultsKey)
    }

    /// Called from the app's own `init`, which is the earliest hook that runs
    /// before any scene is built. Later than this and the first window may
    /// already have drawn with the previous value.
    static func applyPersistedSetting() {
        apply(enabled: AgentSettingsStore.loadFontSmoothingEnabled())
    }
}
