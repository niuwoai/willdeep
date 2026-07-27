//
//  EditorTerminalModels.swift
//  WillDeep
//
//  Lightweight bottom terminal support for project commands.
//

import AppKit
import Combine
import Darwin
import Foundation

struct EditorTerminalSettings: Codable, Equatable {
    var shellPath: String
    var fontName: String
    var fontSize: Double
    var colorSchemeID: String
    var environmentText: String
    /// block / bar / underline. Decoded leniently (older sessions lack it).
    var cursorStyleID: String = EditorTerminalCursorStyle.block.id
    var cursorBlinks: Bool = true
    /// Exact font name the user typed in Settings. When non-empty it overrides
    /// `fontName` — the escape hatch for using any installed font we didn't
    /// auto-detect (most importantly a Nerd Font whose packaged name doesn't
    /// match our probes), which is what fixes powerline/icon glyphs rendering
    /// as boxes. Default-valued so older saved settings decode leniently.
    var customFontName: String = ""

    static var `default`: EditorTerminalSettings {
        EditorTerminalSettings(
            shellPath: "/bin/zsh",
            fontName: EditorTerminalFont.preferredDefaultID,
            fontSize: 12,
            colorSchemeID: EditorTerminalSettings.followSkinColorSchemeID,
            environmentText: "",
            cursorStyleID: EditorTerminalCursorStyle.block.id,
            cursorBlinks: true
        )
    }

    /// Sentinel colorSchemeID meaning "derive terminal colors from the
    /// current interface skin". Handled at apply time by the views that
    /// know the active skin; falls back to a fixed scheme in the model.
    static let followSkinColorSchemeID = "skin"

    var followsInterfaceSkin: Bool { colorSchemeID == Self.followSkinColorSchemeID }
}

/// Common local shells shown in Terminal settings. The text field beside the
/// picker remains the escape hatch for a shell installed at another path.
struct EditorTerminalShellOption: Identifiable, Hashable {
    let name: String
    let path: String

    var id: String { path }

    static let common: [EditorTerminalShellOption] = [
        EditorTerminalShellOption(name: "zsh", path: "/bin/zsh"),
        EditorTerminalShellOption(name: "bash", path: "/bin/bash"),
        EditorTerminalShellOption(name: "sh", path: "/bin/sh"),
        EditorTerminalShellOption(name: "fish (Homebrew)", path: "/opt/homebrew/bin/fish"),
        EditorTerminalShellOption(name: "fish (Intel Homebrew)", path: "/usr/local/bin/fish"),
        EditorTerminalShellOption(name: "ksh", path: "/bin/ksh"),
        EditorTerminalShellOption(name: "tcsh", path: "/bin/tcsh")
    ]

    static func options(for currentPath: String) -> [EditorTerminalShellOption] {
        let trimmed = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !common.contains(where: { $0.path == trimmed }) else {
            return common
        }
        return common + [EditorTerminalShellOption(name: trimmed, path: trimmed)]
    }
}

/// Cursor shapes the user can pick. Maps to SwiftTerm's CursorStyle
/// (combined with the blink flag) at apply time.
enum EditorTerminalCursorStyle: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        }
    }

    static func byID(_ id: String) -> EditorTerminalCursorStyle {
        EditorTerminalCursorStyle(rawValue: id) ?? .block
    }
}

enum EditorTerminalSettingsStore {
    private static let key = "com.willdeep.editorTerminalSettings.v1"

    static func load() -> EditorTerminalSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(EditorTerminalSettings.self, from: data) else {
            return .default
        }
        return settings.normalized()
    }

    static func save(_ settings: EditorTerminalSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized()) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension Notification.Name {
    /// Posted (with the originating AppState as `object`) after terminal
    /// settings are saved, so other live AppState instances — notably the
    /// Settings window's own instance vs. the one the agent window/terminal
    /// uses — reload and re-apply terminal appearance immediately.
    static let editorTerminalSettingsDidChange = Notification.Name("com.willdeep.editorTerminalSettingsDidChange")
}

extension EditorTerminalSettings {
    func normalized() -> EditorTerminalSettings {
        var result = self
        if EditorTerminalFont.byID(result.fontName) == nil {
            result.fontName = EditorTerminalSettings.default.fontName
        }
        if result.colorSchemeID != EditorTerminalSettings.followSkinColorSchemeID,
           EditorTerminalColorScheme.byID(result.colorSchemeID) == nil {
            result.colorSchemeID = EditorTerminalSettings.default.colorSchemeID
        }
        if EditorTerminalCursorStyle(rawValue: result.cursorStyleID) == nil {
            result.cursorStyleID = EditorTerminalCursorStyle.block.id
        }
        if result.shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.shellPath = EditorTerminalSettings.default.shellPath
        }
        result.fontSize = min(max(result.fontSize, 10), 20)
        return result
    }

    var cursorStyle: EditorTerminalCursorStyle {
        EditorTerminalCursorStyle.byID(cursorStyleID)
    }

    var font: NSFont {
        let size = CGFloat(fontSize)
        let base: NSFont
        // A user-typed custom name wins: it's the escape hatch for any
        // installed font we didn't enumerate, which is how a user fixes a
        // Nerd Font whose packaged name didn't match our probes.
        let custom = customFontName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, let f = NSFont(name: custom, size: size) {
            base = f
        } else {
            base = EditorTerminalFont.byID(fontName)?.font(size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // Keep the chosen font (e.g. Monaco) for normal text but cascade to an
        // installed Nerd Font for glyphs it lacks — so zsh prompt icons stop
        // rendering as boxes without forcing the whole terminal to a Nerd Font.
        // Then append the CJK cascade: Nerd Fonts carry no Han glyphs, so
        // without it a terminal set to a Nerd Font drops Chinese to .notdef.
        return EditorTerminalFont.withNerdFontFallback(base).withEditorCJKCascade()
    }

    var colorScheme: EditorTerminalColorScheme {
        EditorTerminalColorScheme.byID(colorSchemeID) ?? .midnight
    }

    var environment: [String: String] {
        EditorTerminalEnvironmentParser.parse(environmentText)
    }
}

struct EditorTerminalFont: Identifiable, Equatable {
    let id: String
    let displayName: String
    let postScriptName: String?

    static let systemMono = EditorTerminalFont(
        id: "system-mono",
        displayName: "System Mono",
        postScriptName: nil
    )
    static let menlo = EditorTerminalFont(id: "menlo", displayName: "Menlo", postScriptName: "Menlo-Regular")
    static let monaco = EditorTerminalFont(id: "monaco", displayName: "Monaco", postScriptName: "Monaco")
    static let sfMono = EditorTerminalFont(id: "sf-mono", displayName: "SF Mono", postScriptName: "SFMono-Regular")

    /// Common Nerd Fonts (Powerline/icon glyphs). Themes like
    /// powerlevel10k / starship render their separators and icons from a
    /// Nerd Font's private-use area; the plain monospace fonts above
    /// can't show those glyphs, so they appear as `?`/boxes. We probe
    /// for the popular ones and only offer the ones actually installed.
    private static let nerdFontCandidates: [(id: String, display: String, family: String)] = [
        ("meslo-nf", "MesloLGS Nerd Font", "MesloLGS NF"),
        ("jetbrainsmono-nf", "JetBrainsMono Nerd Font", "JetBrainsMono Nerd Font"),
        ("firacode-nf", "FiraCode Nerd Font", "FiraCode Nerd Font"),
        ("hack-nf", "Hack Nerd Font", "Hack Nerd Font"),
        ("sourcecodepro-nf", "SauceCodePro Nerd Font", "SauceCodePro Nerd Font")
    ]

    private static let installedNerdFontCache: [EditorTerminalFont] = discoverInstalledNerdFonts()

    static func installedNerdFonts() -> [EditorTerminalFont] {
        installedNerdFontCache
    }

    private static func discoverInstalledNerdFonts() -> [EditorTerminalFont] {
        var result: [EditorTerminalFont] = []
        var seenFamilies = Set<String>()
        // Known candidates first so they keep their stable ids — previously
        // saved settings (e.g. "meslo-nf") still resolve after an upgrade.
        for candidate in nerdFontCandidates where NSFont(name: candidate.family, size: 12) != nil {
            result.append(EditorTerminalFont(id: candidate.id, displayName: candidate.display, postScriptName: candidate.family))
            seenFamilies.insert(candidate.family)
        }
        // Then discover ANY other installed Nerd Font by scanning family names
        // for the "Nerd Font" convention, instead of depending on us having
        // hardcoded the exact packaged name. This is the real fix for "I
        // installed a Nerd Font but it never shows up / terminal still has
        // boxes": whatever variant the user installed now gets offered.
        for family in NSFontManager.shared.availableFontFamilies
        where family.localizedCaseInsensitiveContains("Nerd Font") && !seenFamilies.contains(family) {
            result.append(EditorTerminalFont(id: "nf:" + family, displayName: family, postScriptName: family))
            seenFamilies.insert(family)
        }
        return result
    }

    static var all: [EditorTerminalFont] {
        [.systemMono, .sfMono, .menlo, .monaco] + installedNerdFonts()
    }

    /// Default font id for a fresh terminal: Monaco (ships with macOS,
    /// clean classic terminal look). Note this is not a Nerd Font, so
    /// prompt themes (powerlevel10k / starship) that use Nerd Font icons
    /// will show placeholder boxes until the user picks an installed
    /// Nerd Font in Settings.
    static var preferredDefaultID: String {
        monaco.id
    }

    static func byID(_ id: String) -> EditorTerminalFont? {
        all.first { $0.id == id }
    }

    /// An installed Nerd Font to use as the cascade fallback, preferring
    /// MesloLGS NF (what `p10k configure` recommends and installs). Returns nil
    /// when no Nerd Font is installed — then nothing falls back and the user
    /// still sees boxes until they install one.
    static func nerdFallbackFont(size: CGFloat) -> NSFont? {
        let installed = installedNerdFonts()
        let chosen = installed.first { ($0.postScriptName ?? "").localizedCaseInsensitiveContains("Meslo") }
            ?? installed.first
        guard let name = chosen?.postScriptName else { return nil }
        return NSFont(name: name, size: size)
    }

    /// Return `font` with an installed Nerd Font appended as a cascade
    /// fallback. CoreText resolves a missing glyph (powerline separators, the
    /// Nerd Font private-use icons used by powerlevel10k / starship) from the
    /// fallback while ordinary text keeps using `font`. This is what makes the
    /// default Monaco show prompt icons correctly — same model as Ghostty's
    /// primary-font + fallback list. No-ops if the font already is the Nerd
    /// Font or none is installed.
    static func withNerdFontFallback(_ font: NSFont) -> NSFont {
        guard let fallback = nerdFallbackFont(size: font.pointSize),
              font.fontName != fallback.fontName else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([
            .cascadeList: [fallback.fontDescriptor]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    func font(size: CGFloat) -> NSFont {
        if let postScriptName, let font = NSFont(name: postScriptName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct EditorTerminalColorScheme: Identifiable, Equatable {
    let id: String
    let displayName: String
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    let muted: NSColor

    static let midnight = EditorTerminalColorScheme(
        id: "midnight",
        displayName: "Midnight",
        background: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1),
        foreground: NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.95, alpha: 1),
        accent: NSColor(calibratedRed: 0.41, green: 0.76, blue: 0.93, alpha: 1),
        muted: NSColor(calibratedRed: 0.50, green: 0.56, blue: 0.64, alpha: 1)
    )
    static let graphite = EditorTerminalColorScheme(
        id: "graphite",
        displayName: "Graphite",
        background: NSColor(calibratedWhite: 0.13, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.90, alpha: 1),
        accent: NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.88, alpha: 1),
        muted: NSColor(calibratedWhite: 0.58, alpha: 1)
    )
    static let solar = EditorTerminalColorScheme(
        id: "solar",
        displayName: "Solar",
        background: NSColor(calibratedRed: 0.99, green: 0.96, blue: 0.86, alpha: 1),
        foreground: NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.28, alpha: 1),
        accent: NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.66, alpha: 1),
        muted: NSColor(calibratedRed: 0.48, green: 0.54, blue: 0.55, alpha: 1)
    )
    static let orchard = EditorTerminalColorScheme(
        id: "orchard",
        displayName: "Orchard",
        background: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.08, alpha: 1),
        foreground: NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.86, alpha: 1),
        accent: NSColor(calibratedRed: 0.62, green: 0.82, blue: 0.46, alpha: 1),
        muted: NSColor(calibratedRed: 0.54, green: 0.62, blue: 0.52, alpha: 1)
    )

    // Light-background terminal schemes. These are intentionally solid and
    // high-contrast because the terminal does long-running logs, prompts, and
    // ANSI output; airy editor skins need a sturdier terminal surface.
    static let paperLight = EditorTerminalColorScheme(
        id: "paper-light", displayName: "Paper Light",
        background: hex(0xFAF7EF), foreground: hex(0x232628), accent: hex(0x2F7D70), muted: hex(0x7A766D)
    )
    static let harborLight = EditorTerminalColorScheme(
        id: "harbor-light", displayName: "Harbor Light",
        background: hex(0xF7FBFC), foreground: hex(0x1F2933), accent: hex(0x0F6E8C), muted: hex(0x6B7B83)
    )
    static let mintLight = EditorTerminalColorScheme(
        id: "mint-light", displayName: "Mist Mint",
        background: hex(0xF1FAF3), foreground: hex(0x18342D), accent: hex(0x2F7D58), muted: hex(0x5F746B)
    )
    static let roseLight = EditorTerminalColorScheme(
        id: "rose-light", displayName: "Rose Quartz",
        background: hex(0xFFF7F5), foreground: hex(0x302625), accent: hex(0xB45F5F), muted: hex(0x806D68)
    )
    static let daylight = EditorTerminalColorScheme(
        id: "daylight", displayName: "Daylight",
        background: hex(0xF8FAFC), foreground: hex(0x1E293B), accent: hex(0x2563EB), muted: hex(0x64748B)
    )
    static let solarizedLight = EditorTerminalColorScheme(
        id: "solarized-light", displayName: "Solarized Light",
        background: hex(0xFDF6E3), foreground: hex(0x657B83), accent: hex(0x268BD2), muted: hex(0x93A1A1)
    )
    static let githubLight = EditorTerminalColorScheme(
        id: "github-light", displayName: "GitHub Light",
        background: hex(0xFFFFFF), foreground: hex(0x24292F), accent: hex(0x0969DA), muted: hex(0x57606A)
    )

    // Popular dark schemes from the wider terminal/editor world, using their
    // canonical hex values. Only background / foreground / accent / muted are
    // themed here; the 16-color ANSI palette stays at SwiftTerm's default so
    // program colors (ls, git, grep) remain correct.
    static let solarizedDark = EditorTerminalColorScheme(
        id: "solarized-dark", displayName: "Solarized Dark",
        background: hex(0x002B36), foreground: hex(0x93A1A1), accent: hex(0x268BD2), muted: hex(0x586E75)
    )
    static let dracula = EditorTerminalColorScheme(
        id: "dracula", displayName: "Dracula",
        background: hex(0x282A36), foreground: hex(0xF8F8F2), accent: hex(0xBD93F9), muted: hex(0x6272A4)
    )
    static let oneDark = EditorTerminalColorScheme(
        id: "one-dark", displayName: "One Dark",
        background: hex(0x282C34), foreground: hex(0xABB2BF), accent: hex(0x61AFEF), muted: hex(0x5C6370)
    )
    static let gruvboxDark = EditorTerminalColorScheme(
        id: "gruvbox-dark", displayName: "Gruvbox Dark",
        background: hex(0x282828), foreground: hex(0xEBDBB2), accent: hex(0xFABD2F), muted: hex(0x928374)
    )
    static let nord = EditorTerminalColorScheme(
        id: "nord", displayName: "Nord",
        background: hex(0x2E3440), foreground: hex(0xD8DEE9), accent: hex(0x88C0D0), muted: hex(0x4C566A)
    )
    static let tokyoNight = EditorTerminalColorScheme(
        id: "tokyo-night", displayName: "Tokyo Night",
        background: hex(0x1A1B26), foreground: hex(0xC0CAF5), accent: hex(0x7AA2F7), muted: hex(0x565F89)
    )
    static let monokai = EditorTerminalColorScheme(
        id: "monokai", displayName: "Monokai",
        background: hex(0x272822), foreground: hex(0xF8F8F2), accent: hex(0xA6E22E), muted: hex(0x75715E)
    )
    static let rasterDark = EditorTerminalColorScheme(
        id: "raster-dark", displayName: "Raster Grid",
        background: hex(0x071B1E), foreground: hex(0xD6FFFA), accent: hex(0x00B8C8), muted: hex(0x5E8A8D)
    )
    static let auroraDark = EditorTerminalColorScheme(
        id: "aurora-dark", displayName: "Aurora Night",
        background: hex(0x031C20), foreground: hex(0xC9F7E6), accent: hex(0x3BE58A), muted: hex(0x5C8E86)
    )
    static let emberDark = EditorTerminalColorScheme(
        id: "ember-dark", displayName: "Ember Glow",
        background: hex(0x241B16), foreground: hex(0xF5EDE3), accent: hex(0xFF9B36), muted: hex(0x9A8171)
    )

    static let all: [EditorTerminalColorScheme] = [
        .paperLight, .harborLight, .mintLight, .roseLight, .daylight, .solarizedLight, .githubLight,
        .solar, .midnight, .graphite, .orchard,
        .solarizedDark, .dracula, .oneDark, .gruvboxDark, .nord, .tokyoNight, .monokai,
        .rasterDark, .auroraDark, .emberDark
    ]

    static func byID(_ id: String) -> EditorTerminalColorScheme? {
        all.first { $0.id == id }
    }

    /// Build an sRGB color from a 0xRRGGBB literal — keeps the canonical
    /// hex theme values readable instead of pre-divided float triples.
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum EditorTerminalEnvironmentParser {
    private struct Assignment {
        let key: String
        let value: String
        let expandsVariables: Bool
    }

    static func parse(_ text: String) -> [String: String] {
        merging(text, into: [:])
    }

    /// Applies KEY=value lines in source order, using the environment built by
    /// earlier lines when expanding `$VAR` / `${VAR}` references. Keeping the
    /// assignments ordered is important for shell-style PATH composition:
    ///
    ///     PATH=$JAVA_HOME/bin:$PATH
    ///     PATH=$MAVEN_HOME/bin:$PATH
    ///
    /// A dictionary-only parser silently discarded the first PATH assignment.
    static func merging(_ text: String, into base: [String: String]) -> [String: String] {
        var environment = base
        for assignment in assignments(in: text) {
            environment[assignment.key] = assignment.expandsVariables
                ? expandVariables(in: assignment.value, environment: environment)
                : assignment.value
        }
        return environment
    }

    private static func assignments(in text: String) -> [Assignment] {
        var result: [Assignment] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var expandsVariables = true
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                expandsVariables = first != "'"
                value.removeFirst()
                value.removeLast()
            }
            guard !key.isEmpty else { continue }
            result.append(Assignment(key: key, value: value, expandsVariables: expandsVariables))
        }
        return result
    }

    private static func expandVariables(
        in value: String,
        environment: [String: String]
    ) -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "$" else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }

            let afterDollar = value.index(after: index)
            guard afterDollar < value.endIndex else {
                result.append("$")
                break
            }

            if value[afterDollar] == "{" {
                let keyStart = value.index(after: afterDollar)
                guard let closingBrace = value[keyStart...].firstIndex(of: "}") else {
                    result.append("$")
                    index = afterDollar
                    continue
                }
                let key = String(value[keyStart..<closingBrace])
                if isValidVariableName(key) {
                    result.append(contentsOf: environment[key] ?? "")
                } else {
                    result.append(contentsOf: value[index...closingBrace])
                }
                index = value.index(after: closingBrace)
                continue
            }

            guard isVariableStart(value[afterDollar]) else {
                result.append("$")
                index = afterDollar
                continue
            }

            var keyEnd = value.index(after: afterDollar)
            while keyEnd < value.endIndex, isVariableContinuation(value[keyEnd]) {
                keyEnd = value.index(after: keyEnd)
            }
            let key = String(value[afterDollar..<keyEnd])
            result.append(contentsOf: environment[key] ?? "")
            index = keyEnd
        }

        return result
    }

    private static func isValidVariableName(_ value: String) -> Bool {
        guard let first = value.first, isVariableStart(first) else { return false }
        for character in value.dropFirst() where !isVariableContinuation(character) {
            return false
        }
        return true
    }

    private static func isVariableStart(_ character: Character) -> Bool {
        character == "_" || character.isASCII && character.isLetter
    }

    private static func isVariableContinuation(_ character: Character) -> Bool {
        isVariableStart(character) || character.isASCII && character.isNumber
    }
}

/// Builds the environment for WillDeep-owned interactive shells.
///
/// `CLAUDECODE=1` is intentionally limited to local user shells so `.zshrc`
/// can use the same lightweight prompt path it uses for Claude Code. Delegated
/// executor shells and SSH sessions must not receive the marker: otherwise a
/// Claude CLI launched by WillDeep can mistake itself for a nested session.
enum EditorTerminalLaunchEnvironment {
    static let claudeCodeCompatibilityKey = "CLAUDECODE"
    static let agentTerminalKey = "WILLDEEP_AGENT_TERMINAL"
    private static let enabledValue = "1"

    static func variables(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        settings: EditorTerminalSettings,
        injectClaudeCodeCompatibility: Bool,
        markAsAgentTerminal: Bool
    ) -> [String: String] {
        var environment = base
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        if injectClaudeCodeCompatibility {
            environment[claudeCodeCompatibilityKey] = enabledValue
        }
        if markAsAgentTerminal {
            environment[agentTerminalKey] = enabledValue
        }
        // Explicit Terminal settings remain the final authority, including
        // allowing a user to clear CLAUDECODE when launching Claude manually.
        return EditorTerminalEnvironmentParser.merging(
            settings.environmentText,
            into: environment
        )
    }

    static func array(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        settings: EditorTerminalSettings,
        injectClaudeCodeCompatibility: Bool,
        markAsAgentTerminal: Bool
    ) -> [String] {
        variables(
            from: base,
            settings: settings,
            injectClaudeCodeCompatibility: injectClaudeCodeCompatibility,
            markAsAgentTerminal: markAsAgentTerminal
        )
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
    }
}

struct EditorProjectCommand: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case packageScript
        case vite
        case goMain
        case custom
    }

    let id: String
    let title: String
    let command: String
    let workingDirectory: URL
    let kind: Kind
}

enum EditorProjectCommandResolver {
    static func commands(rootDirectory: URL?, openedFileURL: URL?) -> [EditorProjectCommand] {
        let roots = candidateRoots(rootDirectory: rootDirectory, openedFileURL: openedFileURL)
        var commands: [EditorProjectCommand] = []
        for root in roots {
            commands.append(contentsOf: packageCommands(root: root))
            commands.append(contentsOf: goCommands(root: root))
        }
        var seen: Set<String> = []
        return commands.filter { command in
            let key = "\(command.workingDirectory.path)|\(command.command)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func candidateRoots(rootDirectory: URL?, openedFileURL: URL?) -> [URL] {
        var roots: [URL] = []
        if let rootDirectory {
            roots.append(rootDirectory.standardizedFileURL)
        }
        if let openedFileURL {
            var current = openedFileURL.deletingLastPathComponent().standardizedFileURL
            let stop = rootDirectory?.standardizedFileURL.path
            while true {
                if !roots.contains(current) {
                    roots.append(current)
                }
                // Standardize the parent: on macOS 13 Foundation "/" becomes
                // "/.." otherwise, and the termination check never fires.
                let parent = current.deletingLastPathComponent().standardizedFileURL
                if current.path == stop || parent.path == current.path || parent.path.count >= current.path.count {
                    break
                }
                current = parent
            }
        }
        return roots
    }

    private static func packageCommands(root: URL) -> [EditorProjectCommand] {
        let packageURL = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let scripts = object["scripts"] as? [String: Any] ?? [:]
        let packageManager = packageManagerCommand(root: root)
        let sortedScripts = scripts.keys.sorted { lhs, rhs in
            scriptPriority(lhs) == scriptPriority(rhs) ? lhs < rhs : scriptPriority(lhs) < scriptPriority(rhs)
        }

        var result = sortedScripts.compactMap { name -> EditorProjectCommand? in
            guard scripts[name] is String else { return nil }
            let command = "\(packageManager) run \(shellEscaped(name))"
            let title = "package.json: \(name)"
            return EditorProjectCommand(
                id: "package:\(root.path):\(name)",
                title: title,
                command: command,
                workingDirectory: root,
                kind: .packageScript
            )
        }

        if isViteProject(object: object, scripts: scripts),
           scripts["dev"] == nil {
            result.insert(
                EditorProjectCommand(
                    id: "vite:\(root.path):dev",
                    title: "Vite dev",
                    command: "\(packageManager) exec vite --host 127.0.0.1",
                    workingDirectory: root,
                    kind: .vite
                ),
                at: 0
            )
        }
        return result
    }

    private static func goCommands(root: URL) -> [EditorProjectCommand] {
        var commands: [EditorProjectCommand] = []
        let rootMain = root.appendingPathComponent("main.go")
        if FileManager.default.fileExists(atPath: rootMain.path) {
            commands.append(EditorProjectCommand(
                id: "go:\(root.path):root",
                title: "Go run main.go",
                command: "go run main.go",
                workingDirectory: root,
                kind: .goMain
            ))
        }

        let cmdURL = root.appendingPathComponent("cmd", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cmdURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return commands
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let main = child.appendingPathComponent("main.go")
            guard FileManager.default.fileExists(atPath: main.path) else { continue }
            let rel = "./cmd/\(child.lastPathComponent)"
            commands.append(EditorProjectCommand(
                id: "go:\(root.path):\(child.lastPathComponent)",
                title: "Go run \(rel)",
                command: "go run \(rel)",
                workingDirectory: root,
                kind: .goMain
            ))
        }
        return commands
    }

    private static func packageManagerCommand(root: URL) -> String {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("bun.lockb").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("bun.lock").path) {
            return "bun"
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("package-lock.json").path) {
            return "npm"
        }
        return "yarn"
    }

    private static func isViteProject(object: [String: Any], scripts: [String: Any]) -> Bool {
        let dependencyKeys = ["dependencies", "devDependencies", "peerDependencies"]
        let hasViteDependency = dependencyKeys.contains { key in
            guard let deps = object[key] as? [String: Any] else { return false }
            return deps["vite"] != nil || deps.keys.contains { $0.hasPrefix("@vitejs/") }
        }
        let hasViteScript = scripts.values.contains { value in
            guard let string = value as? String else { return false }
            return string.contains("vite")
        }
        return hasViteDependency || hasViteScript
    }

    private static func scriptPriority(_ name: String) -> Int {
        switch name {
        case "dev": return 0
        case "start": return 1
        case "build": return 2
        case "test": return 3
        case "lint": return 4
        default: return 10
        }
    }

    private static func shellEscaped(_ value: String) -> String {
        guard value.range(of: #"^[A-Za-z0-9:_-]+$"#, options: .regularExpression) != nil else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
