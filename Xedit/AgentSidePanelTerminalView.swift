//
//  AgentSidePanelTerminalView.swift
//  WillDeep
//
//  Right-side Agent-mode terminal panel.
//

import AppKit
import SwiftUI

struct AgentSidePanelTerminalView: View {
    @EnvironmentObject var appState: AppState

    private var controller: AgentInteractiveTerminalController {
        appState.agentTerminalController
    }

    private var session: AgentInteractiveTerminalSession {
        controller.session
    }

    private var settings: EditorTerminalSettings {
        appState.editorTerminalSettings.normalized()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            terminalSurface
            if !session.pendingAutoCommands.isEmpty {
                pendingQueue
            }
        }
        .onAppear {
            controller.selectRuntimeIfNeeded()
        }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: runtimeSelection) {
                    if controller.runtimeOptions.isEmpty {
                        Text(L10n.AgentTerminal.noRuntimeShort).tag(UUID?.none)
                    } else {
                        ForEach(controller.runtimeOptions) { runtime in
                            Text(runtime.displayName).tag(Optional(runtime.id))
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button {
                    if session.isRunning {
                        controller.disconnect()
                    } else {
                        controller.connect(settings: settings)
                    }
                } label: {
                    Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(session.isRunning ? L10n.AgentTerminal.disconnect : L10n.AgentTerminal.connect)

                Menu {
                    serviceMenuContent
                } label: {
                    Image(systemName: "server.rack")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(L10n.AgentTerminal.services)
                .disabled(!session.isRunning)

                Button {
                    copyOutput()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.AgentTerminal.copyOutput)
                .disabled(session.output.isEmpty)

                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.AgentTerminal.clear)
                .disabled(session.output.isEmpty)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(AgentDesign.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var terminalSurface: some View {
        EditorTerminalTextSurface(
            text: session.output.isEmpty ? L10n.AgentTerminal.emptyOutput : session.output,
            settings: settings,
            onInput: { data in
                controller.sendUserInput(data)
            },
            onPasteText: { text in
                controller.sendUserText(text)
            }
        )
        .background(Color(nsColor: settings.colorScheme.background))
    }

    private var pendingQueue: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.AgentTerminal.pendingAutoCommands)
                .font(AgentDesign.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(session.pendingAutoCommands.enumerated()), id: \.offset) { _, command in
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder
    private var serviceMenuContent: some View {
        let services = controller.selectedRuntime?.terminalProfile?.normalized.serviceNames
            ?? RuntimeTerminalProfile.default.serviceNames
        if services.isEmpty {
            Text(L10n.AgentTerminal.noServices)
        } else {
            ForEach(services, id: \.self) { service in
                Menu(service) {
                    Button(L10n.AgentTerminal.serviceStatus) {
                        sendTemplate("systemctl status \(AgentToolRunner.shellQuoted(service)) --no-pager")
                    }
                    Button(L10n.AgentTerminal.serviceRestart) {
                        sendTemplate("sudo systemctl restart \(AgentToolRunner.shellQuoted(service))")
                    }
                    Button(L10n.AgentTerminal.serviceLogs) {
                        sendTemplate("journalctl -u \(AgentToolRunner.shellQuoted(service)) -n 120 --no-pager")
                    }
                    Button(L10n.AgentTerminal.serviceLogsFollow) {
                        sendTemplate("journalctl -u \(AgentToolRunner.shellQuoted(service)) -f")
                    }
                }
            }
            Divider()
            Button(L10n.AgentTerminal.dockerPs) {
                sendTemplate("docker ps")
            }
            Button(L10n.AgentTerminal.dockerLogs) {
                sendTemplate("docker logs --tail 120 <container>")
            }
        }
    }

    private var runtimeSelection: Binding<UUID?> {
        Binding {
            controller.selectedRuntimeID
        } set: { newValue in
            controller.selectedRuntimeID = newValue
        }
    }

    private var statusText: String {
        if session.isRunning {
            return L10n.AgentTerminal.connected(session.runtimeName, session.runtimeTarget)
        }
        if controller.runtimeOptions.isEmpty {
            return L10n.AgentTerminal.noRuntime
        }
        return L10n.AgentTerminal.disconnected
    }

    private func sendTemplate(_ command: String) {
        controller.sendUserText(command + "\n")
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.output, forType: .string)
    }
}

