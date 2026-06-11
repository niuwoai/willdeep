//
//  AgentMCPSettingsView.swift
//  WillDeep
//
//  Settings tab for MCP servers.
//

import SwiftUI
import AppKit

struct AgentMCPSettingsView: View {
    @State private var settings = AgentMCPSettingsStore.load()
    @State private var servers = AgentMCPServerDirectory.list(includeDisabled: true)
    @State private var toolCounts: [String: Int] = [:]
    @State private var serverMessages: [String: String] = [:]
    @State private var serverMessageIsError: Set<String> = []
    @State private var isRefreshing: Set<String> = []
    @State private var isCreatingServer = false
    @State private var statusMessage = L10n.Settings.allChangesSaved

    private var enabledCount: Int {
        servers.filter(\.isEnabled).count
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Settings.MCP.serversDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.Settings.MCP.serversEnabled("\(enabledCount)", "\(servers.count)"))
                        .font(.headline)
                }

                HStack {
                    Button {
                        refreshServers()
                    } label: {
                        Label(L10n.Settings.MCP.refresh, systemImage: "arrow.clockwise")
                    }

                    Button {
                        openCursorConfig()
                    } label: {
                        Label(L10n.Settings.MCP.cursorConfig, systemImage: "curlybraces")
                    }

                    Spacer()

                    Button {
                        isCreatingServer = true
                    } label: {
                        Label(L10n.Settings.MCP.newServer, systemImage: "plus")
                    }
                }
            }

            serverSection(title: L10n.Settings.MCP.userServers, source: .user)
            serverSection(title: L10n.Settings.MCP.cursorServers, source: .cursor)
            serverSection(title: L10n.Settings.MCP.codexServers, source: .codex)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .sheet(isPresented: $isCreatingServer) {
            AgentMCPServerCreationSheet { server in
                AgentMCPSettingsStore.upsertUserServer(server)
                isCreatingServer = false
                refreshServers()
                statusMessage = L10n.Settings.MCP.createdServer(server.name)
            } onCancel: {
                isCreatingServer = false
            }
        }
    }

    private func serverSection(title: String, source: AgentMCPServerSource) -> some View {
        let sourceServers = servers.filter { $0.source == source }
        return Section {
            if sourceServers.isEmpty {
                Text(L10n.Settings.MCP.noServers)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sourceServers) { server in
                    serverRow(server)
                }
            }
        } header: {
            Text(title)
        }
    }

    private func serverRow(_ server: AgentMCPServerConfig) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 34, height: 34)
                Text(String(server.name.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(server.isEnabled ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.headline)
                    Text(server.transport.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if server.source == .user, hasAuthorizationHeader(server) {
                        Button(L10n.Settings.MCP.logout) {
                            AgentMCPSettingsStore.clearAuthorizationHeader(id: server.id)
                            refreshServers()
                            statusMessage = L10n.Settings.MCP.authCleared(server.name)
                        }
                        .font(.caption)
                    }
                }

                HStack(spacing: 6) {
                    if let count = toolCounts[server.id] {
                        Text(L10n.Settings.MCP.toolsEnabled("\(count)"))
                    } else {
                        Text(server.isEnabled ? L10n.Settings.MCP.toolListNotRefreshed : L10n.Settings.MCP.disabled)
                    }
                    if isRefreshing.contains(server.id) {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(server.summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if !server.redactedHeaders.isEmpty {
                    Text(L10n.Settings.MCP.headersPrefix(redactedHeadersText(server)))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let message = serverMessages[server.id] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(serverMessageIsError.contains(server.id) ? .red : .secondary)
                }

                HStack {
                    Button {
                        refreshTools(for: server)
                    } label: {
                        Label(L10n.Settings.MCP.refreshTools, systemImage: "arrow.clockwise")
                    }
                    .disabled(!server.isEnabled || isRefreshing.contains(server.id))

                    if server.source == .user {
                        Button(role: .destructive) {
                            AgentMCPSettingsStore.deleteUserServer(id: server.id)
                            refreshServers()
                            statusMessage = L10n.Settings.MCP.deletedServer(server.name)
                        } label: {
                            Label(L10n.Settings.MCP.delete, systemImage: "trash")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Spacer()

            // 1.58: three-tier trust menu. Filled green shield = fully
            // trusted (every call auto-runs, writes included — for the
            // user's own MCPs); outline check = standard (read-style
            // auto, writes gate); orange filled = untrusted (everything
            // gates, Always-Allow ignored).
            let trustLevel: AgentMCPServerTrustLevel = settings.untrustedServerIDs.contains(server.id)
                ? .untrusted
                : (settings.trustedServerIDs.contains(server.id) ? .fullyTrusted : .standard)
            Menu {
                Picker(L10n.Settings.MCP.trustLevelHelp, selection: Binding(
                    get: { trustLevel },
                    set: { newLevel in
                        AgentMCPSettingsStore.setServerTrustLevel(id: server.id, level: newLevel)
                        refreshServers()
                        switch newLevel {
                        case .fullyTrusted:
                            statusMessage = L10n.Settings.MCP.markedFullyTrusted(server.name)
                        case .standard:
                            statusMessage = L10n.Settings.MCP.markedTrusted(server.name)
                        case .untrusted:
                            statusMessage = L10n.Settings.MCP.markedUntrusted(server.name)
                        }
                    }
                )) {
                    Label(L10n.Settings.MCP.trustLevelFull, systemImage: "checkmark.shield.fill")
                        .tag(AgentMCPServerTrustLevel.fullyTrusted)
                    Label(L10n.Settings.MCP.trustLevelStandard, systemImage: "checkmark.shield")
                        .tag(AgentMCPServerTrustLevel.standard)
                    Label(L10n.Settings.MCP.trustLevelUntrusted, systemImage: "exclamationmark.shield.fill")
                        .tag(AgentMCPServerTrustLevel.untrusted)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                switch trustLevel {
                case .fullyTrusted:
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 13, weight: .medium))
                case .standard:
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 13, weight: .medium))
                case .untrusted:
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(Color.orange)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help({
                switch trustLevel {
                case .fullyTrusted: return L10n.Settings.MCP.trustLevelFull
                case .standard: return L10n.Settings.MCP.trustLevelStandard
                case .untrusted: return L10n.Settings.MCP.trustLevelUntrusted
                }
            }())

            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { enabled in
                    AgentMCPSettingsStore.setServerEnabled(id: server.id, enabled: enabled)
                    refreshServers()
                    statusMessage = L10n.Settings.allChangesSaved
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    private func refreshTools(for server: AgentMCPServerConfig) {
        isRefreshing.insert(server.id)
        serverMessages[server.id] = nil
        serverMessageIsError.remove(server.id)
        Task {
            do {
                let result = try await AgentMCPBridge.listTools(arguments: ["server": .string(server.name)])
                let count = AgentMCPBridge.parseToolCount(from: result.payload) ?? 0
                await MainActor.run {
                    toolCounts[server.id] = count
                    serverMessages[server.id] = L10n.Settings.MCP.lastChecked(Date.now.formatted(date: .omitted, time: .shortened))
                    serverMessageIsError.remove(server.id)
                    isRefreshing.remove(server.id)
                }
            } catch {
                await MainActor.run {
                    serverMessages[server.id] = L10n.Settings.MCP.failedPrefix(error.localizedDescription)
                    serverMessageIsError.insert(server.id)
                    isRefreshing.remove(server.id)
                }
            }
        }
    }

    private func refreshServers() {
        settings = AgentMCPSettingsStore.load()
        servers = AgentMCPServerDirectory.list(includeDisabled: true)
        toolCounts = toolCounts.filter { id, _ in servers.contains { $0.id == id } }
        serverMessages = serverMessages.filter { id, _ in servers.contains { $0.id == id } }
    }

    private func openCursorConfig() {
        let url = AgentMCPServerDirectory.cursorConfigURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            statusMessage = L10n.Settings.MCP.openedCursorConfig
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
            statusMessage = L10n.Settings.MCP.cursorConfigMissing
        }
    }

    private func hasAuthorizationHeader(_ server: AgentMCPServerConfig) -> Bool {
        server.headers.keys.contains { $0.lowercased() == "authorization" }
    }

    private func redactedHeadersText(_ server: AgentMCPServerConfig) -> String {
        server.redactedHeaders
            .keys
            .sorted()
            .map { "\($0)=\(server.redactedHeaders[$0] ?? "")" }
            .joined(separator: ", ")
    }
}

private struct AgentMCPServerCreationSheet: View {
    @State private var name = ""
    @State private var transport: AgentMCPTransport = .streamableHTTP
    @State private var url = ""
    @State private var command = ""
    @State private var args = ""
    @State private var envLines = ""
    @State private var headerLines = ""
    @State private var timeout = 30.0
    @State private var errorMessage = ""

    let onCreate: (AgentMCPServerConfig) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Settings.MCP.newServerTitle)
                .font(.title3)
                .fontWeight(.semibold)

            TextField(L10n.Settings.MCP.serverNamePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)

            Picker(L10n.Settings.MCP.transportLabel, selection: $transport) {
                ForEach(AgentMCPTransport.allCases) { transport in
                    Text(transport.displayName).tag(transport)
                }
            }
            .pickerStyle(.segmented)

            if transport == .streamableHTTP {
                TextField(L10n.Settings.MCP.urlPlaceholder, text: $url)
                    .textFieldStyle(.roundedBorder)

                Text(L10n.Settings.MCP.headersLabel)
                    .font(.headline)
                TextEditor(text: $headerLines)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                Text(L10n.Settings.MCP.headersHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField(L10n.Settings.MCP.commandPathPlaceholder, text: $command)
                    .textFieldStyle(.roundedBorder)

                TextField(L10n.Settings.MCP.argsPlaceholder, text: $args)
                    .textFieldStyle(.roundedBorder)

                Text(L10n.Settings.MCP.environmentLabel)
                    .font(.headline)
                TextEditor(text: $envLines)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                Text(L10n.Settings.MCP.environmentHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent(L10n.Settings.MCP.timeoutLabel) {
                HStack {
                    Slider(value: $timeout, in: 1...180, step: 1)
                    Text("\(Int(timeout))s")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.Settings.MCP.cancelButton) {
                    onCancel()
                }
                Button(L10n.Settings.MCP.createButton) {
                    createServer()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func createServer() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = L10n.Settings.MCP.errorServerNameRequired
            return
        }

        switch transport {
        case .streamableHTTP:
            guard URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
                errorMessage = L10n.Settings.MCP.errorValidURLRequired
                return
            }
            onCreate(AgentMCPServerConfig(
                name: trimmedName,
                source: .user,
                transport: .streamableHTTP,
                url: url,
                headers: parseKeyValueLines(headerLines),
                startupTimeout: timeout
            ))
        case .stdio:
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else {
                errorMessage = L10n.Settings.MCP.errorCommandRequired
                return
            }
            onCreate(AgentMCPServerConfig(
                name: trimmedName,
                source: .user,
                transport: .stdio,
                command: trimmedCommand,
                args: args.split(separator: " ").map(String.init),
                env: parseKeyValueLines(envLines),
                startupTimeout: timeout
            ))
        }
    }

    private func parseKeyValueLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
