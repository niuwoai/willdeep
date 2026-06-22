//
//  AgentRuntimeSettingsView.swift
//  WillDeep
//
//  Settings tab for remote Agent runtimes. SSH is the first transport;
//  daemon support is represented in the model but intentionally not
//  install-mutating in this UI.
//

import SwiftUI

private let defaultSSHIdentityFilePath = "~/.ssh/id_rsa"
private let remoteRuntimePortRange = 1...65535

struct AgentRuntimeSettingsView: View {
    @State private var runtimes = AgentRuntimeStore.loadDescriptors()
    @State private var selectedRuntimeID: UUID?
    @State private var statusMessage = ""
    @State private var probingRuntimeID: UUID?

    @State private var displayName = ""
    @State private var host = ""
    @State private var username = ""
    @State private var port = 22
    @State private var identityFilePath = ""
    @State private var daemonURL = ""
    @State private var daemonToken = ""
    @State private var transport: RuntimeTransport = .ssh
    @State private var workspacePath = ""

    private var selectedRuntime: RuntimeDescriptor? {
        guard let selectedRuntimeID else { return nil }
        return runtimes.first { $0.id == selectedRuntimeID }
    }

    var body: some View {
        HSplitView {
            runtimeList
                .frame(minWidth: 220, idealWidth: 260)
            runtimeEditor
                .frame(minWidth: 380)
        }
        .onAppear {
            reload()
            if selectedRuntimeID == nil {
                selectedRuntimeID = runtimes.first?.id
                loadSelectedRuntime()
            }
        }
        .onCompatibleChange(of: selectedRuntimeID) { _, _ in
            loadSelectedRuntime()
        }
    }

    private var runtimeList: some View {
        Form {
            Section(L10n.Settings.RemoteRuntimes.listSection) {
                if runtimes.isEmpty {
                    Text(L10n.Settings.RemoteRuntimes.empty)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runtimes) { runtime in
                        Button {
                            selectedRuntimeID = runtime.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: runtime.transport == .ssh ? "terminal" : "antenna.radiowaves.left.and.right")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(runtime.displayName)
                                        .font(.headline)
                                    Text(runtime.hostLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedRuntimeID == runtime.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    let runtime = RuntimeDescriptor(
                        displayName: L10n.Settings.RemoteRuntimes.newRuntimeDefaultName,
                        host: "",
                        username: NSUserName(),
                        identityFilePath: defaultSSHIdentityFilePath,
                        defaultWorkspacePath: ""
                    )
                    runtimes.append(runtime)
                    selectedRuntimeID = runtime.id
                    saveAll()
                } label: {
                    Label(L10n.Settings.RemoteRuntimes.addButton, systemImage: "plus")
                }

                Button {
                    let runtime = RuntimeDescriptor(
                        displayName: L10n.Settings.RemoteRuntimes.newDaemonRuntimeDefaultName,
                        transport: .daemon,
                        host: "127.0.0.1",
                        port: 8765,
                        username: "",
                        daemonBaseURL: "http://127.0.0.1:8765",
                        defaultWorkspacePath: ""
                    )
                    runtimes.append(runtime)
                    selectedRuntimeID = runtime.id
                    saveAll()
                } label: {
                    Label(L10n.Settings.RemoteRuntimes.addDaemonButton, systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runtimeEditor: some View {
        Form {
            Section(L10n.Settings.RemoteRuntimes.connectionSection) {
                textInput(
                    L10n.Settings.RemoteRuntimes.displayNameLabel,
                    text: $displayName,
                    prompt: L10n.Settings.RemoteRuntimes.displayNamePrompt
                )
                Picker(L10n.Settings.RemoteRuntimes.transportLabel, selection: $transport) {
                    Text(L10n.Settings.RemoteRuntimes.sshTransportLabel).tag(RuntimeTransport.ssh)
                    Text(L10n.Settings.RemoteRuntimes.daemonTransportLabel).tag(RuntimeTransport.daemon)
                }
                .pickerStyle(.segmented)

                if transport == .ssh {
                    textInput(
                        L10n.Settings.RemoteRuntimes.hostLabel,
                        text: $host,
                        prompt: L10n.Settings.RemoteRuntimes.hostPrompt
                    )
                    textInput(
                        L10n.Settings.RemoteRuntimes.usernameLabel,
                        text: $username,
                        prompt: L10n.Settings.RemoteRuntimes.usernamePrompt
                    )
                    portInput
                    textInput(
                        L10n.Settings.RemoteRuntimes.identityFileLabel,
                        text: $identityFilePath,
                        prompt: L10n.Settings.RemoteRuntimes.identityFilePrompt
                    )
                    Text(L10n.Settings.RemoteRuntimes.sshDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    textInput(
                        L10n.Settings.RemoteRuntimes.daemonURLLabel,
                        text: $daemonURL,
                        prompt: L10n.Settings.RemoteRuntimes.daemonURLPrompt
                    )
                    secureInput(
                        L10n.Settings.RemoteRuntimes.daemonTokenLabel,
                        text: $daemonToken,
                        prompt: L10n.Settings.RemoteRuntimes.daemonTokenPrompt
                    )
                    Text(L10n.Settings.RemoteRuntimes.daemonDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                textInput(
                    L10n.Settings.RemoteRuntimes.workspacePathLabel,
                    text: $workspacePath,
                    prompt: L10n.Settings.RemoteRuntimes.workspacePathPrompt
                )
            }

            if let selectedRuntime {
                Section(L10n.Settings.RemoteRuntimes.probeSection) {
                    LabeledContent(L10n.Settings.RemoteRuntimes.platformLabel) {
                        Text("\(selectedRuntime.platform.displayName) / \(selectedRuntime.arch.displayName)")
                    }
                    LabeledContent(L10n.Settings.RemoteRuntimes.capabilitiesLabel) {
                        Text(capabilityLine(selectedRuntime))
                    }
                    if !toolchainLine(selectedRuntime).isEmpty {
                        LabeledContent(L10n.Settings.RemoteRuntimes.toolchainLabel) {
                            Text(toolchainLine(selectedRuntime))
                        }
                    }
                    if !collaborationLine(selectedRuntime).isEmpty {
                        LabeledContent(L10n.Settings.RemoteRuntimes.collaborationLabel) {
                            Text(collaborationLine(selectedRuntime))
                                .lineLimit(3)
                        }
                    }
                    if !mirrorLine(selectedRuntime).isEmpty {
                        LabeledContent(L10n.Settings.RemoteRuntimes.mirrorLabel) {
                            Text(mirrorLine(selectedRuntime))
                                .lineLimit(3)
                        }
                    }
                    if !proxyLine(selectedRuntime).isEmpty {
                        LabeledContent(L10n.Settings.RemoteRuntimes.proxyLabel) {
                            Text(proxyLine(selectedRuntime))
                                .lineLimit(4)
                        }
                    }
                    if let lastProbeAt = selectedRuntime.lastProbeAt {
                        LabeledContent(L10n.Settings.RemoteRuntimes.lastProbeLabel) {
                            Text(lastProbeAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }

                    HStack {
                        Button(probingRuntimeID == selectedRuntime.id ? L10n.Settings.RemoteRuntimes.probingButton : L10n.Settings.RemoteRuntimes.probeButton) {
                            saveCurrent()
                            probeSelectedRuntime()
                        }
                        .disabled(probingRuntimeID != nil || !canProbe)

                        Button(L10n.Settings.RemoteRuntimes.saveButton) {
                            saveCurrent()
                        }

                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Label(L10n.Settings.RemoteRuntimes.deleteButton, systemImage: "trash")
                        }

                        Spacer()
                    }
                }
            }
            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onCompatibleChange(of: transport) { _, newTransport in
            if newTransport == .ssh && identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identityFilePath = defaultSSHIdentityFilePath
            }
        }
        .onCompatibleChange(of: port) { _, newPort in
            port = clampedPort(newPort)
        }
    }

    private var portInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Settings.RemoteRuntimes.portInputLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                L10n.Settings.RemoteRuntimes.portPrompt,
                value: $port,
                format: .number.grouping(.never)
            )
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }

    private func textInput(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }

    private func secureInput(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }

    private func loadSelectedRuntime() {
        guard let selectedRuntime else {
            displayName = ""
            host = ""
            username = NSUserName()
            port = 22
            identityFilePath = defaultSSHIdentityFilePath
            daemonURL = ""
            daemonToken = ""
            transport = .ssh
            workspacePath = ""
            return
        }
        displayName = selectedRuntime.displayName
        host = selectedRuntime.host
        username = selectedRuntime.username
        port = clampedPort(selectedRuntime.port)
        identityFilePath = selectedRuntime.identityFilePath ?? defaultSSHIdentityFilePath
        daemonURL = selectedRuntime.daemonBaseURL ?? selectedRuntime.daemonEndpointURL?.absoluteString ?? ""
        daemonToken = selectedRuntime.transport == .daemon ? RemoteRuntimeSecretStore.daemonToken(runtimeID: selectedRuntime.id) : ""
        transport = selectedRuntime.transport
        workspacePath = selectedRuntime.defaultWorkspacePath
    }

    private func saveCurrent() {
        let id = selectedRuntimeID ?? UUID()
        var runtime = selectedRuntime ?? RuntimeDescriptor(
            id: id,
            displayName: displayName,
            host: host,
            port: port,
            username: username,
            identityFilePath: identityFilePath,
            daemonBaseURL: daemonURL,
            defaultWorkspacePath: workspacePath
        )
        runtime.displayName = displayName
        runtime.transport = transport
        runtime.port = clampedPort(port)
        if transport == .ssh {
            runtime.host = host
            runtime.username = username
            runtime.port = clampedPort(port)
            runtime.identityFilePath = identityFilePath
            runtime.daemonBaseURL = nil
        } else {
            runtime.daemonBaseURL = daemonURL
            runtime.host = daemonHost(from: daemonURL)
            runtime.port = daemonPort(from: daemonURL)
            runtime.username = ""
            runtime.identityFilePath = nil
            RemoteRuntimeSecretStore.saveDaemonToken(daemonToken, runtimeID: runtime.id)
        }
        runtime.defaultWorkspacePath = workspacePath
        upsertLocal(runtime.normalized)
        statusMessage = L10n.Settings.RemoteRuntimes.savedStatus
    }

    private func probeSelectedRuntime() {
        guard let runtime = selectedRuntime?.normalized else { return }
        probingRuntimeID = runtime.id
        statusMessage = L10n.Settings.RemoteRuntimes.probingStatus(runtime.displayName)
        Task {
            do {
                let updated: RuntimeDescriptor
                if runtime.transport == .daemon {
                    updated = try await DaemonRuntimeBackend(descriptor: runtime).probe()
                } else {
                    updated = try await SSHRuntimeBackend(descriptor: runtime).probe()
                }
                await MainActor.run {
                    upsertLocal(updated)
                    probingRuntimeID = nil
                    statusMessage = L10n.Settings.RemoteRuntimes.probeSucceeded(updated.platform.displayName, updated.arch.displayName)
                }
            } catch {
                await MainActor.run {
                    probingRuntimeID = nil
                    statusMessage = L10n.Settings.RemoteRuntimes.probeFailed(error.localizedDescription)
                }
            }
        }
    }

    private func deleteSelected() {
        guard let selectedRuntimeID else { return }
        RemoteRuntimeSecretStore.deleteDaemonToken(runtimeID: selectedRuntimeID)
        runtimes.removeAll { $0.id == selectedRuntimeID }
        AgentRuntimeStore.saveDescriptors(runtimes)
        self.selectedRuntimeID = runtimes.first?.id
        loadSelectedRuntime()
        statusMessage = L10n.Settings.RemoteRuntimes.deletedStatus
    }

    private func upsertLocal(_ runtime: RuntimeDescriptor) {
        if let index = runtimes.firstIndex(where: { $0.id == runtime.id }) {
            runtimes[index] = runtime
        } else {
            runtimes.append(runtime)
        }
        saveAll()
        selectedRuntimeID = runtime.id
        loadSelectedRuntime()
    }

    private func saveAll() {
        runtimes = runtimes.map(\.normalized)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        AgentRuntimeStore.saveDescriptors(runtimes)
    }

    private func reload() {
        runtimes = AgentRuntimeStore.loadDescriptors()
    }

    private var canProbe: Bool {
        switch transport {
        case .ssh:
            return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .daemon:
            return URL(string: daemonURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .local:
            return false
        }
    }

    private func capabilityLine(_ runtime: RuntimeDescriptor) -> String {
        let git = runtime.capabilities.hasGit ? "git" : "no git"
        let rg = runtime.capabilities.hasRipgrep ? "rg" : "no rg"
        let shell = runtime.capabilities.shellPath ?? "shell unknown"
        return "\(git), \(rg), \(shell)"
    }

    private func toolchainLine(_ runtime: RuntimeDescriptor) -> String {
        [
            runtime.capabilities.nodeVersion.map { "node \($0)" },
            runtime.capabilities.npmVersion.map { "npm \($0)" },
            runtime.capabilities.yarnVersion.map { "yarn \($0)" },
            runtime.capabilities.pythonVersion,
            runtime.capabilities.pipVersion,
            runtime.capabilities.rubyVersion,
            runtime.capabilities.goVersion,
            runtime.capabilities.javaVersion
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func collaborationLine(_ runtime: RuntimeDescriptor) -> String {
        guard let ghVersion = runtime.capabilities.ghVersion else {
            return L10n.Settings.RemoteRuntimes.githubCLIMissing
        }
        var values = ["gh \(ghVersion)"]
        if let authStatus = runtime.capabilities.ghAuthStatus {
            values.append("auth: \(authStatus)")
        } else {
            values.append(L10n.Settings.RemoteRuntimes.githubCLIAuthSuggested)
        }
        return values.joined(separator: "\n")
    }

    private func mirrorLine(_ runtime: RuntimeDescriptor) -> String {
        [
            runtime.capabilities.npmRegistry.map { "npm: \($0)" },
            runtime.capabilities.yarnRegistry.map { "yarn: \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private func proxyLine(_ runtime: RuntimeDescriptor) -> String {
        var values: [String] = []
        if let npmProxy = runtime.capabilities.npmProxy {
            values.append("npm proxy: \(npmProxy)")
        }
        if let npmHTTPSProxy = runtime.capabilities.npmHTTPSProxy {
            values.append("npm https-proxy: \(npmHTTPSProxy)")
        }
        if let pipProxy = runtime.capabilities.pipProxy {
            values.append("pip proxy: \(pipProxy)")
        }
        values += runtime.capabilities.proxyEnvironment
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
        return values.joined(separator: "\n")
    }
}

private extension RuntimeDescriptor {
    var hostLine: String {
        if transport == .daemon {
            return daemonBaseURL ?? daemonEndpointURL?.absoluteString ?? "daemon"
        }
        let prefix = username.isEmpty ? host : "\(username)@\(host)"
        return "\(prefix):\(port)"
    }
}

private func daemonHost(from value: String) -> String {
    URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "127.0.0.1"
}

private func daemonPort(from value: String) -> Int {
    URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.port ?? 8765
}

private func clampedPort(_ value: Int) -> Int {
    min(max(value, remoteRuntimePortRange.lowerBound), remoteRuntimePortRange.upperBound)
}
