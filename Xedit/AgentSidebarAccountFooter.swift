//
//  AgentSidebarAccountFooter.swift
//  WillDeep
//
//  Compact account status row and Codex-style account popover for the
//  lower-left Agent sidebar.
//

import AppKit
import SwiftUI

enum AgentSidebarAccountMetrics {
    static let footerHorizontalPadding: CGFloat = 8
    static let footerVerticalPadding: CGFloat = 4
    static let accountRowHeight: CGFloat = 32
    static let accountCornerRadius: CGFloat = 8
    static let avatarSize: CGFloat = 20
    static let helpButtonSize: CGFloat = 28
    static let menuWidth: CGFloat = 344
    static let menuHeaderHeight: CGFloat = 34
    static let menuRowHeight: CGFloat = 34
    /// 低余额是温和提醒而非错误。浅色外观使用低饱和赭石棕保证小字号对比度，
    /// 深色外观提升亮度；两者都比系统红更安静。
    static let lowCreditsTextColor = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.86, green: 0.66, blue: 0.32, alpha: 1)
        }
        return NSColor(srgbRed: 0.49, green: 0.32, blue: 0.10, alpha: 1)
    })
}

enum AgentSidebarAccountLinks {
    static func helpURL(preferredLanguages: [String] = Locale.preferredLanguages) -> URL {
        let locale = preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh" : "en"
        return URL(string: "https://some.im/\(locale)/products/willdeep")!
    }
}

struct AgentSidebarAccountFooter: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var desktopPet = DesktopPetWindowManager.shared

    let account: SomeIMAccount?
    let isAuthenticated: Bool
    let isRefreshingAccount: Bool
    let accountStatus: String
    let onOpenAccount: () -> Void
    let onOpenLogin: () -> Void
    let onRefreshAccount: () -> Void
    let onOpenSettings: () -> Void
    let onLogOut: () -> Void
    let onOpenHelp: () -> Void

    @State private var isAccountHovered = false
    @State private var isAccountMenuPresented = false
    @State private var isLogOutConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                // Sessions blocked on the user come first: the update banner
                // can wait, a stalled agent cannot.
                AgentSidebarPendingApprovalStrip()
                if let update = appState.availableAppUpdate {
                    appUpdateBanner(update)
                }
                HStack(spacing: 8) {
                    accountControl
                    helpButton
                }
            }
            .padding(.horizontal, AgentSidebarAccountMetrics.footerHorizontalPadding)
            .padding(.vertical, AgentSidebarAccountMetrics.footerVerticalPadding)
        }
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.48))
        .alert(L10n.SidebarAccount.logOutTitle, isPresented: $isLogOutConfirmationPresented) {
            Button(L10n.SidebarAccount.cancel, role: .cancel) {}
            Button(L10n.SidebarAccount.logOut, role: .destructive, action: onLogOut)
        } message: {
            Text(L10n.SidebarAccount.logOutMessage)
        }
    }

    @ViewBuilder
    private var accountControl: some View {
        if let account {
            Button {
                isAccountMenuPresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    accountAvatar(account)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(L10n.Sidebar.someIMCredits(account.compactDisplayCredits))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(account.isLowOnCredits ? AgentSidebarAccountMetrics.lowCreditsTextColor : Color.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: AgentSidebarAccountMetrics.accountRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accountControlBackground)
                .contentShape(RoundedRectangle(cornerRadius: AgentSidebarAccountMetrics.accountCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isAccountHovered = $0 }
            .help(accountStatus.isEmpty ? L10n.SidebarAccount.menuHelp : accountStatus)
            .popover(isPresented: $isAccountMenuPresented, arrowEdge: .bottom) {
                AgentSidebarAccountMenu(
                    account: account,
                    isRefreshingAccount: isRefreshingAccount,
                    onOpenAccount: {
                        isAccountMenuPresented = false
                        onRefreshAccount()
                        onOpenAccount()
                    },
                    onToggleDesktopPet: {
                        isAccountMenuPresented = false
                        desktopPet.attach(to: appState)
                        desktopPet.toggle()
                    },
                    onOpenSettings: {
                        isAccountMenuPresented = false
                        onOpenSettings()
                    },
                    onLogOut: {
                        isAccountMenuPresented = false
                        DispatchQueue.main.async {
                            isLogOutConfirmationPresented = true
                        }
                    }
                )
                .environmentObject(appState)
            }
        } else if isAuthenticated {
            Button(action: onOpenAccount) {
                HStack(spacing: 8) {
                    anonymousAvatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.Sidebar.someIMAccountTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L10n.Settings.SomeIM.accountConnected)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if isRefreshingAccount {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: AgentSidebarAccountMetrics.accountRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accountControlBackground)
            }
            .buttonStyle(.plain)
            .onHover { isAccountHovered = $0 }
            .help(accountStatus.isEmpty ? L10n.SidebarAccount.menuHelp : accountStatus)
        } else {
            Button(action: onOpenLogin) {
                HStack(spacing: 8) {
                    anonymousAvatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.Sidebar.someIMAccountTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L10n.Sidebar.someIMNotLoggedIn)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: AgentSidebarAccountMetrics.accountRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accountControlBackground)
            }
            .buttonStyle(.plain)
            .onHover { isAccountHovered = $0 }
            .help(L10n.Sidebar.someIMNotLoggedInTooltip)
        }
    }

    private var helpButton: some View {
        Button(action: onOpenHelp) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: AgentSidebarAccountMetrics.helpButtonSize,
                    height: AgentSidebarAccountMetrics.helpButtonSize
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.SidebarAccount.help)
        .accessibilityLabel(Text(L10n.SidebarAccount.help))
    }

    private var accountControlBackground: some View {
        RoundedRectangle(
            cornerRadius: AgentSidebarAccountMetrics.accountCornerRadius,
            style: .continuous
        )
        .fill(accountInteractionFill)
    }

    private var accountInteractionFill: Color {
        let palette = appState.editorSettings.interfaceSkin.palette
        if isAccountMenuPresented {
            return palette.selectionFill.opacity(0.92)
        }
        return isAccountHovered ? palette.hoverFill : .clear
    }

    private func appUpdateBanner(_ update: AppUpdateMeta) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.AppUpdate.sidebarTitle(update.version))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(L10n.AppUpdate.sidebarSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                appState.downloadAvailableAppUpdate()
            } label: {
                if appState.isDownloadingAppUpdate {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Text(L10n.AppUpdate.sidebarAction)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.isDownloadingAppUpdate)
            .help(L10n.AppUpdate.sidebarActionHelp)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(appState.editorSettings.interfaceSkin.palette.accent.opacity(0.12))
        )
        .padding(.bottom, 6)
    }

    private func accountAvatar(_ account: SomeIMAccount) -> some View {
        AgentSidebarAccountAvatar(
            account: account,
            size: AgentSidebarAccountMetrics.avatarSize
        )
    }

    private var anonymousAvatar: some View {
        Image(systemName: "person.crop.circle")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: AgentSidebarAccountMetrics.avatarSize, height: AgentSidebarAccountMetrics.avatarSize)
    }

}

struct AgentSidebarAccountMenu: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var desktopPet = DesktopPetWindowManager.shared

    let account: SomeIMAccount
    let isRefreshingAccount: Bool
    let onOpenAccount: () -> Void
    let onToggleDesktopPet: () -> Void
    let onOpenSettings: () -> Void
    let onLogOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                AgentSidebarAccountAvatar(
                    account: account,
                    size: AgentSidebarAccountMetrics.avatarSize
                )
                Text(account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: AgentSidebarAccountMetrics.menuHeaderHeight)

            Divider().padding(.horizontal, 8)

            AgentSidebarAccountMenuRow(
                systemImage: "gauge.with.dots.needle.50percent",
                title: L10n.SidebarAccount.remainingCredits,
                trailingText: isRefreshingAccount ? nil : account.compactDisplayCredits,
                showsProgress: isRefreshingAccount,
                showsChevron: true,
                action: onOpenAccount
            )
            AgentSidebarAccountMenuRow(
                systemImage: "pawprint",
                title: desktopPet.isEnabled ? L10n.SidebarAccount.hideDesktopPet : L10n.SidebarAccount.showDesktopPet,
                action: onToggleDesktopPet
            )
            AgentSidebarAccountMenuRow(
                systemImage: "gearshape",
                title: L10n.SidebarAccount.settings,
                trailingText: "⌘,",
                action: onOpenSettings
            )
            AgentSidebarAccountMenuRow(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: L10n.SidebarAccount.logOut,
                action: onLogOut
            )
        }
        .padding(6)
        .frame(width: AgentSidebarAccountMetrics.menuWidth)
    }
}

private struct AgentSidebarAccountAvatar: View {
    @EnvironmentObject private var appState: AppState

    let account: SomeIMAccount
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(appState.editorSettings.interfaceSkin.palette.accent.opacity(0.22))
            if let url = validatedAvatarURL {
                CachedAvatarImage(url: url) {
                    avatarInitial
                }
            } else {
                avatarInitial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarInitial: some View {
        Text(
            account.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .first
                .map { String($0).uppercased() } ?? "S"
        )
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
    }

    private var validatedAvatarURL: URL? {
        guard let value = account.avatarURL,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

private struct AgentSidebarAccountMenuRow: View {
    let systemImage: String
    let title: String
    var trailingText: String? = nil
    var showsProgress = false
    var showsChevron = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: AgentSidebarAccountMetrics.menuRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
    }
}
