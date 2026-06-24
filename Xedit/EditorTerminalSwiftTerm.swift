//
//  EditorTerminalSwiftTerm.swift
//  WillDeep
//
//  SwiftTerm-backed editor bottom terminal + shared terminal appearance
//  (font / colors / cursor style / interface-skin palette) used by both
//  the editor terminal and the Agent side-panel terminal tabs.
//

import AppKit
import Combine
import SwiftTerm
import SwiftUI

// MARK: - Shared appearance

/// Colors pulled from the active interface skin, passed in when the
/// terminal color scheme is "Follow App Skin". Kept as NSColors so the
/// model/appearance layer doesn't depend on the skin types.
struct TerminalSkinColors {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor

    /// Resolve from a SwiftUI-based skin palette. `base`/`ink` come from the
    /// skin's opaque preview surface so the terminal background is solid.
    @MainActor
    static func from(palette: EditorInterfaceSkinPalette) -> TerminalSkinColors {
        TerminalSkinColors(
            background: NSColor(palette.previewBase),
            foreground: NSColor(palette.previewInk),
            cursor: NSColor(palette.accent)
        )
    }
}

enum TerminalAppearance {
    /// Apply font, colors, and cursor style to a SwiftTerm view. When the
    /// scheme is "Follow App Skin", `skin` carries the resolved colors;
    /// otherwise the fixed `EditorTerminalColorScheme` is used. The ANSI
    /// 16-color palette is deliberately left at SwiftTerm's default so
    /// program colors (ls, git, grep, …) stay correct and readable — the
    /// skin only drives background / foreground / cursor.
    @MainActor
    static func apply(
        to view: TerminalView,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) {
        view.font = settings.font

        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        if settings.followsInterfaceSkin, let skin {
            background = skin.background
            foreground = skin.foreground
            cursor = skin.cursor
        } else {
            let scheme = settings.colorScheme
            background = scheme.background
            foreground = scheme.foreground
            cursor = scheme.accent
        }
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = cursor

        view.getTerminal().setCursorStyle(
            swiftTermCursorStyle(settings.cursorStyle, blinks: settings.cursorBlinks)
        )
    }

    static func swiftTermCursorStyle(_ style: EditorTerminalCursorStyle, blinks: Bool) -> CursorStyle {
        switch style {
        case .block: return blinks ? .blinkBlock : .steadyBlock
        case .bar: return blinks ? .blinkBar : .steadyBar
        case .underline: return blinks ? .blinkUnderline : .steadyUnderline
        }
    }
}

// MARK: - Editor terminal session (SwiftTerm)

/// The editor's bottom-pane terminal, rebuilt on SwiftTerm so it's a real
/// VT100/ANSI terminal (matching the Agent side-panel terminal). Single
/// session; keeps the small lifecycle surface the pane + AppState use.
@MainActor
final class EditorTerminalSession: ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var workingDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var isRunning = false

    /// Created lazily on first access (i.e. when the editor terminal pane
    /// is actually shown). AppState holds an EditorTerminalSession as a
    /// stored property, so eager creation here would spin up a SwiftTerm
    /// (Metal-backed) NSView for every AppState() — including the many
    /// constructed in headless unit tests, where GPU/Metal view init is
    /// unsafe and crashed CI. Lazy keeps test-time AppState() cheap and
    /// view-free.
    lazy var terminalView: AgentLocalProcessTerminalView = {
        let view = AgentLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        view.processDelegate = self
        return view
    }()

    init() {}

    func setWorkingDirectory(_ url: URL) {
        workingDirectoryPath = url.standardizedFileURL.path
    }

    func startShellIfNeeded(settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        guard !isRunning else { return }
        let normalized = settings.normalized()
        TerminalAppearance.apply(to: terminalView, settings: normalized, skin: skin)
        let shell = Self.loginShellPath(normalized.shellPath)
        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: Self.environmentArray(settings: normalized),
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: workingDirectoryPath.isEmpty ? nil : workingDirectoryPath
        )
        isRunning = true
    }

    func run(_ command: String, settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startShellIfNeeded(settings: settings, skin: skin)
        terminalView.send(txt: trimmed + "\n")
    }

    func clear() {
        // RIS-style clear + scrollback wipe.
        terminalView.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
    }

    func stop() {
        guard isRunning else { return }
        terminalView.terminate()
        isRunning = false
    }

    func applyAppearance(settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        TerminalAppearance.apply(to: terminalView, settings: settings.normalized(), skin: skin)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory, !directory.isEmpty { workingDirectoryPath = directory }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
    }

    private static func loginShellPath(_ configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    private static func environmentArray(settings: EditorTerminalSettings) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        for (key, value) in settings.environment {
            environment[key] = value
        }
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - SwiftUI host

/// Mounts the editor session's SwiftTerm view (owned by the session, so
/// it survives SwiftUI re-renders).
struct EditorTerminalSurfaceView: NSViewRepresentable {
    let terminalView: AgentLocalProcessTerminalView

    func makeNSView(context: Context) -> AgentLocalProcessTerminalView {
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: AgentLocalProcessTerminalView, context: Context) {}
}
