//
//  EditorSettingsView.swift
//  VeilWriter
//
//  Preferences UI for editor appearance.
//

import SwiftUI
import AppKit

struct EditorSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var cliInstallState: CommandLineToolInstallState = .notInstalled
    @State private var cliStatusMessage = ""
    @State private var isInstallingCLI = false

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Font", selection: setting(\.fontID)) {
                    ForEach(EditorFontChoice.allCases) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }

                HStack {
                    Slider(value: setting(\.fontSize), in: 10...28, step: 1)
                    Text("\(Int(appState.editorSettings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Slider(value: setting(\.lineHeightMultiple), in: 1.0...1.8, step: 0.05)
                    Text(String(format: "%.2fx", appState.editorSettings.lineHeightMultiple))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Section("Color Style") {
                Picker("Theme", selection: setting(\.themeID)) {
                    ForEach(EditorTheme.all) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(EditorTheme.all) { theme in
                        Button {
                            update(\.themeID, theme.id)
                        } label: {
                            ThemeSwatch(theme: theme)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.displayName)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Editor") {
                Toggle("Show Line Numbers", isOn: setting(\.showsLineNumbers))
                Toggle("Highlight Current Line", isOn: setting(\.highlightsCurrentLine))
            }

            Section("Sidebar") {
                HStack {
                    Slider(value: setting(\.fileTreeFontSize), in: 10...16, step: 1)
                    Text("\(Int(appState.editorSettings.fileTreeFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Section("Inspector") {
                Picker("Default View", selection: setting(\.preferredInspectorMode)) {
                    ForEach(EditorInspectorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("View Order", selection: setting(\.inspectorPanelOrder)) {
                    ForEach(EditorInspectorPanelOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            }

            Section("Save") {
                Toggle("Trim Trailing Whitespace", isOn: setting(\.trimsTrailingWhitespaceOnSave))
                Toggle("Ensure Final Newline", isOn: setting(\.ensuresFinalNewlineOnSave))
            }

            Section("Command Line Tool") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("veilwriter")
                            .font(.headline)
                        Text(cliStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(cliButtonTitle) {
                        installCLI()
                    }
                    .disabled(isInstallingCLI)
                }

                if !cliStatusMessage.isEmpty {
                    Text(cliStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 500)
        .background(SettingsKeyboardShortcutHandler())
        .onAppear {
            refreshCLIState()
        }
    }

    private var cliStatusText: String {
        switch cliInstallState {
        case .installed:
            return "Installed at \(CommandLineToolInstaller.installURL.path)"
        case .needsUpdate:
            return "A command exists at \(CommandLineToolInstaller.installURL.path) and can be updated."
        case .notInstalled:
            return "Install the veilwriter command for Terminal."
        }
    }

    private var cliButtonTitle: String {
        if isInstallingCLI {
            return "Installing..."
        }

        switch cliInstallState {
        case .installed:
            return "Reinstall"
        case .needsUpdate:
            return "Update"
        case .notInstalled:
            return "Install"
        }
    }

    private func refreshCLIState() {
        cliInstallState = CommandLineToolInstaller.installState()
    }

    private func installCLI() {
        isInstallingCLI = true
        cliStatusMessage = "Installing without administrator privileges."

        Task.detached {
            let result: Result<Void, Error>
            do {
                try CommandLineToolInstaller.install()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isInstallingCLI = false
                refreshCLIState()
                switch result {
                case .success:
                    cliStatusMessage = "Installed. Try: veilwriter . Add ~/.local/bin to PATH if needed."
                case .failure(let error):
                    cliStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>) -> Binding<Value> {
        Binding {
            appState.editorSettings[keyPath: keyPath]
        } set: { newValue in
            update(keyPath, newValue)
        }
    }

    private func update<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>, _ value: Value) {
        var settings = appState.editorSettings
        settings[keyPath: keyPath] = value
        appState.editorSettings = settings.normalized()
    }
}

private struct SettingsKeyboardShortcutHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  event.charactersIgnoringModifiers?.lowercased() == "w" else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.option) || modifiers.contains(.command) else {
                return event
            }

            window.performClose(nil)
            return nil
        }
    }
}

private struct ThemeSwatch: View {
    let theme: EditorTheme

    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: theme.backgroundColor)
            Color(nsColor: theme.keywordColor)
            Color(nsColor: theme.stringColor)
            Color(nsColor: theme.commentColor)
            Color(nsColor: theme.numberColor)
        }
        .frame(width: 64, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: theme.gutterTextColor).opacity(0.45), lineWidth: 1)
        )
    }
}
