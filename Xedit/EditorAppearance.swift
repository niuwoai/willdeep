//
//  EditorAppearance.swift
//  VeilWriter
//
//  Editor appearance settings, built-in fonts, and built-in color themes.
//

import AppKit
import Foundation

struct EditorSettings: Codable, Equatable {
    var fontID: String
    var fontSize: Double
    var themeID: String
    var showsLineNumbers: Bool
    var highlightsCurrentLine: Bool

    static let `default` = EditorSettings(
        fontID: EditorFontChoice.systemMono.id,
        fontSize: 13,
        themeID: EditorTheme.paper.id,
        showsLineNumbers: true,
        highlightsCurrentLine: true
    )
}

enum EditorSettingsStore {
    private static let key = "im.some.veilwriter.editorSettings.v1"

    static func load() -> EditorSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(EditorSettings.self, from: data) else {
            return .default
        }
        return settings.normalized()
    }

    static func save(_ settings: EditorSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized()) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension EditorSettings {
    func normalized() -> EditorSettings {
        var result = self
        if EditorFontChoice.byID(result.fontID) == nil {
            result.fontID = EditorSettings.default.fontID
        }
        if EditorTheme.byID(result.themeID) == nil {
            result.themeID = EditorSettings.default.themeID
        }
        result.fontSize = min(max(result.fontSize, 10), 28)
        return result
    }

    var fontChoice: EditorFontChoice {
        EditorFontChoice.byID(fontID) ?? .systemMono
    }

    var theme: EditorTheme {
        EditorTheme.byID(themeID) ?? .paper
    }

    func editorFont() -> NSFont {
        fontChoice.font(size: CGFloat(fontSize))
    }
}

struct EditorFontChoice: Identifiable, CaseIterable, Equatable {
    let id: String
    let displayName: String
    let postScriptName: String?

    static let systemMono = EditorFontChoice(
        id: "system-mono",
        displayName: "System Monospace",
        postScriptName: nil
    )

    static let menlo = EditorFontChoice(id: "menlo", displayName: "Menlo", postScriptName: "Menlo-Regular")
    static let monaco = EditorFontChoice(id: "monaco", displayName: "Monaco", postScriptName: "Monaco")
    static let courier = EditorFontChoice(id: "courier", displayName: "Courier", postScriptName: "Courier")

    static let allCases: [EditorFontChoice] = [
        .systemMono,
        .menlo,
        .monaco,
        .courier,
    ]

    static func byID(_ id: String) -> EditorFontChoice? {
        allCases.first { $0.id == id }
    }

    func font(size: CGFloat) -> NSFont {
        if let postScriptName, let font = NSFont(name: postScriptName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct EditorTheme: Identifiable, Equatable {
    let id: String
    let displayName: String
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let gutterBackgroundColor: NSColor
    let gutterTextColor: NSColor
    let currentLineBackgroundColor: NSColor
    let keywordColor: NSColor
    let stringColor: NSColor
    let commentColor: NSColor
    let numberColor: NSColor
    let typeNameColor: NSColor
    let headerColor: NSColor
    let insertionPointColor: NSColor

    static let paper = EditorTheme(
        id: "paper",
        displayName: "Paper",
        backgroundColor: NSColor(hex: 0xFBFAF7),
        foregroundColor: NSColor(hex: 0x242424),
        gutterBackgroundColor: NSColor(hex: 0xF0EEE8),
        gutterTextColor: NSColor(hex: 0x8A877F),
        currentLineBackgroundColor: NSColor(hex: 0xECE8DC),
        keywordColor: NSColor(hex: 0x0E5CAD),
        stringColor: NSColor(hex: 0xA13D2D),
        commentColor: NSColor(hex: 0x5F7A3D),
        numberColor: NSColor(hex: 0x9A5C00),
        typeNameColor: NSColor(hex: 0x00706D),
        headerColor: NSColor(hex: 0x7A3E91),
        insertionPointColor: NSColor(hex: 0x242424)
    )

    static let graphite = EditorTheme(
        id: "graphite",
        displayName: "Graphite",
        backgroundColor: NSColor(hex: 0x1F2227),
        foregroundColor: NSColor(hex: 0xE7E2D8),
        gutterBackgroundColor: NSColor(hex: 0x191C20),
        gutterTextColor: NSColor(hex: 0x767D88),
        currentLineBackgroundColor: NSColor(hex: 0x2B3037),
        keywordColor: NSColor(hex: 0x7BB2FF),
        stringColor: NSColor(hex: 0xF3A36D),
        commentColor: NSColor(hex: 0x86A36E),
        numberColor: NSColor(hex: 0xE6C15C),
        typeNameColor: NSColor(hex: 0x65D6C8),
        headerColor: NSColor(hex: 0xC997E8),
        insertionPointColor: NSColor(hex: 0xF4F0E8)
    )

    static let harbor = EditorTheme(
        id: "harbor",
        displayName: "Harbor",
        backgroundColor: NSColor(hex: 0xF7FBFC),
        foregroundColor: NSColor(hex: 0x1F2933),
        gutterBackgroundColor: NSColor(hex: 0xE8F0F2),
        gutterTextColor: NSColor(hex: 0x6B7B83),
        currentLineBackgroundColor: NSColor(hex: 0xDDECEF),
        keywordColor: NSColor(hex: 0x165BAA),
        stringColor: NSColor(hex: 0xB2454A),
        commentColor: NSColor(hex: 0x577C55),
        numberColor: NSColor(hex: 0xA05A17),
        typeNameColor: NSColor(hex: 0x00727C),
        headerColor: NSColor(hex: 0x7B4BB2),
        insertionPointColor: NSColor(hex: 0x1F2933)
    )

    static let ember = EditorTheme(
        id: "ember",
        displayName: "Ember",
        backgroundColor: NSColor(hex: 0x241F1D),
        foregroundColor: NSColor(hex: 0xF0E9DF),
        gutterBackgroundColor: NSColor(hex: 0x1C1816),
        gutterTextColor: NSColor(hex: 0x8A7A70),
        currentLineBackgroundColor: NSColor(hex: 0x332B27),
        keywordColor: NSColor(hex: 0x72B5F8),
        stringColor: NSColor(hex: 0xFFB36B),
        commentColor: NSColor(hex: 0x8DBB74),
        numberColor: NSColor(hex: 0xE7D36E),
        typeNameColor: NSColor(hex: 0x68D8CA),
        headerColor: NSColor(hex: 0xD08EE8),
        insertionPointColor: NSColor(hex: 0xF0E9DF)
    )

    static let all: [EditorTheme] = [
        .paper,
        .graphite,
        .harbor,
        .ember,
    ]

    static func byID(_ id: String) -> EditorTheme? {
        all.first { $0.id == id }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
