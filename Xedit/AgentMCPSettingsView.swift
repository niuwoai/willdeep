//
//  AgentMCPSettingsView.swift
//  VeilWriter
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
    @State private var isRefreshing: Set<String> = []
    @State private var isCreatingServer = false
    @State private var statusMessage = "All changes saved"

    private var enabledCount: Int {
        servers.filter(\.isEnabled).count
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Servers available in this workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(enabledCount) of \(servers.count) MCP servers enabled")
                        .font(.headline)
                }

                HStack {
                    Button {
                        refreshServers()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        openCursorConfig()
                    } label: {
                        Label("Cursor mcp.json", systemImage: "curlybraces")
                    }

                    Spacer()

                    Button {
                        isCreatingServer = true
                    } label: {
                        Label("New MCP Server", systemImage: "plus")
                    }
                }
            }

            serverSection(title: "User MCP Servers", source: .user)
            serverSection(title: "Cursor MCP Servers", source: .cursor)
            serverSection(title: "Codex MCP Servers", source: .codex)
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
                statusMessage = "Created \(server.name)."
            } onCancel: {
                isCreatingServer = false
            }
        }
    }

    private func serverSection(title: String, source: AgentMCPServerSource) -> some View {
        let sourceServers = servers.filter { $0.source == source }
        return Section {
            if sourceServers.isEmpty {
                Text("No servers in this group.")
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
                        Button("Logout") {
                            AgentMCPSettingsStore.clearAuthorizationHeader(id: server.id)
                            refreshServers()
                            statusMessage = "Authorization header cleared for \(server.name)."
                        }
                        .font(.caption)
                    }
                }

                HStack(spacing: 6) {
                    if let count = toolCounts[server.id] {
                        Text("\(count) tools enabled")
                    } else {
                        Text(server.isEnabled ? "Tool list not refreshed" : "Disabled")
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
                    Text("headers: \(redactedHeadersText(server))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let message = serverMessages[server.id] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("Failed") ? .red : .secondary)
                }

                HStack {
                    Button {
                        refreshTools(for: server)
                    } label: {
                        Label("Refresh Tools", systemImage: "arrow.clockwise")
                    }
                    .disabled(!server.isEnabled || isRefreshing.contains(server.id))

                    if server.source == .user {
                        Button(role: .destructive) {
                            AgentMCPSettingsStore.deleteUserServer(id: server.id)
                            refreshServers()
                            statusMessage = "Deleted \(server.name)."
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { enabled in
                    AgentMCPSettingsStore.setServerEnabled(id: server.id, enabled: enabled)
                    refreshServers()
                    statusMessage = "All changes saved"
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    private func refreshTools(for server: AgentMCPServerConfig) {
        isRefreshing.insert(server.id)
        serverMessages[server.id] = nil
        Task {
            do {
                let result = try await AgentMCPBridge.listTools(arguments: ["server": .string(server.name)])
                let count = AgentMCPBridge.parseToolCount(from: result.payload) ?? 0
                await MainActor.run {
                    toolCounts[server.id] = count
                    serverMessages[server.id] = "Last checked: \(Date.now.formatted(date: .omitted, time: .shortened))"
                    isRefreshing.remove(server.id)
                }
            } catch {
                await MainActor.run {
                    serverMessages[server.id] = "Failed: \(error.localizedDescription)"
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
            statusMessage = "Opened Cursor mcp.json."
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
            statusMessage = "Cursor mcp.json does not exist yet."
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
            Text("New MCP Server")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Server name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Transport", selection: $transport) {
                ForEach(AgentMCPTransport.allCases) { transport in
                    Text(transport.displayName).tag(transport)
                }
            }
            .pickerStyle(.segmented)

            if transport == .streamableHTTP {
                TextField("https://example.com/mcp", text: $url)
                    .textFieldStyle(.roundedBorder)

                Text("Headers")
                    .font(.headline)
                TextEditor(text: $headerLines)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                Text("One header per line, for example: Authorization=Bearer ...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("/absolute/path/to/server", text: $command)
                    .textFieldStyle(.roundedBorder)

                TextField("Arguments separated by spaces", text: $args)
                    .textFieldStyle(.roundedBorder)

                Text("Environment")
                    .font(.headline)
                TextEditor(text: $envLines)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                Text("One variable per line, for example: HTTPS_PROXY=http://127.0.0.1:7890")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Timeout") {
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
                Button("Cancel") {
                    onCancel()
                }
                Button("Create") {
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
            errorMessage = "Server name is required."
            return
        }

        switch transport {
        case .streamableHTTP:
            guard URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
                errorMessage = "A valid server URL is required."
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
                errorMessage = "Command is required."
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
