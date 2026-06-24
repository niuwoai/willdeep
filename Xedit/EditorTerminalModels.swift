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

    static var `default`: EditorTerminalSettings {
        EditorTerminalSettings(
            shellPath: "/bin/zsh",
            fontName: EditorTerminalFont.preferredDefaultID,
            fontSize: 12,
            colorSchemeID: EditorTerminalColorScheme.midnight.id,
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
        EditorTerminalFont.byID(fontName)?.font(size: CGFloat(fontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
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

    static func installedNerdFonts() -> [EditorTerminalFont] {
        nerdFontCandidates.compactMap { candidate in
            guard NSFont(name: candidate.family, size: 12) != nil else { return nil }
            return EditorTerminalFont(id: candidate.id, displayName: candidate.display, postScriptName: candidate.family)
        }
    }

    static var all: [EditorTerminalFont] {
        [.systemMono, .sfMono, .menlo, .monaco] + installedNerdFonts()
    }

    /// Default font id for a fresh terminal: prefer an installed Nerd
    /// Font so prompt themes render correctly out of the box; otherwise
    /// fall back to the system monospace.
    static var preferredDefaultID: String {
        installedNerdFonts().first?.id ?? systemMono.id
    }

    static func byID(_ id: String) -> EditorTerminalFont? {
        all.first { $0.id == id }
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

    static let all: [EditorTerminalColorScheme] = [.midnight, .graphite, .solar, .orchard]

    static func byID(_ id: String) -> EditorTerminalColorScheme? {
        all.first { $0.id == id }
    }
}

enum EditorTerminalEnvironmentParser {
    static func parse(_ text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            guard !key.isEmpty else { continue }
            environment[key] = value
        }
        return environment
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
                if current.path == stop || current.path == current.deletingLastPathComponent().path {
                    break
                }
                current.deleteLastPathComponent()
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
