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
                appState.editorTerminalSession.setWorkingDirectory(root)
            }
            appState.editorTerminalSession.startShellIfNeeded(settings: settings, skin: skinColors)
        }
        .onCompatibleChange(of: appState.editorTerminalSettings) { _, _ in
            // Live-apply font / color / cursor changes to the running terminal.
            appState.editorTerminalSession.applyAppearance(settings: settings, skin: skinColors)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.editorTerminalSession.isRunning ? "terminal.fill" : "terminal")
                .foregroundStyle(Color(nsColor: settings.colorScheme.accent))
            Text("Terminal")
                .font(.caption.weight(.semibold))

            TextField("working directory", text: $appState.editorTerminalSession.workingDirectoryPath)
                .textFieldStyle(.plain)
                .font(.caption2.monospaced())
                .foregroundStyle(Color(nsColor: settings.colorScheme.muted))
                .disabled(appState.editorTerminalSession.isRunning)

            Spacer(minLength: 0)

            Menu {
                if commands.isEmpty {
                    Text("No project commands found")
                } else {
                    ForEach(commands) { command in
                        Button(command.title) {
                            run(command)
                        }
                    }
                }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .menuStyle(.button)

            Button {
                appState.editorTerminalSession.startShellIfNeeded(settings: settings, skin: skinColors)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .disabled(appState.editorTerminalSession.isRunning)
            .help("Start Shell")

            Button {
                appState.openTerminalSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Terminal Settings")

            Button {
                appState.editorTerminalSession.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear")

            Button {
                appState.isEditorTerminalVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var terminalSurface: some View {
        EditorTerminalSurfaceView(terminalView: appState.editorTerminalSession.terminalView)
    }

    private func run(_ projectCommand: EditorProjectCommand) {
        appState.editorTerminalSession.setWorkingDirectory(projectCommand.workingDirectory)
        appState.editorTerminalSession.run(projectCommand.command, settings: settings, skin: skinColors)
    }
}

extension EditorSettingsView {
    var terminalSettings: some View {
        Form {
            Section("Terminal") {
                LabeledContent("Shell") {
                    TextField("/bin/zsh", text: terminalSetting(\.shellPath))
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Font", selection: terminalSetting(\.fontName)) {
                    ForEach(EditorTerminalFont.all) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }

                LabeledContent("Size") {
                    HStack {
                        Slider(value: terminalSetting(\.fontSize), in: 10...20, step: 1)
                        Text("\(Int(appState.editorTerminalSettings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Picker("Cursor", selection: terminalSetting(\.cursorStyleID)) {
                    ForEach(EditorTerminalCursorStyle.allCases) { style in
                        Text(style.displayName).tag(style.id)
                    }
                }

                Toggle("Blink cursor", isOn: terminalSetting(\.cursorBlinks))

                Picker("Color scheme", selection: terminalSetting(\.colorSchemeID)) {
                    Text("Follow App Skin").tag(EditorTerminalSettings.followSkinColorSchemeID)
                    ForEach(EditorTerminalColorScheme.all) { scheme in
                        Text(scheme.displayName).tag(scheme.id)
                    }
                }

                HStack(spacing: 8) {
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
                Text("“Follow App Skin” derives the terminal background, foreground, and cursor from your interface skin; ANSI program colors stay standard so output stays readable. Line spacing isn't adjustable with the current terminal engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment") {
                TextEditor(text: terminalSetting(\.environmentText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                Text("One KEY=value per line. These values are added to commands launched from the editor terminal.")
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
