//
//  EditorAppearance.swift
//  WillDeep
//
//  Editor appearance settings, built-in fonts, and built-in color themes.
//

import AppKit
import Foundation
import SwiftUI

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
    var agentWallpaperEnabled: Bool
    var agentWallpaperGlassEnabled: Bool
    var agentWallpaperGlassMaterial: EditorGlassMaterial
    var agentWallpaperGlassOpacity: Double
    var agentWallpaperSurfaceOpacity: Double
    var editorGlassEnabled: Bool
    var editorGlassMaterial: EditorGlassMaterial
    var editorGlassOpacity: Double
    var editorSurfaceOpacity: Double
    var interfaceSkinID: String
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
        agentWallpaperEnabled: true,
        agentWallpaperGlassEnabled: false,
        agentWallpaperGlassMaterial: .contentBackground,
        agentWallpaperGlassOpacity: 0.45,
        agentWallpaperSurfaceOpacity: 0.58,
        editorGlassEnabled: false,
        editorGlassMaterial: .contentBackground,
        editorGlassOpacity: 0.75,
        editorSurfaceOpacity: 0.82,
        interfaceSkinID: EditorInterfaceSkin.system.id,
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
        agentWallpaperEnabled: Bool = true,
        agentWallpaperGlassEnabled: Bool = false,
        agentWallpaperGlassMaterial: EditorGlassMaterial = .contentBackground,
        agentWallpaperGlassOpacity: Double = 0.45,
        agentWallpaperSurfaceOpacity: Double = 0.58,
        editorGlassEnabled: Bool,
        editorGlassMaterial: EditorGlassMaterial,
        editorGlassOpacity: Double,
        editorSurfaceOpacity: Double,
        interfaceSkinID: String,
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
        self.agentWallpaperEnabled = agentWallpaperEnabled
        self.agentWallpaperGlassEnabled = agentWallpaperGlassEnabled
        self.agentWallpaperGlassMaterial = agentWallpaperGlassMaterial
        self.agentWallpaperGlassOpacity = agentWallpaperGlassOpacity
        self.agentWallpaperSurfaceOpacity = agentWallpaperSurfaceOpacity
        self.editorGlassEnabled = editorGlassEnabled
        self.editorGlassMaterial = editorGlassMaterial
        self.editorGlassOpacity = editorGlassOpacity
        self.editorSurfaceOpacity = editorSurfaceOpacity
        self.interfaceSkinID = interfaceSkinID
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
        agentWallpaperEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentWallpaperEnabled) ?? fallback.agentWallpaperEnabled
        agentWallpaperGlassEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentWallpaperGlassEnabled) ?? fallback.agentWallpaperGlassEnabled
        agentWallpaperGlassMaterial = try container.decodeIfPresent(EditorGlassMaterial.self, forKey: .agentWallpaperGlassMaterial) ?? fallback.agentWallpaperGlassMaterial
        agentWallpaperGlassOpacity = try container.decodeIfPresent(Double.self, forKey: .agentWallpaperGlassOpacity) ?? fallback.agentWallpaperGlassOpacity
        agentWallpaperSurfaceOpacity = try container.decodeIfPresent(Double.self, forKey: .agentWallpaperSurfaceOpacity) ?? fallback.agentWallpaperSurfaceOpacity
        editorGlassEnabled = try container.decodeIfPresent(Bool.self, forKey: .editorGlassEnabled) ?? fallback.editorGlassEnabled
        editorGlassMaterial = try container.decodeIfPresent(EditorGlassMaterial.self, forKey: .editorGlassMaterial) ?? fallback.editorGlassMaterial
        editorGlassOpacity = try container.decodeIfPresent(Double.self, forKey: .editorGlassOpacity) ?? fallback.editorGlassOpacity
        editorSurfaceOpacity = try container.decodeIfPresent(Double.self, forKey: .editorSurfaceOpacity) ?? fallback.editorSurfaceOpacity
        interfaceSkinID = try container.decodeIfPresent(String.self, forKey: .interfaceSkinID) ?? fallback.interfaceSkinID
        trimsTrailingWhitespaceOnSave = try container.decodeIfPresent(Bool.self, forKey: .trimsTrailingWhitespaceOnSave) ?? fallback.trimsTrailingWhitespaceOnSave
        ensuresFinalNewlineOnSave = try container.decodeIfPresent(Bool.self, forKey: .ensuresFinalNewlineOnSave) ?? fallback.ensuresFinalNewlineOnSave
    }
}

enum EditorSettingsStore {
    private static let key = "com.willdeep.editorSettings.v1"
    static let didChangeNotification = Notification.Name("com.willdeep.editorSettingsDidChange")

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
        if EditorInterfaceSkin.byID(result.interfaceSkinID) == nil {
            result.interfaceSkinID = EditorSettings.default.interfaceSkinID
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
        result.agentWallpaperGlassOpacity = min(max(result.agentWallpaperGlassOpacity, 0), 1)
        result.agentWallpaperSurfaceOpacity = min(max(result.agentWallpaperSurfaceOpacity, 0.2), 1)
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

    var interfaceSkin: EditorInterfaceSkin {
        EditorInterfaceSkin.byID(interfaceSkinID) ?? .system
    }

    var hasConfiguredWorkspaceWallpaper: Bool {
        guard let path = windowBackgroundImagePath else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasConfiguredAgentWallpaper: Bool {
        agentWallpaperEnabled && hasConfiguredWorkspaceWallpaper
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

struct EditorInterfaceSkin: Identifiable, CaseIterable {
    let id: String
    let symbolName: String
    let preferredColorScheme: ColorScheme?
    let recommendedThemeID: String
    let palette: EditorInterfaceSkinPalette

    static let system = EditorInterfaceSkin(
        id: "system",
        symbolName: "macwindow",
        preferredColorScheme: nil,
        recommendedThemeID: EditorTheme.paper.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
            ],
            sidebarColors: [
                Color(nsColor: .controlBackgroundColor),
                Color(nsColor: .controlBackgroundColor),
            ],
            panelFill: Color(nsColor: .controlBackgroundColor).opacity(0.62),
            controlFill: Color(nsColor: .textBackgroundColor),
            selectionFill: Color.accentColor.opacity(0.16),
            hoverFill: Color.primary.opacity(0.07),
            hairline: Color.secondary.opacity(0.14),
            primaryText: Color.primary,
            secondaryText: Color.secondary,
            accent: Color.accentColor,
            secondaryAccent: Color.secondary,
            previewBase: Color(nsColor: .textBackgroundColor),
            previewInk: Color.primary
        )
    )

    static let mistForest = EditorInterfaceSkin(
        id: "mist-forest",
        symbolName: "leaf",
        preferredColorScheme: .light,
        recommendedThemeID: EditorTheme.harbor.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(red: 0.94, green: 0.98, blue: 0.95),
                Color(red: 0.98, green: 0.95, blue: 0.91),
                Color(red: 0.90, green: 0.96, blue: 0.98),
            ],
            sidebarColors: [
                Color(red: 0.90, green: 0.97, blue: 0.92).opacity(0.94),
                Color(red: 0.98, green: 0.93, blue: 0.88).opacity(0.84),
            ],
            panelFill: Color.white.opacity(0.58),
            controlFill: Color.white.opacity(0.74),
            selectionFill: Color(red: 0.23, green: 0.48, blue: 0.42).opacity(0.18),
            hoverFill: Color(red: 0.77, green: 0.46, blue: 0.35).opacity(0.10),
            hairline: Color(red: 0.28, green: 0.43, blue: 0.36).opacity(0.18),
            primaryText: Color(red: 0.12, green: 0.23, blue: 0.20),
            secondaryText: Color(red: 0.34, green: 0.47, blue: 0.40),
            accent: Color(red: 0.23, green: 0.48, blue: 0.42),
            secondaryAccent: Color(red: 0.77, green: 0.46, blue: 0.35),
            previewBase: Color(red: 0.88, green: 0.95, blue: 0.88),
            previewInk: Color(red: 0.19, green: 0.34, blue: 0.30)
        )
    )

    static let ricePaper = EditorInterfaceSkin(
        id: "rice-paper",
        symbolName: "paintbrush.pointed",
        preferredColorScheme: .light,
        recommendedThemeID: EditorTheme.paper.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(red: 0.95, green: 0.93, blue: 0.86),
                Color(red: 0.88, green: 0.90, blue: 0.84),
                Color(red: 0.98, green: 0.95, blue: 0.89),
            ],
            sidebarColors: [
                Color(red: 0.89, green: 0.89, blue: 0.83).opacity(0.95),
                Color(red: 0.78, green: 0.82, blue: 0.78).opacity(0.84),
            ],
            panelFill: Color(red: 0.98, green: 0.96, blue: 0.90).opacity(0.52),
            controlFill: Color(red: 0.97, green: 0.95, blue: 0.88).opacity(0.78),
            selectionFill: Color(red: 0.18, green: 0.25, blue: 0.31).opacity(0.14),
            hoverFill: Color.black.opacity(0.07),
            hairline: Color(red: 0.22, green: 0.25, blue: 0.24).opacity(0.20),
            primaryText: Color(red: 0.17, green: 0.20, blue: 0.20),
            secondaryText: Color(red: 0.42, green: 0.43, blue: 0.38),
            accent: Color(red: 0.18, green: 0.25, blue: 0.31),
            secondaryAccent: Color(red: 0.58, green: 0.43, blue: 0.23),
            previewBase: Color(red: 0.91, green: 0.89, blue: 0.80),
            previewInk: Color(red: 0.20, green: 0.26, blue: 0.30)
        )
    )

    static let sciFiRaster = EditorInterfaceSkin(
        id: "sci-fi-raster",
        symbolName: "sparkles",
        preferredColorScheme: .dark,
        recommendedThemeID: EditorTheme.graphite.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(red: 0.07, green: 0.10, blue: 0.12),
                Color(red: 0.04, green: 0.17, blue: 0.18),
                Color(red: 0.12, green: 0.11, blue: 0.08),
            ],
            sidebarColors: [
                Color(red: 0.05, green: 0.12, blue: 0.14).opacity(0.97),
                Color(red: 0.10, green: 0.09, blue: 0.08).opacity(0.93),
            ],
            panelFill: Color(red: 0.07, green: 0.13, blue: 0.14).opacity(0.88),
            controlFill: Color(red: 0.12, green: 0.20, blue: 0.21).opacity(0.84),
            selectionFill: Color(red: 0.00, green: 0.58, blue: 0.64).opacity(0.23),
            hoverFill: Color(red: 0.00, green: 0.58, blue: 0.64).opacity(0.13),
            hairline: Color(red: 0.15, green: 0.84, blue: 0.88).opacity(0.24),
            primaryText: Color(red: 0.85, green: 0.96, blue: 0.95),
            secondaryText: Color(red: 0.48, green: 0.68, blue: 0.67),
            accent: Color(red: 0.00, green: 0.72, blue: 0.76),
            secondaryAccent: Color(red: 0.91, green: 0.45, blue: 0.18),
            previewBase: Color(red: 0.04, green: 0.12, blue: 0.14),
            previewInk: Color(red: 0.60, green: 0.95, blue: 0.91)
        )
    )

    static let midnightSlate = EditorInterfaceSkin(
        id: "midnight-slate",
        symbolName: "moon.stars",
        preferredColorScheme: .dark,
        recommendedThemeID: EditorTheme.graphite.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(red: 0.13, green: 0.17, blue: 0.25),
                Color(red: 0.16, green: 0.21, blue: 0.31),
                Color(red: 0.10, green: 0.13, blue: 0.20),
            ],
            sidebarColors: [
                Color(red: 0.11, green: 0.15, blue: 0.23).opacity(0.98),
                Color(red: 0.18, green: 0.22, blue: 0.31).opacity(0.92),
            ],
            panelFill: Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.90),
            controlFill: Color(red: 0.09, green: 0.12, blue: 0.18).opacity(0.85),
            selectionFill: Color(red: 0.42, green: 0.53, blue: 0.96).opacity(0.25),
            hoverFill: Color(red: 0.42, green: 0.53, blue: 0.96).opacity(0.13),
            hairline: Color(red: 0.50, green: 0.60, blue: 0.82).opacity(0.22),
            primaryText: Color(red: 0.88, green: 0.92, blue: 0.98),
            secondaryText: Color(red: 0.56, green: 0.62, blue: 0.72),
            accent: Color(red: 0.42, green: 0.53, blue: 0.96),
            secondaryAccent: Color(red: 0.54, green: 0.72, blue: 1.0),
            previewBase: Color(red: 0.08, green: 0.11, blue: 0.18),
            previewInk: Color(red: 0.72, green: 0.80, blue: 1.0)
        )
    )

    static let auroraNight = EditorInterfaceSkin(
        id: "aurora-night",
        symbolName: "waveform.path.ecg",
        preferredColorScheme: .dark,
        recommendedThemeID: EditorTheme.graphite.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(red: 0.04, green: 0.12, blue: 0.13),
                Color(red: 0.10, green: 0.24, blue: 0.20),
                Color(red: 0.03, green: 0.10, blue: 0.16),
            ],
            sidebarColors: [
                Color(red: 0.04, green: 0.16, blue: 0.15).opacity(0.98),
                Color(red: 0.08, green: 0.22, blue: 0.18).opacity(0.92),
            ],
            panelFill: Color(red: 0.05, green: 0.17, blue: 0.16).opacity(0.90),
            controlFill: Color(red: 0.03, green: 0.12, blue: 0.16).opacity(0.86),
            selectionFill: Color(red: 0.23, green: 0.86, blue: 0.55).opacity(0.23),
            hoverFill: Color(red: 0.16, green: 0.74, blue: 0.94).opacity(0.13),
            hairline: Color(red: 0.25, green: 0.92, blue: 0.70).opacity(0.22),
            primaryText: Color(red: 0.82, green: 0.98, blue: 0.92),
            secondaryText: Color(red: 0.45, green: 0.72, blue: 0.66),
            accent: Color(red: 0.23, green: 0.86, blue: 0.55),
            secondaryAccent: Color(red: 0.16, green: 0.74, blue: 0.94),
            previewBase: Color(red: 0.02, green: 0.12, blue: 0.15),
            previewInk: Color(red: 0.56, green: 0.96, blue: 0.78)
        )
    )

    static let emberGraphite = EditorInterfaceSkin(
        id: "ember-graphite",
        symbolName: "flame",
        preferredColorScheme: .dark,
        recommendedThemeID: EditorTheme.ember.id,
        palette: EditorInterfaceSkinPalette(
            windowColors: [
                Color(red: 0.20, green: 0.17, blue: 0.15),
                Color(red: 0.26, green: 0.22, blue: 0.18),
                Color(red: 0.14, green: 0.12, blue: 0.11),
            ],
            sidebarColors: [
                Color(red: 0.18, green: 0.15, blue: 0.13).opacity(0.98),
                Color(red: 0.26, green: 0.21, blue: 0.17).opacity(0.92),
            ],
            panelFill: Color(red: 0.20, green: 0.16, blue: 0.14).opacity(0.90),
            controlFill: Color(red: 0.10, green: 0.09, blue: 0.08).opacity(0.86),
            selectionFill: Color(red: 1.00, green: 0.58, blue: 0.18).opacity(0.24),
            hoverFill: Color(red: 1.00, green: 0.58, blue: 0.18).opacity(0.12),
            hairline: Color(red: 1.00, green: 0.66, blue: 0.30).opacity(0.20),
            primaryText: Color(red: 0.95, green: 0.91, blue: 0.84),
            secondaryText: Color(red: 0.65, green: 0.58, blue: 0.50),
            accent: Color(red: 1.00, green: 0.58, blue: 0.18),
            secondaryAccent: Color(red: 0.95, green: 0.38, blue: 0.14),
            previewBase: Color(red: 0.11, green: 0.09, blue: 0.08),
            previewInk: Color(red: 1.00, green: 0.69, blue: 0.35)
        )
    )

    static let allCases: [EditorInterfaceSkin] = [
        .system,
        .mistForest,
        .ricePaper,
        .sciFiRaster,
        .midnightSlate,
        .auroraNight,
        .emberGraphite,
    ]

    static func byID(_ id: String) -> EditorInterfaceSkin? {
        allCases.first { $0.id == id }
    }
}

struct EditorInterfaceSkinPalette {
    let windowColors: [Color]
    let sidebarColors: [Color]
    let panelFill: Color
    let controlFill: Color
    let selectionFill: Color
    let hoverFill: Color
    let hairline: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let secondaryAccent: Color
    let previewBase: Color
    let previewInk: Color
}

extension EditorInterfaceSkin {
    var windowBackground: LinearGradient {
        LinearGradient(colors: palette.windowColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var sidebarBackground: LinearGradient {
        LinearGradient(colors: palette.sidebarColors, startPoint: .top, endPoint: .bottom)
    }
}

enum EditorBackgroundImageMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch
    case center
    case tile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill:
            return L10n.Settings.backgroundImageModeFill
        case .fit:
            return L10n.Settings.backgroundImageModeFit
        case .stretch:
            return L10n.Settings.backgroundImageModeStretch
        case .center:
            return L10n.Settings.backgroundImageModeCenter
        case .tile:
            return L10n.Settings.backgroundImageModeTile
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
        currentLineBackgroundColor: NSColor(hex: 0x2F7D70).withAlphaComponent(0.10),
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

extension EditorTheme {
    /// Diff 高亮的新增/删除行颜色。主题结构体里没有专门的
    /// 红绿槽位，这里按背景亮度推导深浅两套（GitHub 风格）。
    private var hasDarkBackground: Bool {
        guard let rgb = backgroundColor.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5
    }

    var diffAddedColor: NSColor {
        hasDarkBackground ? NSColor(hex: 0x3FB950) : NSColor(hex: 0x1A7F37)
    }

    var diffRemovedColor: NSColor {
        hasDarkBackground ? NSColor(hex: 0xF85149) : NSColor(hex: 0xCF222E)
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
