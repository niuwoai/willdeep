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
    var lineHeightMultiple: Double
    var fileTreeFontSize: Double
    var fileTreeLineHeightMultiple: Double
    var themeID: String
    var showsLineNumbers: Bool
    var highlightsCurrentLine: Bool
    var preferredInspectorMode: EditorInspectorMode
    var inspectorPanelOrder: EditorInspectorPanelOrder
    var windowBackgroundImagePath: String?
    var windowBackgroundImageOpacity: Double
    var windowBackgroundImageMode: EditorBackgroundImageMode
    var windowBackgroundImageScale: Double
    var editorGlassEnabled: Bool
    var editorGlassMaterial: EditorGlassMaterial
    var editorGlassOpacity: Double
    var editorSurfaceOpacity: Double
    var trimsTrailingWhitespaceOnSave: Bool
    var ensuresFinalNewlineOnSave: Bool

    static let `default` = EditorSettings(
        fontID: EditorFontChoice.systemMono.id,
        fontSize: 13,
        lineHeightMultiple: 1.15,
        fileTreeFontSize: 12,
        fileTreeLineHeightMultiple: 1.25,
        themeID: EditorTheme.paper.id,
        showsLineNumbers: true,
        highlightsCurrentLine: true,
        preferredInspectorMode: .minimap,
        inspectorPanelOrder: .minimapFirst,
        windowBackgroundImagePath: nil,
        windowBackgroundImageOpacity: 0.28,
        windowBackgroundImageMode: .fill,
        windowBackgroundImageScale: 1.0,
        editorGlassEnabled: false,
        editorGlassMaterial: .contentBackground,
        editorGlassOpacity: 0.75,
        editorSurfaceOpacity: 0.82,
        trimsTrailingWhitespaceOnSave: false,
        ensuresFinalNewlineOnSave: false
    )

    init(
        fontID: String,
        fontSize: Double,
        lineHeightMultiple: Double,
        fileTreeFontSize: Double,
        fileTreeLineHeightMultiple: Double,
        themeID: String,
        showsLineNumbers: Bool,
        highlightsCurrentLine: Bool,
        preferredInspectorMode: EditorInspectorMode,
        inspectorPanelOrder: EditorInspectorPanelOrder,
        windowBackgroundImagePath: String?,
        windowBackgroundImageOpacity: Double,
        windowBackgroundImageMode: EditorBackgroundImageMode,
        windowBackgroundImageScale: Double,
        editorGlassEnabled: Bool,
        editorGlassMaterial: EditorGlassMaterial,
        editorGlassOpacity: Double,
        editorSurfaceOpacity: Double,
        trimsTrailingWhitespaceOnSave: Bool,
        ensuresFinalNewlineOnSave: Bool
    ) {
        self.fontID = fontID
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.fileTreeFontSize = fileTreeFontSize
        self.fileTreeLineHeightMultiple = fileTreeLineHeightMultiple
        self.themeID = themeID
        self.showsLineNumbers = showsLineNumbers
        self.highlightsCurrentLine = highlightsCurrentLine
        self.preferredInspectorMode = preferredInspectorMode
        self.inspectorPanelOrder = inspectorPanelOrder
        self.windowBackgroundImagePath = windowBackgroundImagePath
        self.windowBackgroundImageOpacity = windowBackgroundImageOpacity
        self.windowBackgroundImageMode = windowBackgroundImageMode
        self.windowBackgroundImageScale = windowBackgroundImageScale
        self.editorGlassEnabled = editorGlassEnabled
        self.editorGlassMaterial = editorGlassMaterial
        self.editorGlassOpacity = editorGlassOpacity
        self.editorSurfaceOpacity = editorSurfaceOpacity
        self.trimsTrailingWhitespaceOnSave = trimsTrailingWhitespaceOnSave
        self.ensuresFinalNewlineOnSave = ensuresFinalNewlineOnSave
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = EditorSettings.default

        fontID = try container.decodeIfPresent(String.self, forKey: .fontID) ?? fallback.fontID
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? fallback.fontSize
        lineHeightMultiple = try container.decodeIfPresent(Double.self, forKey: .lineHeightMultiple) ?? fallback.lineHeightMultiple
        fileTreeFontSize = try container.decodeIfPresent(Double.self, forKey: .fileTreeFontSize) ?? fallback.fileTreeFontSize
        fileTreeLineHeightMultiple = try container.decodeIfPresent(Double.self, forKey: .fileTreeLineHeightMultiple) ?? fallback.fileTreeLineHeightMultiple
        themeID = try container.decodeIfPresent(String.self, forKey: .themeID) ?? fallback.themeID
        showsLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showsLineNumbers) ?? fallback.showsLineNumbers
        highlightsCurrentLine = try container.decodeIfPresent(Bool.self, forKey: .highlightsCurrentLine) ?? fallback.highlightsCurrentLine
        preferredInspectorMode = try container.decodeIfPresent(EditorInspectorMode.self, forKey: .preferredInspectorMode) ?? fallback.preferredInspectorMode
        inspectorPanelOrder = try container.decodeIfPresent(EditorInspectorPanelOrder.self, forKey: .inspectorPanelOrder) ?? fallback.inspectorPanelOrder
        windowBackgroundImagePath = try container.decodeIfPresent(String.self, forKey: .windowBackgroundImagePath) ?? fallback.windowBackgroundImagePath
        windowBackgroundImageOpacity = try container.decodeIfPresent(Double.self, forKey: .windowBackgroundImageOpacity) ?? fallback.windowBackgroundImageOpacity
        windowBackgroundImageMode = try container.decodeIfPresent(EditorBackgroundImageMode.self, forKey: .windowBackgroundImageMode) ?? fallback.windowBackgroundImageMode
        windowBackgroundImageScale = try container.decodeIfPresent(Double.self, forKey: .windowBackgroundImageScale) ?? fallback.windowBackgroundImageScale
        editorGlassEnabled = try container.decodeIfPresent(Bool.self, forKey: .editorGlassEnabled) ?? fallback.editorGlassEnabled
        editorGlassMaterial = try container.decodeIfPresent(EditorGlassMaterial.self, forKey: .editorGlassMaterial) ?? fallback.editorGlassMaterial
        editorGlassOpacity = try container.decodeIfPresent(Double.self, forKey: .editorGlassOpacity) ?? fallback.editorGlassOpacity
        editorSurfaceOpacity = try container.decodeIfPresent(Double.self, forKey: .editorSurfaceOpacity) ?? fallback.editorSurfaceOpacity
        trimsTrailingWhitespaceOnSave = try container.decodeIfPresent(Bool.self, forKey: .trimsTrailingWhitespaceOnSave) ?? fallback.trimsTrailingWhitespaceOnSave
        ensuresFinalNewlineOnSave = try container.decodeIfPresent(Bool.self, forKey: .ensuresFinalNewlineOnSave) ?? fallback.ensuresFinalNewlineOnSave
    }
}

enum EditorSettingsStore {
    private static let key = "im.some.veilwriter.editorSettings.v1"
    static let didChangeNotification = Notification.Name("im.some.veilwriter.editorSettingsDidChange")

    static func load() -> EditorSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(EditorSettings.self, from: data) else {
            return .default
        }
        return settings.normalized()
    }

    static func save(_ settings: EditorSettings) {
        let normalizedSettings = settings.normalized()
        guard let data = try? JSONEncoder().encode(normalizedSettings) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: normalizedSettings)
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
        result.lineHeightMultiple = min(max(result.lineHeightMultiple, 1.0), 1.8)
        result.fileTreeFontSize = min(max(result.fileTreeFontSize, 10), 16)
        result.fileTreeLineHeightMultiple = min(max(result.fileTreeLineHeightMultiple, 1.0), 2.0)
        if let path = result.windowBackgroundImagePath?.trimmingCharacters(in: .whitespacesAndNewlines), path.isEmpty {
            result.windowBackgroundImagePath = nil
        }
        result.windowBackgroundImageOpacity = min(max(result.windowBackgroundImageOpacity, 0), 1)
        result.windowBackgroundImageScale = min(max(result.windowBackgroundImageScale, 0.25), 3)
        result.editorGlassOpacity = min(max(result.editorGlassOpacity, 0), 1)
        result.editorSurfaceOpacity = min(max(result.editorSurfaceOpacity, 0.25), 1)
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

    func editorParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(lineHeightMultiple)
        return style
    }

    var orderedInspectorModes: [EditorInspectorMode] {
        inspectorPanelOrder.modes
    }
}

enum EditorBackgroundImageMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch
    case center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill:
            return "Fill & Crop"
        case .fit:
            return "Fit"
        case .stretch:
            return "Stretch"
        case .center:
            return "Center"
        }
    }
}

enum EditorGlassMaterial: String, Codable, CaseIterable, Identifiable {
    case contentBackground
    case windowBackground
    case underWindowBackground
    case hudWindow
    case sidebar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .contentBackground:
            return "Content"
        case .windowBackground:
            return "Window"
        case .underWindowBackground:
            return "Under Window"
        case .hudWindow:
            return "HUD"
        case .sidebar:
            return "Sidebar"
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .contentBackground:
            return .contentBackground
        case .windowBackground:
            return .windowBackground
        case .underWindowBackground:
            return .underWindowBackground
        case .hudWindow:
            return .hudWindow
        case .sidebar:
            return .sidebar
        }
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
