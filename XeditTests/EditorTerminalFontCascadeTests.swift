//
//  EditorTerminalFontCascadeTests.swift
//  WillDeepTests
//
//  Guard rails for the terminal font fallback chain: whatever base font the
//  user picks (including a Nerd Font, which ships no Han glyphs), the resolved
//  terminal font must cascade to a CJK-capable font so Chinese text doesn't
//  fall to .notdef and disappear.
//

import AppKit
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorTerminalFontCascadeTests {
    private static let cjkCascadeNames: Set<String> = [
        "PingFangSC-Regular",
        "HiraginoSansGB-W3",
        "STHeitiSC-Light",
    ]

    private func cascadeNames(of font: NSFont) -> [String] {
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []
        return cascade.compactMap(\.postscriptName)
    }

    @Test("terminal settings font cascades to a CJK-capable font")
    func terminalSettingsFontHasCJKCascade() {
        let font = EditorTerminalSettings.default.font
        let names = Set(cascadeNames(of: font))
        #expect(!names.isDisjoint(with: Self.cjkCascadeNames))
    }

    @Test("CJK cascade survives a custom font name")
    func customFontKeepsCJKCascade() {
        var settings = EditorTerminalSettings.default
        settings.customFontName = "Menlo-Regular"
        let names = Set(cascadeNames(of: settings.font))
        #expect(!names.isDisjoint(with: Self.cjkCascadeNames))
    }

    @Test("CJK cascade applies even when the base font is the Nerd Font itself")
    func nerdFontBaseStillGetsCJKCascade() throws {
        // The original bug: a Nerd Font base made withNerdFontFallback no-op,
        // leaving no CJK fallback at all. Only meaningful where a Nerd Font
        // is actually installed (dev machines); skip cleanly elsewhere.
        guard let nerd = EditorTerminalFont.nerdFallbackFont(size: 13) else { return }
        let resolved = EditorTerminalFont.withNerdFontFallback(nerd).withEditorCJKCascade()
        let names = Set(cascadeNames(of: resolved))
        #expect(!names.isDisjoint(with: Self.cjkCascadeNames))
    }

    @Test("Nerd Font fallback stays first, CJK cascade appended after")
    func nerdFallbackPrecedesCJKCascade() throws {
        guard let nerd = EditorTerminalFont.nerdFallbackFont(size: 13) else { return }
        let base = NSFont(name: "Monaco", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let names = cascadeNames(of: EditorTerminalFont.withNerdFontFallback(base).withEditorCJKCascade())
        let nerdIndex = try #require(names.firstIndex(of: nerd.fontName))
        let cjkIndex = try #require(names.firstIndex { Self.cjkCascadeNames.contains($0) })
        #expect(nerdIndex < cjkIndex)
    }

    @Test("applying the CJK cascade twice does not duplicate entries")
    func cjkCascadeIsIdempotent() {
        let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let names = cascadeNames(of: base.withEditorCJKCascade().withEditorCJKCascade())
        #expect(names.count == Set(names).count)
    }
}
