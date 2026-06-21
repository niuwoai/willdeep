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
        .background(Color(nsColor: settings.colorScheme.background))
        .foregroundStyle(Color(nsColor: settings.colorScheme.foreground))
        .onAppear {
            if let root = appState.rootDirectory {
                appState.editorTerminalSession.setWorkingDirectory(root)
            }
            appState.editorTerminalSession.startShellIfNeeded(settings: settings)
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
                appState.editorTerminalSession.startShellIfNeeded(settings: settings)
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
        EditorTerminalTextSurface(
            text: appState.editorTerminalSession.output.isEmpty ? "Starting shell...\n" : appState.editorTerminalSession.output,
            settings: settings,
            onInput: { data in
                appState.editorTerminalSession.send(data)
            },
            onPasteText: { text in
                appState.editorTerminalSession.send(text)
            }
        )
    }

    private func run(_ projectCommand: EditorProjectCommand) {
        appState.editorTerminalSession.setWorkingDirectory(projectCommand.workingDirectory)
        appState.editorTerminalSession.run(projectCommand.command, settings: settings)
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

                Picker("Color scheme", selection: terminalSetting(\.colorSchemeID)) {
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

struct EditorTerminalTextSurface: NSViewRepresentable {
    let text: String
    let settings: EditorTerminalSettings
    let onInput: (Data) -> Void
    let onPasteText: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = settings.colorScheme.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = TerminalTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = settings.colorScheme.background
        textView.textColor = settings.colorScheme.foreground
        textView.font = settings.font
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.onInput = onInput
        textView.onPasteText = onPasteText

        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.backgroundColor = settings.colorScheme.background
        guard let textView = context.coordinator.textView else { return }
        textView.onInput = onInput
        textView.onPasteText = onPasteText
        textView.backgroundColor = settings.colorScheme.background
        textView.textColor = settings.colorScheme.foreground
        textView.font = settings.font
        if textView.string != text {
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var textView: TerminalTextView?
    }
}

final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var onPasteText: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            super.keyDown(with: event)
            return
        }

        if let data = terminalInputData(for: event) {
            onInput?(data)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            onPasteText?(text)
        }
    }

    private func terminalInputData(for event: NSEvent) -> Data? {
        switch event.keyCode {
        case 36:
            return Data([13])
        case 51:
            return Data([127])
        case 53:
            return Data([27])
        case 123:
            return Data("\u{1B}[D".utf8)
        case 124:
            return Data("\u{1B}[C".utf8)
        case 125:
            return Data("\u{1B}[B".utf8)
        case 126:
            return Data("\u{1B}[A".utf8)
        default:
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
               let scalar = characters.unicodeScalars.first {
                let value = scalar.value
                if value >= 64 && value <= 95 {
                    return Data([UInt8(value - 64)])
                }
                if value >= 97 && value <= 122 {
                    return Data([UInt8(value - 96)])
                }
            }
            return Data(characters.utf8)
        }
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
