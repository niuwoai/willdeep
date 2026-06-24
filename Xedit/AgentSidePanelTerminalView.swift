//
//  AgentSidePanelTerminalView.swift
//  WillDeep
//
//  Right-side Agent-mode terminal panel. Multi-tab, SwiftTerm-backed.
//  Each tab is a full terminal emulator; tabs default to a local login
//  shell and remember which Agent session opened them.
//

import AppKit
import SwiftUI

struct AgentSidePanelTerminalView: View {
    @EnvironmentObject var appState: AppState

    private var controller: AgentInteractiveTerminalController {
        appState.agentTerminalController
    }

    private var settings: EditorTerminalSettings {
        appState.editorTerminalSettings.normalized()
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.5)
            terminalSurface
        }
        .onAppear {
            controller.selectRuntimeIfNeeded()
            controller.ensureAtLeastOneTab(
                originAgentSessionID: appState.activeAgentSessionID,
                workingDirectory: workingDirectory,
                settings: settings
            )
            controller.applyAppearanceToAll(settings)
        }
        .onCompatibleChange(of: appState.editorTerminalSettings) { _, _ in
            // Live-apply font / color changes (e.g. switching to a Nerd
            // Font to fix powerline glyphs) to already-open tabs.
            controller.applyAppearanceToAll(settings)
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 6)
            }
            // 让 tab 滚动区只吃「剩余」宽度,窄侧栏时长标签横向滚动,
            // 不会把右侧「+」挤出可视区。`+` 用 layoutPriority 先拿空间。
            .frame(maxWidth: .infinity, alignment: .leading)
            addTabMenu
                .layoutPriority(1)
        }
        .frame(height: 30)
        .padding(.trailing, 6)
    }

    private func tabChip(_ tab: AgentTerminalTab) -> some View {
        let isActive = controller.activeTabID == tab.id
        return HStack(spacing: 5) {
            Image(systemName: tab.kind.isSSH ? "network" : "terminal")
                .font(.system(size: 9))
                .foregroundStyle(tab.isRunning ? Color.green : Color.secondary)
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                // 标题封顶,避免 `rocky@host:/` 这种长 OSC 标题把
                // 整个 chip 撑得占满侧栏、把 `+` 顶出去。
                .frame(maxWidth: 130)
            Button {
                controller.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(originBadgeColor(tab), lineWidth: isOpenedByCurrentSession(tab) ? 1 : 0)
        )
        .help(tabTooltip(tab))
        .contentShape(Rectangle())
        .onTapGesture {
            controller.activeTabID = tab.id
        }
    }

    private var addTabMenu: some View {
        Menu {
            Button {
                controller.openLocalTab(
                    originAgentSessionID: appState.activeAgentSessionID,
                    workingDirectory: workingDirectory,
                    settings: settings
                )
            } label: {
                Label(L10n.AgentTerminal.newLocalTab, systemImage: "terminal")
            }
            if !controller.runtimeOptions.isEmpty {
                Divider()
                ForEach(controller.runtimeOptions) { runtime in
                    Button {
                        controller.openSSHTab(
                            runtime: runtime,
                            originAgentSessionID: appState.activeAgentSessionID,
                            settings: settings
                        )
                    } label: {
                        Label(L10n.AgentTerminal.newSSHTab(runtime.displayName), systemImage: "network")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.AgentTerminal.newTab)
    }

    // MARK: Terminal surface

    @ViewBuilder
    private var terminalSurface: some View {
        if let tab = controller.activeTab {
            AgentTerminalViewRepresentable(terminalView: tab.terminalView)
                .id(tab.id)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(L10n.AgentTerminal.emptyOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Helpers

    private var workingDirectory: String? {
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return path
        }
        return appState.rootDirectory?.standardizedFileURL.path
    }

    private func isOpenedByCurrentSession(_ tab: AgentTerminalTab) -> Bool {
        guard let origin = tab.originAgentSessionID,
              let active = appState.activeAgentSessionID else { return false }
        return origin == active
    }

    private func originBadgeColor(_ tab: AgentTerminalTab) -> Color {
        isOpenedByCurrentSession(tab) ? Color.accentColor.opacity(0.55) : Color.clear
    }

    private func tabTooltip(_ tab: AgentTerminalTab) -> String {
        var lines = [tab.title]
        switch tab.kind {
        case .localShell:
            lines.append(L10n.AgentTerminal.localShellTooltip)
        case .ssh(_, _, let target):
            lines.append(target)
        }
        if isOpenedByCurrentSession(tab) {
            lines.append(L10n.AgentTerminal.openedByThisSession)
        }
        return lines.joined(separator: " · ")
    }
}

/// Hosts a SwiftTerm LocalProcessTerminalView (owned by the tab) inside
/// SwiftUI. The view instance is stable for the tab's lifetime, so this
/// representable just mounts/focuses it.
struct AgentTerminalViewRepresentable: NSViewRepresentable {
    let terminalView: AgentLocalProcessTerminalView

    func makeNSView(context: Context) -> AgentLocalProcessTerminalView {
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: AgentLocalProcessTerminalView, context: Context) {}
}
