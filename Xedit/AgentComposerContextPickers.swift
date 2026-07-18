import SwiftUI

// MARK: - Composer run context

struct AgentComposerRunContextBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    WorkspacePickerPill()
                    AgentRunLocationPickerPill()
                    branchPill
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentExecutionPickerPill()
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable(false)
    }

    private var branchPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
            Text(appState.agentWorkspaceGitStatus.branchName ?? L10n.ComposerWorkspace.noBranch)
                .font(AgentDesign.secondaryFont)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        .help(L10n.ComposerWorkspace.currentBranch)
        .fixedSize()
    }
}

struct AgentRunLocationPickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            Button {
                guard let primary = appState.agentGitWorktrees.first(where: \.isPrimary) else { return }
                appState.moveActiveAgentSessionToWorkspace(at: primary.path)
            } label: {
                Label(L10n.ComposerWorkspace.localRun, systemImage: "laptopcomputer")
            }
            .disabled(primaryWorktree == nil || isPrimaryWorkspace)

            Button {
                appState.createAgentGitWorktreeFromActiveWorkspace()
            } label: {
                Label(L10n.ComposerWorkspace.newWorktreeRun, systemImage: "arrow.triangle.branch")
            }
            .disabled(!appState.agentWorkspaceGitStatus.isRepository || appState.agentGitWorktreeCreation != nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPrimaryWorkspace ? "laptopcomputer" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(isPrimaryWorkspace
                    ? L10n.ComposerWorkspace.localRun
                    : L10n.ComposerWorkspace.newWorktreeRun)
                    .font(AgentDesign.secondaryFont)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help(isPrimaryWorkspace
            ? L10n.ComposerWorkspace.localRunHelp
            : L10n.ComposerWorkspace.newWorktreeRunHelp)
    }

    private var primaryWorktree: AgentGitWorktree? {
        appState.agentGitWorktrees.first(where: \.isPrimary)
    }

    private var activeWorkspacePath: String? {
        appState.activeRuntime?.workspaceLocation?.localPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
    }

    private var isPrimaryWorkspace: Bool {
        guard let activeWorkspacePath,
              let primaryWorktree else { return true }
        return activeWorkspacePath == primaryWorktree.url.path
    }
}

// MARK: - Approval mode picker

struct AgentApprovalModePickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(AgentApprovalMode.allCases) { mode in
                Button {
                    appState.setAgentApprovalMode(mode)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: mode.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                            Text(mode.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if appState.agentApprovalMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.agentApprovalMode.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.agentApprovalMode.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help(L10n.ApprovalMode.pickerHelp)
    }

    private var pillForeground: Color {
        appState.agentApprovalMode == .workspaceAccess ? Color.white : Color.secondary
    }

    private var pillBackground: Color {
        switch appState.agentApprovalMode {
        case .requestEveryTime: return Color.secondary.opacity(0.10)
        case .smart: return Color.accentColor.opacity(0.14)
        case .workspaceAccess: return Color.accentColor
        }
    }

    private var pillBorder: Color {
        switch appState.agentApprovalMode {
        case .requestEveryTime: return Color.secondary.opacity(0.25)
        case .smart: return Color.accentColor.opacity(0.35)
        case .workspaceAccess: return Color.clear
        }
    }
}
