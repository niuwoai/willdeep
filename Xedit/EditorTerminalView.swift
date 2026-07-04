//
//  EditorTerminalView.swift
//  WillDeep
//
//  Bottom terminal pane and Settings UI.
//

import SwiftUI
import AppKit

struct EditorTerminalPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        EditorTerminalPaneContent(session: appState.editorTerminalSession)
    }
}

private struct EditorTerminalPaneContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: EditorTerminalSession

    private var settings: EditorTerminalSettings {
        appState.editorTerminalSettings.normalized()
    }

    private var skinColors: TerminalSkinColors? {
        settings.followsInterfaceSkin
            ? .from(palette: appState.editorSettings.interfaceSkin.palette)
            : nil
    }

    private var commands: [EditorProjectCommand] {
        EditorProjectCommandResolver.commands(
            rootDirectory: appState.rootDirectory,
            openedFileURL: appState.openedFileURL
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminalSurface
        }
        .frame(minHeight: 160, idealHeight: 230, maxHeight: 320)
        .onAppear {
            if let root = appState.rootDirectory {
                session.setWorkingDirectory(root)
            }
            session.startShellIfNeeded(settings: settings, skin: skinColors)
        }
        .onCompatibleChange(of: appState.editorTerminalSettings) { _, _ in
            // Live-apply font / color / cursor changes to the running terminal.
            session.applyAppearance(settings: settings, skin: skinColors)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isRunning ? "terminal.fill" : "terminal")
                .foregroundStyle(Color(nsColor: settings.colorScheme.accent))
            Text(L10n.EditorTerminal.title)
                .font(.caption.weight(.semibold))

            TextField(L10n.EditorTerminal.workingDirectoryPlaceholder, text: $session.workingDirectoryPath)
                .textFieldStyle(.plain)
                .font(.caption2.monospaced())
                .foregroundStyle(Color(nsColor: settings.colorScheme.muted))
                .disabled(session.isRunning)

            Spacer(minLength: 0)

            Menu {
                if commands.isEmpty {
                    Text(L10n.EditorTerminal.noProjectCommands)
                } else {
                    ForEach(commands) { command in
                        Button(command.title) {
                            run(command)
                        }
                    }
                }
            } label: {
                Label(L10n.EditorTerminal.run, systemImage: "play.fill")
            }
            .menuStyle(.button)

            Button {
                session.startShellIfNeeded(settings: settings, skin: skinColors)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .disabled(session.isRunning)
            .help(L10n.EditorTerminal.startShellHelp)

            Button {
                appState.openTerminalSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.EditorTerminal.settingsHelp)

            Button {
                session.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.EditorTerminal.clearHelp)

            Button {
                appState.isEditorTerminalVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.EditorTerminal.closeHelp)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var terminalSurface: some View {
        EditorTerminalSurfaceView(terminalView: session.terminalView)
    }

    private func run(_ projectCommand: EditorProjectCommand) {
        session.setWorkingDirectory(projectCommand.workingDirectory)
        session.run(projectCommand.command, settings: settings, skin: skinColors)
    }
}

extension EditorSettingsView {
    var terminalSettings: some View {
        Form {
            Section(L10n.EditorTerminal.settingsSection) {
                LabeledContent(L10n.EditorTerminal.shell) {
                    TextField("/bin/zsh", text: terminalSetting(\.shellPath))
                        .textFieldStyle(.roundedBorder)
                }

                Picker(L10n.EditorTerminal.font, selection: terminalSetting(\.fontName)) {
                    ForEach(EditorTerminalFont.all) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }

                LabeledContent(L10n.EditorTerminal.customFont) {
                    TextField(L10n.EditorTerminal.customFontPlaceholder, text: terminalSetting(\.customFontName))
                        .textFieldStyle(.roundedBorder)
                }
                Text(L10n.EditorTerminal.customFontFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L10n.EditorTerminal.size) {
                    HStack {
                        Slider(value: terminalSetting(\.fontSize), in: 10...20, step: 1)
                        Text(L10n.EditorTerminal.fontSizePoints(String(Int(appState.editorTerminalSettings.fontSize))))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Picker(L10n.EditorTerminal.cursor, selection: terminalSetting(\.cursorStyleID)) {
                    ForEach(EditorTerminalCursorStyle.allCases) { style in
                        Text(style.displayName).tag(style.id)
                    }
                }

                Toggle(L10n.EditorTerminal.blinkCursor, isOn: terminalSetting(\.cursorBlinks))

                Picker(L10n.EditorTerminal.colorScheme, selection: terminalSetting(\.colorSchemeID)) {
                    Text(L10n.EditorTerminal.followAppSkin).tag(EditorTerminalSettings.followSkinColorSchemeID)
                    ForEach(EditorTerminalColorScheme.all) { scheme in
                        Text(scheme.displayName).tag(scheme.id)
                    }
                }

                // Adaptive grid so the swatch row wraps instead of overflowing
                // once there are many schemes (11+ now).
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(EditorTerminalColorScheme.all) { scheme in
                        Button {
                            updateTerminal(\.colorSchemeID, scheme.id)
                        } label: {
                            TerminalSchemeSwatch(scheme: scheme)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(scheme.displayName)
                    }
                }
                Text(L10n.EditorTerminal.colorSchemeFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.EditorTerminal.environmentSection) {
                TextEditor(text: terminalSetting(\.environmentText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                Text(L10n.EditorTerminal.environmentFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func terminalSetting<Value>(_ keyPath: WritableKeyPath<EditorTerminalSettings, Value>) -> Binding<Value> {
        Binding {
            appState.editorTerminalSettings[keyPath: keyPath]
        } set: { newValue in
            updateTerminal(keyPath, newValue)
        }
    }

    func updateTerminal<Value>(_ keyPath: WritableKeyPath<EditorTerminalSettings, Value>, _ value: Value) {
        var settings = appState.editorTerminalSettings
        settings[keyPath: keyPath] = value
        appState.editorTerminalSettings = settings.normalized()
    }
}

private struct TerminalSchemeSwatch: View {
    let scheme: EditorTerminalColorScheme

    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: scheme.background)
            Color(nsColor: scheme.foreground)
            Color(nsColor: scheme.accent)
            Color(nsColor: scheme.muted)
        }
        .frame(width: 64, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: scheme.muted).opacity(0.5), lineWidth: 1)
        )
    }
}
