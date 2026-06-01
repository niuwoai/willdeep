//
//  EditorSettingsView.swift
//  VeilWriter
//
//  Preferences UI for editor appearance.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditorSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var cliInstallState: CommandLineToolInstallState = .notInstalled
    @State private var cliStatusMessage = ""
    @State private var isInstallingCLI = false
    @State private var fetchedAgentModels: [String] = []
    @State private var isFetchingAgentModels = false
    @State private var agentModelFetchMessage = ""

    // Local buffers for the Agent settings text fields. The previous
    // implementation bound directly to `appState.agentConfiguration`,
    // which sent every keystroke through the @Published didSet →
    // Keychain → normalize round-trip. Under macOS 26 SwiftUI that loop
    // sometimes clears the SecureField mid-type. Keeping the in-flight
    // text local means typing is purely a @State mutation; an explicit
    // Save button is the only commit point.
    @State private var agentBaseURLBuffer: String = ""
    @State private var agentModelBuffer: String = ""
    @State private var agentAPIKeyBuffer: String = ""
    @State private var agentSaveStatus: String = ""

    var body: some View {
        TabView {
            typographySettings
                .tabItem {
                    Label("Typography", systemImage: "textformat")
                }

            appearanceSettings
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            workspaceSettings
                .tabItem {
                    Label("Workspace", systemImage: "sidebar.left")
                }

            agentSettings
                .tabItem {
                    Label("Agent", systemImage: "sparkles")
                }

            toolsSettings
                .tabItem {
                    Label("Tools", systemImage: "terminal")
                }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 460)
        .background(SettingsKeyboardShortcutHandler())
        .onAppear {
            refreshCLIState()
        }
    }

    private var typographySettings: some View {
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
        }
        .formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
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

            Section("Editor Background") {
                LabeledContent("Image") {
                    HStack {
                        Text(backgroundImageLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(appState.editorSettings.windowBackgroundImagePath == nil ? .secondary : .primary)
                        Spacer(minLength: 8)
                        Button("Choose...") {
                            chooseBackgroundImage()
                        }
                        Button("Clear") {
                            update(\.windowBackgroundImagePath, nil)
                        }
                        .disabled(appState.editorSettings.windowBackgroundImagePath == nil)
                    }
                }

                Picker("Image Mode", selection: setting(\.windowBackgroundImageMode)) {
                    ForEach(EditorBackgroundImageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(appState.editorSettings.windowBackgroundImagePath == nil)

                LabeledContent("Image Size") {
                    HStack {
                        Slider(value: setting(\.windowBackgroundImageScale), in: 0.25...3, step: 0.05)
                        Text("\(Int(appState.editorSettings.windowBackgroundImageScale * 100))%")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(appState.editorSettings.windowBackgroundImagePath == nil)

                LabeledContent("Image Opacity") {
                    HStack {
                        Slider(value: setting(\.windowBackgroundImageOpacity), in: 0...1, step: 0.05)
                        Text("\(Int(appState.editorSettings.windowBackgroundImageOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Editor") {
                Toggle("Show Line Numbers", isOn: setting(\.showsLineNumbers))
                Toggle("Highlight Current Line", isOn: setting(\.highlightsCurrentLine))
                Toggle("Glass Editor Background", isOn: setting(\.editorGlassEnabled))

                Picker("Glass Material", selection: setting(\.editorGlassMaterial)) {
                    ForEach(EditorGlassMaterial.allCases) { material in
                        Text(material.displayName).tag(material)
                    }
                }
                .disabled(!appState.editorSettings.editorGlassEnabled)

                LabeledContent("Glass Strength") {
                    HStack {
                        Slider(value: setting(\.editorGlassOpacity), in: 0...1, step: 0.05)
                        Text("\(Int(appState.editorSettings.editorGlassOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!appState.editorSettings.editorGlassEnabled)

                LabeledContent("Editor Surface") {
                    HStack {
                        Slider(value: setting(\.editorSurfaceOpacity), in: 0.25...1, step: 0.05)
                        Text("\(Int(appState.editorSettings.editorSurfaceOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!appState.editorSettings.editorGlassEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var workspaceSettings: some View {
        Form {
            Section("Sidebar") {
                LabeledContent("Text Size") {
                    HStack {
                        Slider(value: setting(\.fileTreeFontSize), in: 10...16, step: 1)
                        Text("\(Int(appState.editorSettings.fileTreeFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent("Line Height") {
                    HStack {
                        Slider(value: setting(\.fileTreeLineHeightMultiple), in: 1.0...2.0, step: 0.05)
                        Text(String(format: "%.2fx", appState.editorSettings.fileTreeLineHeightMultiple))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
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
        }
        .formStyle(.grouped)
    }

    private var agentSettings: some View {
        Form {
            Section("Agent") {
                Picker("Provider", selection: agentProviderBinding) {
                    ForEach(AgentProviderPreset.all) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }

                TextField("Base URL", text: $agentBaseURLBuffer)
                    .textFieldStyle(.roundedBorder)

                LabeledContent("Model") {
                    HStack {
                        TextField("Model", text: $agentModelBuffer)
                            .textFieldStyle(.roundedBorder)

                        if !fetchedAgentModels.isEmpty {
                            Picker("Fetched Models", selection: $agentModelBuffer) {
                                ForEach(fetchedAgentModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                }

                SecureField("API Key", text: $agentAPIKeyBuffer)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") {
                        commitAgentBuffers()
                    }
                    .disabled(!agentBuffersDiffer)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button("Revert") {
                        loadAgentBuffersFromAppState()
                        agentSaveStatus = ""
                    }
                    .disabled(!agentBuffersDiffer)

                    Button(isFetchingAgentModels ? "Fetching..." : "Fetch Models") {
                        fetchAgentModels()
                    }
                    .disabled(isFetchingAgentModels)

                    if !agentSaveStatus.isEmpty {
                        Text(agentSaveStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if !agentModelFetchMessage.isEmpty {
                        Text(agentModelFetchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text("Keystrokes stay local until you press Save (⌘↩). The API key is stored in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadAgentBuffersFromAppState()
        }
        .onChange(of: appState.agentConfiguration) { _, _ in
            // External writes (e.g. fetchModels picking a default) should
            // refresh the buffers — but only when they currently match
            // what we last saved, so the user's in-flight typing isn't
            // clobbered.
            if !agentBuffersDiffer {
                loadAgentBuffersFromAppState()
            }
        }
    }

    private var agentBuffersDiffer: Bool {
        let configuration = appState.agentConfiguration
        return agentBaseURLBuffer != configuration.baseURL
            || agentModelBuffer != configuration.model
            || agentAPIKeyBuffer != configuration.apiKey
    }

    private func loadAgentBuffersFromAppState() {
        let configuration = appState.agentConfiguration
        agentBaseURLBuffer = configuration.baseURL
        agentModelBuffer = configuration.model
        agentAPIKeyBuffer = configuration.apiKey
    }

    private func commitAgentBuffers() {
        var configuration = appState.agentConfiguration
        configuration.baseURL = agentBaseURLBuffer
        configuration.model = agentModelBuffer
        configuration.apiKey = agentAPIKeyBuffer
        appState.agentConfiguration = configuration.normalized
        // Reflect any normalization (trim, fallback baseURL) back into
        // the buffer so the user sees what was actually saved.
        loadAgentBuffersFromAppState()
        agentSaveStatus = "Saved."
        // Clear the status after a beat so it doesn't linger forever.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if agentSaveStatus == "Saved." { agentSaveStatus = "" }
        }
    }

    private var toolsSettings: some View {
        Form {
            Section("Agent Always Allow") {
                if appState.agentAlwaysAllowedCommands.isEmpty {
                    Text("No commands are always allowed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.agentAlwaysAllowedCommands) { command in
                        HStack {
                            Label(command.commandSignature, systemImage: "checkmark.shield")
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button("Remove") {
                                appState.removeAgentAlwaysAllowedCommand(id: command.id)
                            }
                        }
                    }

                    Button("Clear All") {
                        appState.clearAgentAlwaysAllowedCommands()
                    }
                    .foregroundStyle(.red)
                }

                Text("Rules apply to command families such as `git push`; dangerous commands still require confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    private var backgroundImageLabel: String {
        guard let path = appState.editorSettings.windowBackgroundImagePath else {
            return "No image selected"
        }
        return URL(fileURLWithPath: path).lastPathComponent
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

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Editor Background Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            update(\.windowBackgroundImagePath, url.path)
        }
    }

    private func fetchAgentModels() {
        isFetchingAgentModels = true
        agentModelFetchMessage = ""
        let configuration = appState.agentConfiguration.normalized

        Task {
            let result: Result<[String], Error>
            do {
                let models = try await AgentClient(configuration: configuration).fetchModels()
                result = .success(models)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isFetchingAgentModels = false
                switch result {
                case .success(let models):
                    fetchedAgentModels = models
                    appState.recordFetchedAgentModels(models)
                    if models.isEmpty {
                        agentModelFetchMessage = "No models returned."
                    } else {
                        agentModelFetchMessage = "Fetched \(models.count) models."
                        if agentModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            agentModelBuffer = firstModel
                        }
                    }
                case .failure(let error):
                    fetchedAgentModels = []
                    agentModelFetchMessage = error.localizedDescription
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

    private var agentProviderBinding: Binding<String> {
        Binding {
            appState.agentConfiguration.providerID
        } set: { providerID in
            var configuration = appState.agentConfiguration
            configuration.providerID = providerID
            if let preset = AgentProviderPreset.preset(id: providerID),
               preset.id != AgentProviderPreset.customID {
                configuration.baseURL = preset.baseURL
                configuration.model = preset.defaultModel
                // Reflect the preset in the live buffers so the user
                // doesn't have to click Save just to make the picker
                // visibly take effect.
                agentBaseURLBuffer = preset.baseURL
                agentModelBuffer = preset.defaultModel
            }
            fetchedAgentModels = []
            agentModelFetchMessage = ""
            appState.agentConfiguration = configuration.normalized
        }
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
