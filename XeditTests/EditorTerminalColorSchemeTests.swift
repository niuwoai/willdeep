//
//  EditorTerminalColorSchemeTests.swift
//  WillDeepTests
//
//  Guard rails for terminal palettes and interface-skin terminal defaults.
//

import AppKit
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorTerminalColorSchemeTests {
    @Test("fresh terminal settings follow the app skin")
    func defaultTerminalSettingsFollowAppSkin() {
        #expect(EditorTerminalSettings.default.colorSchemeID == EditorTerminalSettings.followSkinColorSchemeID)
    }

    @Test("terminal settings offer several light-background schemes")
    func terminalSettingsOfferLightSchemes() {
        let lightSchemeIDs = Set(EditorTerminalColorScheme.all.compactMap { scheme -> String? in
            terminalBackgroundIsLight(scheme.background) ? scheme.id : nil
        })

        #expect(lightSchemeIDs.isSuperset(of: [
            EditorTerminalColorScheme.paperLight.id,
            EditorTerminalColorScheme.harborLight.id,
            EditorTerminalColorScheme.mintLight.id,
            EditorTerminalColorScheme.roseLight.id,
            EditorTerminalColorScheme.daylight.id,
            EditorTerminalColorScheme.solarizedLight.id,
            EditorTerminalColorScheme.githubLight.id,
        ]))
    }

    @Test("every interface skin maps to an available terminal scheme")
    func interfaceSkinsMapToAvailableTerminalSchemes() {
        for skin in EditorInterfaceSkin.allCases {
            #expect(
                EditorTerminalColorScheme.byID(skin.recommendedTerminalColorSchemeID) != nil,
                "Missing terminal scheme for skin \(skin.id)"
            )
        }
    }

    private func terminalBackgroundIsLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance >= 0.82
    }
}
