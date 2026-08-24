import AppKit
import SwiftUI

// Composer chrome deliberately stays monochrome, matching Codex's quiet
// black/white/gray hierarchy. State is communicated by weight and opacity
// instead of borrowing the app accent color.
enum AgentComposerChrome {
    static let cardFill = Color(nsColor: .textBackgroundColor)
    static let controlFill = Color.primary.opacity(0.045)
    static let selectedControlFill = Color.primary.opacity(0.085)
    static let strongControlFill = Color.primary.opacity(0.13)
    static let border = Color.primary.opacity(0.10)
    static let selectedBorder = Color.primary.opacity(0.17)
    static let strongBorder = Color.primary.opacity(0.23)
    static let actionFill = Color.primary.opacity(0.82)
    static let actionForeground = Color(nsColor: .textBackgroundColor)
    static let iconPrimary = Color.primary.opacity(0.82)
    static let iconSecondary = Color.secondary
    static let iconMuted = Color.secondary.opacity(0.58)
    static let iconDisabled = Color.secondary.opacity(0.34)

    // MARK: - Bottom action row metrics
    //
    // The row's four controls used to size themselves independently, so the
    // mic circle sat 4pt smaller than send/stop and the two bare glyphs
    // differed by 1pt — visible as a ragged row. Sizes live here so a new
    // control inherits the row's scale instead of picking its own.

    /// Diameter of the filled circular actions (mic, send/stop).
    static let actionDiameter: CGFloat = 26
    /// Point size of the bare glyph buttons (attach, insert secret).
    static let barIconSize: CGFloat = 16
    /// Point size of a glyph drawn inside `actionDiameter`.
    static let actionGlyphSize: CGFloat = 11
}

extension View {
    /// Keep an overflow "…" menu in the quiet gray hierarchy.
    ///
    /// `Menu` with `.borderlessButton` ignores the label's own
    /// `foregroundStyle` and falls back to the macOS accent tint, so every
    /// one of these ended up system blue no matter what the label asked for
    /// — the label styling was not wrong, it was simply not consulted.
    /// `.tint` is the level AppKit actually reads. Applied at each call site
    /// rather than to a shared container so a deliberately accented control
    /// nearby is not swept up with it.
    func agentQuietMenuChrome(_ color: Color = AgentComposerChrome.iconSecondary) -> some View {
        symbolRenderingMode(.monochrome)
            .tint(color)
    }
}

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
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize
                ))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AgentComposerChrome.controlFill)
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
                appState.moveActiveAgentSessionToGitWorktree(
                    at: primary.path,
                    sidebarWorkspaceRootPath: primary.path
                )
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
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AgentComposerChrome.controlFill)
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
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 11,
                        weight: .medium
                    ))
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
        appState.agentApprovalMode == .requestEveryTime ? Color.secondary : Color.primary
    }

    private var pillBackground: Color {
        switch appState.agentApprovalMode {
        case .requestEveryTime: return AgentComposerChrome.controlFill
        case .smart: return AgentComposerChrome.selectedControlFill
        // 静默模式用最重的一档底色：它是唯一一个「几乎不会再拦你」的档位，
        // 用户扫一眼 composer 就该看出自己正处在哪种姿态里。
        case .silent: return AgentComposerChrome.strongControlFill
        case .workspaceAccess: return AgentComposerChrome.strongControlFill
        }
    }

    private var pillBorder: Color {
        switch appState.agentApprovalMode {
        case .requestEveryTime: return AgentComposerChrome.border
        case .smart: return AgentComposerChrome.selectedBorder
        case .silent: return AgentComposerChrome.strongBorder
        case .workspaceAccess: return AgentComposerChrome.strongBorder
        }
    }
}
