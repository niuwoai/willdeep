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
    @State private var fetchedImageModels: [String] = []
    @State private var isFetchingImageModels = false
    @State private var imageModelFetchMessage = ""

    // Local buffers for the Agent settings text fields. The previous
    // implementation bound directly to `appState.agentConfiguration`,
    // which sent every keystroke through the @Published didSet →
    // Keychain → normalize round-trip. Under macOS 26 SwiftUI that loop
    // sometimes clears the SecureField mid-type. Keeping the in-flight
    // text local means typing is purely a @State mutation; an explicit
    // Save button is the only commit point.
    @State private var agentBaseURLBuffer: String = ""
    @State private var agentModelBuffer: String = ""
    @State private var agentFlashModelBuffer: String = ""
    @State private var agentProModelBuffer: String = ""
    @State private var agentRoutingModeBuffer: AgentModelRoutingMode = .auto
    @State private var agentAPIKeyBuffer: String = ""
    @State private var imageProviderIDBuffer: String = ""
    @State private var imageBaseURLBuffer: String = ""
    @State private var imageModelBuffer: String = ""
    @State private var imageAPIKeyBuffer: String = ""
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

            AgentMemorySettingsView()
                .tabItem {
                    Label("Memory", systemImage: "brain.head.profile")
                }

            AgentSkillSettingsView()
                .tabItem {
                    Label("Skills", systemImage: "wand.and.stars")
                }

            AgentMCPSettingsView()
                .tabItem {
                    Label("MCP", systemImage: "globe")
                }

            toolsSettings
                .tabItem {
                    Label("Tools", systemImage: "terminal")
                }
        }
        .padding(20)
        .frame(
            minWidth: 560,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .background(SettingsKeyboardShortcutHandler())
        .background(SettingsWindowResizableEnforcer())
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
            Section("Agent Providers") {
                AgentProviderLibrarySection(
                    fetchedAgentModels: $fetchedAgentModels,
                    isFetchingAgentModels: $isFetchingAgentModels,
                    agentModelFetchMessage: $agentModelFetchMessage,
                    onFetchModels: { entry in
                        fetchAgentModels(forEntry: entry)
                    }
                )
            }

            Section("Image Understanding") {
                Picker("Provider", selection: imageProviderBinding) {
                    ForEach(AgentProviderPreset.all.filter(\.supportsImageInput)) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }

                TextField("Base URL", text: $imageBaseURLBuffer)
                    .textFieldStyle(.roundedBorder)

                agentModelField("Vision Model", text: $imageModelBuffer, models: fetchedImageModels)

                LabeledContent("API Key") {
                    RevealableSecretField(
                        text: $imageAPIKeyBuffer,
                        placeholder: "sk-...",
                        onCommit: {}
                    )
                }

                Text("Used only when the active Agent provider cannot accept images directly. Multiple attached images are described in one request, then the description is sent to the main model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                    Button(isFetchingImageModels ? "Fetching Images..." : "Fetch Image Models") {
                        fetchImageModels()
                    }
                    .disabled(isFetchingImageModels)

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
                    } else if !imageModelFetchMessage.isEmpty {
                        Text(imageModelFetchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text("Keystrokes stay local until you press Save (⌘↩). API keys are stored separately in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tool approval") {
                Toggle("Auto-approve safe commands", isOn: Binding(
                    get: { appState.autoApproveSafeCommands },
                    set: { appState.autoApproveSafeCommands = $0 }
                ))
                Text("Read-only shell commands in the built-in allowlist (cat, head, tail, ls, find without -delete/-exec, git diff/log/status/show, rg, grep, wc, file, stat, which, pwd, echo, …) run without asking. Commands outside the allowlist are passed to a one-shot LLM judge running on the active provider's **Flash** model (cheap & fast — never Pro), and only YES verdicts auto-run. Destructive patterns (rm, sudo, git push --force, git reset --hard, …) still require typing \"confirm\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Concurrency") {
                HStack {
                    Text("Per-provider concurrency")
                    Spacer()
                    Text("\(appState.perProviderConcurrencyLimit)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(appState.perProviderConcurrencyLimit) },
                        set: { appState.perProviderConcurrencyLimit = Int($0.rounded()) }
                    ),
                    in: 1...8,
                    step: 1
                )
                Text("Cap on simultaneous Agent turns per provider. Each provider has its own quota — running 3 DashScope sessions doesn't block OpenAI sessions. When the cap is hit, new dispatches queue (FIFO) and drain as turns finish. Raising the cap immediately promotes queued work; lowering it just stops promoting new ones (running turns are never aborted). Default 3 is conservative — bump up if your provider's rate limit comfortably allows.")
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

    /// Save button now only covers the Image Understanding fields and
    /// routing mode — all the per-provider Agent fields are managed
    /// live by the new `AgentProviderLibrarySection`.
    private var agentBuffersDiffer: Bool {
        let configuration = appState.agentConfiguration
        return agentRoutingModeBuffer != configuration.routingMode
            || imageProviderIDBuffer != configuration.imageDescription.providerID
            || imageBaseURLBuffer != configuration.imageDescription.baseURL
            || imageModelBuffer != configuration.imageDescription.model
            || imageAPIKeyBuffer != configuration.imageDescription.apiKey
    }

    private func loadAgentBuffersFromAppState() {
        let configuration = appState.agentConfiguration
        agentBaseURLBuffer = configuration.baseURL
        agentModelBuffer = configuration.model
        agentFlashModelBuffer = configuration.flashModel
        agentProModelBuffer = configuration.proModel
        agentRoutingModeBuffer = configuration.routingMode
        agentAPIKeyBuffer = configuration.apiKey
        imageProviderIDBuffer = configuration.imageDescription.providerID
        imageBaseURLBuffer = configuration.imageDescription.baseURL
        imageModelBuffer = configuration.imageDescription.model
        imageAPIKeyBuffer = configuration.imageDescription.apiKey
    }

    private func commitAgentBuffers() {
        var configuration = appState.agentConfiguration
        configuration.routingMode = agentRoutingModeBuffer
        configuration.imageDescription = AgentImageDescriptionConfiguration(
            providerID: imageProviderIDBuffer,
            baseURL: imageBaseURLBuffer,
            model: imageModelBuffer,
            apiKey: imageAPIKeyBuffer
        )
        appState.agentConfiguration = configuration.normalized
        loadAgentBuffersFromAppState()
        agentSaveStatus = "Saved."
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if agentSaveStatus == "Saved." { agentSaveStatus = "" }
        }
    }

    private func agentModelField(_ title: String, text: Binding<String>, models: [String]) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)

                if !models.isEmpty {
                    Picker("Fetched Models", selection: text) {
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
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
                        if agentFlashModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            agentFlashModelBuffer = firstModel
                        }
                        if agentProModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            agentProModelBuffer = firstModel
                        }
                    }
                case .failure(let error):
                    fetchedAgentModels = []
                    agentModelFetchMessage = error.localizedDescription
                }
            }
        }
    }

    /// Fetch /models from a specific library entry (as opposed to the
    /// currently active configuration). Used by the multi-provider
    /// section so each row can pull its own model list independently
    /// of which entry is currently active in the chat.
    private func fetchAgentModels(forEntry entry: AgentProviderEntry) {
        isFetchingAgentModels = true
        agentModelFetchMessage = ""
        let configuration = entry.makeConfiguration().normalized

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
                    agentModelFetchMessage = models.isEmpty
                        ? "No models returned."
                        : "Fetched \(models.count) models for \(entry.displayName)."
                case .failure(let error):
                    fetchedAgentModels = []
                    agentModelFetchMessage = error.localizedDescription
                }
            }
        }
    }

    private func fetchImageModels() {
        isFetchingImageModels = true
        imageModelFetchMessage = ""
        let imageConfiguration = AgentImageDescriptionConfiguration(
            providerID: imageProviderIDBuffer,
            baseURL: imageBaseURLBuffer,
            model: imageModelBuffer,
            apiKey: imageAPIKeyBuffer
        ).normalized.agentConfiguration

        Task {
            let result: Result<[String], Error>
            do {
                let models = try await AgentClient(configuration: imageConfiguration).fetchModels()
                result = .success(models)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isFetchingImageModels = false
                switch result {
                case .success(let models):
                    fetchedImageModels = models
                    appState.recordFetchedAgentModels(models)
                    if models.isEmpty {
                        imageModelFetchMessage = "No image models returned."
                    } else {
                        imageModelFetchMessage = "Fetched \(models.count) image models."
                        if imageModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            imageModelBuffer = firstModel
                        }
                    }
                case .failure(let error):
                    fetchedImageModels = []
                    imageModelFetchMessage = error.localizedDescription
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
                configuration.flashModel = preset.defaultFlashModel
                configuration.proModel = preset.defaultProModel
                configuration.routingMode = .auto
                // Reflect the preset in the live buffers so the user
                // doesn't have to click Save just to make the picker
                // visibly take effect.
                agentBaseURLBuffer = preset.baseURL
                agentModelBuffer = preset.defaultModel
                agentFlashModelBuffer = preset.defaultFlashModel
                agentProModelBuffer = preset.defaultProModel
                agentRoutingModeBuffer = .auto
            }
            fetchedAgentModels = []
            agentModelFetchMessage = ""
            appState.agentConfiguration = configuration.normalized
        }
    }

    private var imageProviderBinding: Binding<String> {
        Binding {
            imageProviderIDBuffer
        } set: { providerID in
            imageProviderIDBuffer = providerID
            if let preset = AgentProviderPreset.preset(id: providerID),
               preset.id != AgentProviderPreset.customID {
                imageBaseURLBuffer = preset.baseURL
                imageModelBuffer = preset.defaultVisionModel
            }
            fetchedImageModels = []
            imageModelFetchMessage = ""
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

// MARK: - Agent provider library section

/// Phase C: Settings UI for the multi-provider library. Left pane lists
/// the user's saved providers with active-marker / add / remove
/// controls; right pane edits the selected entry's preset, base URL,
/// API key, flash primary + alternates, pro primary + alternates,
/// with a Fetch Models button that pulls per-entry. Edits commit
/// immediately to `appState.agentProviderLibrary` (no Save button) —
/// the legacy single-config Save flow continues to cover Image
/// Understanding and routing.
struct AgentProviderLibrarySection: View {
    @EnvironmentObject var appState: AppState
    @Binding var fetchedAgentModels: [String]
    @Binding var isFetchingAgentModels: Bool
    @Binding var agentModelFetchMessage: String
    let onFetchModels: (AgentProviderEntry) -> Void

    @State private var selectedEntryID: UUID?

    private var selectedEntry: AgentProviderEntry? {
        guard let id = selectedEntryID else { return nil }
        return appState.agentProviderLibrary.entries.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                providerList
                    .frame(width: 200)
                editorPane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Edits save automatically. The active provider (★) drives the next chat turn — click any star to switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: ensureSelection)
        .onChange(of: appState.agentProviderLibrary.activeID) { _, _ in
            ensureSelection()
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.agentProviderLibrary.entries) { entry in
                        providerRow(entry)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .frame(minHeight: 260)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            HStack(spacing: 2) {
                Button {
                    addEntry()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Add provider")

                Button {
                    if let id = selectedEntryID {
                        appState.removeProviderLibraryEntry(id: id)
                        selectedEntryID = appState.agentProviderLibrary.entries.first?.id
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selectedEntryID == nil || appState.agentProviderLibrary.entries.count <= 1)
                .help("Remove selected provider")

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func providerRow(_ entry: AgentProviderEntry) -> some View {
        let isSelected = selectedEntryID == entry.id
        let isActive = appState.agentProviderLibrary.activeID == entry.id
        HStack(spacing: 8) {
            Button {
                appState.setActiveProviderLibraryEntry(id: entry.id)
            } label: {
                Image(systemName: isActive ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.yellow : Color.secondary.opacity(0.45))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active provider" : "Make active")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(entry.flashPrimary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedEntryID = entry.id
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let entry = selectedEntry {
            AgentProviderEntryEditor(
                entry: entry,
                fetchedAgentModels: fetchedAgentModels,
                isFetchingAgentModels: isFetchingAgentModels,
                agentModelFetchMessage: agentModelFetchMessage,
                onFetch: { onFetchModels(entry) },
                onChange: { updated in
                    appState.upsertProviderLibraryEntry(updated)
                }
            )
        } else {
            Text("Pick a provider on the left, or add one with +")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func addEntry() {
        // Default new entries to the OpenAI preset so the user has
        // something to overwrite immediately.
        let preset = AgentProviderPreset.preset(id: AgentProviderPreset.openAIID) ?? AgentProviderPreset.all[0]
        let entry = AgentProviderEntry(
            providerID: preset.id,
            baseURL: preset.baseURL,
            apiKey: "",
            flashPrimary: preset.defaultFlashModel,
            proPrimary: preset.defaultProModel
        )
        appState.upsertProviderLibraryEntry(entry)
        selectedEntryID = entry.id
    }

    private func ensureSelection() {
        if selectedEntryID == nil
            || appState.agentProviderLibrary.entries.first(where: { $0.id == selectedEntryID }) == nil {
            selectedEntryID = appState.agentProviderLibrary.activeID
                ?? appState.agentProviderLibrary.entries.first?.id
        }
    }
}

/// Right-pane editor for one library entry. State buffers locally to
/// keep typing snappy; commits to AppState on `.onChange` so there's
/// no Save button to forget.
private struct AgentProviderEntryEditor: View {
    let entry: AgentProviderEntry
    let fetchedAgentModels: [String]
    let isFetchingAgentModels: Bool
    let agentModelFetchMessage: String
    let onFetch: () -> Void
    let onChange: (AgentProviderEntry) -> Void

    @State private var providerID: String = ""
    @State private var displayName: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var flashPrimary: String = ""
    @State private var flashAlternatesText: String = ""
    @State private var proPrimary: String = ""
    @State private var proAlternatesText: String = ""
    @State private var routingMode: AgentModelRoutingMode = .auto

    private let labelWidth: CGFloat = 110

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                connectionGroup
                modelsGroup
                routingGroup
                fetchModelsRow
            }
            .padding(.trailing, 4)
        }
        .onAppear(perform: loadFromEntry)
        .onChange(of: entry.id) { _, _ in loadFromEntry() }
    }

    // MARK: - Connection

    private var connectionGroup: some View {
        GroupBox(label: sectionLabel("Connection", system: "link")) {
            VStack(alignment: .leading, spacing: 10) {
                fieldRow("Display name") {
                    TextField("e.g. Work OpenAI", text: $displayName, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("Preset") {
                    Picker("", selection: $providerID) {
                        ForEach(AgentProviderPreset.all) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: providerID) { _, newID in
                        // Snap to preset defaults so the user doesn't have
                        // to retype everything when switching brands.
                        if let preset = AgentProviderPreset.preset(id: newID), preset.id != AgentProviderPreset.customID {
                            baseURL = preset.baseURL
                            if !preset.recognizesModelID(flashPrimary) {
                                flashPrimary = preset.defaultFlashModel
                            }
                            if !preset.recognizesModelID(proPrimary) {
                                proPrimary = preset.defaultProModel
                            }
                            if displayName.isEmpty || AgentProviderPreset.all.map(\.displayName).contains(displayName) {
                                displayName = preset.displayName
                            }
                        }
                        commit()
                    }
                }
                fieldRow("Base URL") {
                    TextField("https://...", text: $baseURL, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("API key") {
                    RevealableSecretField(
                        text: $apiKey,
                        placeholder: "sk-...",
                        onCommit: commit
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Models

    private var modelsGroup: some View {
        GroupBox(label: sectionLabel("Models", system: "cube.box")) {
            VStack(alignment: .leading, spacing: 12) {
                modelGroup(
                    title: "Flash",
                    primaryBinding: $flashPrimary,
                    alternatesBinding: $flashAlternatesText
                )
                Divider()
                modelGroup(
                    title: "Pro",
                    primaryBinding: $proPrimary,
                    alternatesBinding: $proAlternatesText
                )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Routing

    private var routingGroup: some View {
        GroupBox(label: sectionLabel("Routing", system: "arrow.triangle.branch")) {
            VStack(alignment: .leading, spacing: 8) {
                fieldRow("Default tier") {
                    Picker("", selection: $routingMode) {
                        ForEach(AgentModelRoutingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: routingMode) { _, _ in commit() }
                }
                Text(routingMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, labelWidth + 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Fetch models row

    private var fetchModelsRow: some View {
        HStack(spacing: 10) {
            Button {
                onFetch()
            } label: {
                HStack(spacing: 4) {
                    if isFetchingAgentModels {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(isFetchingAgentModels ? "Fetching…" : "Fetch Models")
                }
            }
            .disabled(isFetchingAgentModels)
            if !agentModelFetchMessage.isEmpty {
                Text(agentModelFetchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(_ title: String, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func modelGroup(
        title: String,
        primaryBinding: Binding<String>,
        alternatesBinding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("\(title) primary") {
                modelField(text: primaryBinding)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("\(title) alternates")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: alternatesBinding)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 52, maxHeight: 88)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .onChange(of: alternatesBinding.wrappedValue) { _, _ in commit() }
                    Text("One model id per line — surfaces in the chat picker as one-click switches.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func modelField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField("model-id", text: text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
            if !fetchedAgentModels.isEmpty {
                Menu {
                    ForEach(fetchedAgentModels, id: \.self) { id in
                        Button(id) { text.wrappedValue = id; commit() }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick from fetched models")
            }
        }
        .onChange(of: text.wrappedValue) { _, _ in commit() }
    }

    private func loadFromEntry() {
        providerID = entry.providerID
        displayName = entry.displayName
        baseURL = entry.baseURL
        apiKey = entry.apiKey
        flashPrimary = entry.flashPrimary
        flashAlternatesText = entry.flashAlternates.joined(separator: "\n")
        proPrimary = entry.proPrimary
        proAlternatesText = entry.proAlternates.joined(separator: "\n")
        routingMode = entry.routingMode
    }

    private func commit() {
        let updated = AgentProviderEntry(
            id: entry.id,
            providerID: providerID,
            displayName: displayName,
            baseURL: baseURL,
            apiKey: apiKey,
            flashPrimary: flashPrimary,
            flashAlternates: splitLines(flashAlternatesText),
            proPrimary: proPrimary,
            proAlternates: splitLines(proAlternatesText),
            routingMode: routingMode
        )
        onChange(updated)
    }

    private func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Secret field that toggles between SecureField (dots) and TextField
/// (revealed) via an eye button. Lets the user verify a pasted API key
/// without re-typing it. The reveal state lives in the view — never
/// persisted — so closing Settings re-hides the key by default.
private struct RevealableSecretField: View {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void

    @State private var isRevealed: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text, onCommit: onCommit)
                } else {
                    SecureField(placeholder, text: $text, onCommit: onCommit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Hide key" : "Show key")
        }
    }
}

/// SwiftUI's `Settings { }` scene installs an `NSPanel` whose default
/// styleMask omits `.resizable`, so the user can't drag the corners
/// even after the SwiftUI view advertises `maxWidth: .infinity`.  We
/// reach into the host window once it's available and add the
/// resizable + miniaturizable + zoom bits, drop the contentMaxSize
/// cap, and give it a sensible content min size.  Result: feels like
/// a normal mac document window.
private struct SettingsWindowResizableEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        var mask = window.styleMask
        mask.insert(.resizable)
        mask.insert(.miniaturizable)
        mask.insert(.closable)
        mask.insert(.titled)
        window.styleMask = mask
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
    }
}
