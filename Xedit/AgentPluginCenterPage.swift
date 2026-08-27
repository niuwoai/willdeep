//
//  AgentPluginCenterPage.swift
//  WillDeep
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentPluginCenterPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var registry = AgentPluginRegistry.shared

    @State private var pendingProposal: AgentPluginInstallProposal?
    @State private var isGitSheetPresented = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    if registry.snapshot.records.isEmpty && !registry.isRefreshing {
                        emptyState
                    } else {
                        ForEach(registry.snapshot.records) { record in
                            pluginCard(record)
                        }
                    }
                    if !registry.snapshot.issues.isEmpty {
                        diagnosticsSection
                    }
                }
                .padding(20)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
        .tint(.primary)
        .sheet(item: $pendingProposal, onDismiss: cleanupPendingProposal) { proposal in
            AgentPluginApprovalSheet(
                proposal: proposal,
                onCancel: {
                    AgentPluginInstaller.cleanup(proposal: proposal)
                    pendingProposal = nil
                },
                onInstall: { pinnedIDs in
                    install(proposal: proposal, pinnedDestinationIDs: pinnedIDs)
                }
            )
        }
        .sheet(isPresented: $isGitSheetPresented) {
            AgentPluginGitInstallSheet { repository, reference in
                isGitSheetPresented = false
                stage(.git(repository: repository, reference: reference))
            }
        }
        .task {
            await registry.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Plugins.centerTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.Plugins.centerDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isWorking || registry.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                chooseLocalSource()
            } label: {
                Label(L10n.Plugins.installLocal, systemImage: "plus")
            }
            .buttonStyle(AgentPluginPrimaryActionButtonStyle())
            Button {
                isGitSheetPresented = true
            } label: {
                Label(L10n.Plugins.installGit, systemImage: "arrow.down.to.line")
            }
            .buttonStyle(AgentPluginPrimaryActionButtonStyle())
            Button {
                Task { await registry.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.Plugins.refresh)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(L10n.Plugins.noPlugins).font(.headline)
            Text(L10n.Plugins.noPluginsDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(L10n.Plugins.installLocal) { chooseLocalSource() }
                .buttonStyle(AgentPluginPrimaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func pluginCard(_ record: AgentPluginRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AgentPluginIcon(
                    icon: record.activePackage.codexManifest.interface?.logo
                        ?? record.activePackage.codexManifest.interface?.composerIcon,
                    packageURL: record.activePackage.packageURL,
                    presentation: .originalColor,
                    fallbackSeed: record.pluginID
                )
                .frame(width: 30, height: 30)
                .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.activePackage.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    if !record.activePackage.summary.isEmpty {
                        Text(record.activePackage.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(L10n.Plugins.installedVersion(record.activePackage.version))
                        Text("·")
                        Text(sourceTitle(record.activePackage.source))
                        Text("·")
                        Text(L10n.Plugins.destinationCount(record.activePackage.destinations.count))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if record.isApproved {
                    Toggle(
                        record.isEnabled ? L10n.Plugins.enabled : L10n.Plugins.disabled,
                        isOn: Binding(
                            get: { record.isEnabled },
                            set: { enabled in
                                registry.setEnabled(enabled, pluginID: record.pluginID)
                                if !enabled,
                                   case .plugin(let destinationID) = appState.agentPrimaryDestination,
                                   destinationID.hasPrefix("\(record.pluginID):") {
                                    appState.agentPrimaryDestination = .pluginCenter
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                } else {
                    Button(L10n.Plugins.approve) {
                        stage(.local(record.activePackage.packageURL))
                    }
                    .buttonStyle(AgentPluginApprovalActionButtonStyle())
                }
                Menu {
                    if let source = registry.installSource(for: record.activePackage) {
                        Button(L10n.Plugins.checkForUpdates) {
                            stage(
                                source.installSource,
                                previousPackage: record.activePackage
                            )
                        }
                    }
                    Button(L10n.Plugins.openInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([record.activePackage.packageURL])
                    }
                    if record.availableVersions.count > 1 {
                        Menu(L10n.Plugins.rollback) {
                            ForEach(record.availableVersions) { package in
                                Button(package.version) {
                                    if registry.isApproved(package: package) {
                                        registry.activate(version: package.version, pluginID: record.pluginID)
                                    } else {
                                        stage(
                                            .local(package.packageURL),
                                            previousPackage: record.activePackage
                                        )
                                    }
                                }
                                .disabled(package.version == record.activePackage.version)
                            }
                        }
                    }
                    if record.activePackage.source == .installed {
                        Divider()
                        Button(L10n.Plugins.uninstall, role: .destructive) {
                            uninstall(record)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let manifest = record.activePackage.manifest {
                if !manifest.permissions.isEmpty {
                    permissionChips(manifest.permissions)
                }
                if !record.activePackage.destinations.isEmpty {
                    Divider()
                    ForEach(record.activePackage.destinations) { destination in
                        destinationRow(destination, enabled: record.isEnabled)
                    }
                }
                if !manifest.contributes.settings.isEmpty {
                    Divider()
                    DisclosureGroup(L10n.Plugins.settings) {
                        VStack(spacing: 9) {
                            ForEach(manifest.contributes.settings) { setting in
                                AgentPluginSettingRow(pluginID: record.pluginID, setting: setting)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func destinationRow(
        _ destination: AgentPluginDestinationDescriptor,
        enabled: Bool
    ) -> some View {
        let pinned = registry.snapshot.pinnedDestinationIDs.contains(destination.qualifiedID)
        return HStack(spacing: 9) {
            AgentPluginIcon(icon: destination.navigation.icon, packageURL: destination.packageURL)
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
            Text(registry.localizedTitle(for: destination))
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            if destination.defaultPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.Plugins.pin)
            } else {
                Button(pinned ? L10n.Plugins.unpin : L10n.Plugins.pin) {
                    if pinned {
                        registry.unpin(destinationID: destination.qualifiedID)
                    } else {
                        registry.pin(destinationID: destination.qualifiedID)
                    }
                }
                .disabled(!enabled || (!pinned && registry.snapshot.pinnedDestinationIDs.count >= AgentPluginRegistry.maximumPinnedDestinations))
            }
            Button {
                appState.agentPrimaryDestination = .plugin(destination.qualifiedID)
            } label: {
                Image(systemName: "arrow.right")
            }
            .disabled(!enabled)
        }
        .frame(height: 28)
    }

    private func permissionChips(_ permissions: [AgentPluginPermission]) -> some View {
        HStack(spacing: 6) {
            Text(L10n.Plugins.permissions)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(permissions, id: \.rawValue) { permission in
                Text(permission.rawValue)
                    .font(.system(size: 9).monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }

    private var diagnosticsSection: some View {
        DisclosureGroup(L10n.Plugins.diagnostics) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(registry.snapshot.issues, id: \.self) { issue in
                    Text(issue)
                        .font(.system(size: 10).monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    private func chooseLocalSource() {
        let panel = NSOpenPanel()
        panel.title = L10n.Plugins.selectSource
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stage(url.hasDirectoryPath ? .local(url) : .archive(url))
    }

    private func stage(
        _ source: AgentPluginInstallSource,
        previousPackage: AgentPluginPackage? = nil
    ) {
        isWorking = true
        errorMessage = nil
        let previousPermissions = previousPackage.map {
            AgentMCPServerDirectory.requiredPluginPermissions(for: $0)
        } ?? []
        Task {
            do {
                let proposal = try await AgentPluginInstaller.stage(
                    source: source,
                    currentWillDeepVersion: currentVersion,
                    previouslyGrantedPermissions: previousPermissions
                )
                pendingProposal = proposal
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func install(
        proposal: AgentPluginInstallProposal,
        pinnedDestinationIDs: Set<String>
    ) {
        isWorking = true
        let version = currentVersion
        Task {
            do {
                let package = try await Task.detached(priority: .utility) {
                    try AgentPluginInstaller.install(
                        proposal: proposal,
                        currentWillDeepVersion: version
                    )
                }.value
                registry.approve(package: package, source: proposal.source.record)
                await registry.refresh()
                for id in pinnedDestinationIDs {
                    registry.pin(destinationID: id)
                }
                pendingProposal = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func uninstall(_ record: AgentPluginRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Plugins.uninstall
        alert.informativeText = record.activePackage.displayName
        alert.addButton(withTitle: L10n.Plugins.uninstall)
        alert.addButton(withTitle: L10n.Plugins.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AgentPluginInstaller.uninstallAllVersions(pluginID: record.pluginID)
            AgentPluginSettingsStore.removeAll(
                pluginID: record.pluginID,
                settings: record.activePackage.manifest?.contributes.settings ?? []
            )
            registry.removeInstalledPluginState(pluginID: record.pluginID)
            Task { await registry.refresh() }
            if case .plugin(let id) = appState.agentPrimaryDestination,
               id.hasPrefix("\(record.pluginID):") {
                appState.agentPrimaryDestination = .pluginCenter
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cleanupPendingProposal() {
        if let proposal = pendingProposal {
            AgentPluginInstaller.cleanup(proposal: proposal)
        }
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private func sourceTitle(_ source: AgentPluginPackageSource) -> String {
        switch source {
        case .installed:
            return String(localized: "plugins.source.installed", defaultValue: "Installed")
        case .codexCache:
            return String(localized: "plugins.source.codex-cache", defaultValue: "Codex cache")
        case .bundled:
            return String(localized: "plugins.source.bundled", defaultValue: "Bundled")
        case .draft:
            return String(localized: "plugins.source.draft", defaultValue: "Draft")
        }
    }
}

private struct AgentPluginApprovalSheet: View {
    let proposal: AgentPluginInstallProposal
    let onCancel: () -> Void
    let onInstall: (Set<String>) -> Void
    @State private var pinnedDestinationIDs: Set<String>

    init(
        proposal: AgentPluginInstallProposal,
        onCancel: @escaping () -> Void,
        onInstall: @escaping (Set<String>) -> Void
    ) {
        self.proposal = proposal
        self.onCancel = onCancel
        self.onInstall = onInstall
        let defaultPinned = proposal.package.destinations.first.map { Set([$0.qualifiedID]) } ?? []
        _pinnedDestinationIDs = State(initialValue: defaultPinned)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AgentPluginIcon(
                    icon: proposal.package.codexManifest.interface?.logo,
                    packageURL: proposal.package.packageURL,
                    presentation: .originalColor,
                    fallbackSeed: proposal.package.pluginID
                )
                .frame(width: 36, height: 36)
                Text(proposal.package.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(L10n.Plugins.versionLabel(proposal.package.version))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
            }
            if proposal.addedPermissions.isEmpty {
                Label(L10n.Plugins.noPermissions, systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.Plugins.addedPermissions)
                    .font(.system(size: 12, weight: .semibold))
                ForEach(proposal.addedPermissions, id: \.rawValue) { permission in
                    Label(permission.rawValue, systemImage: "exclamationmark.shield")
                        .font(.system(size: 11))
                }
            }
            if !proposal.package.destinations.isEmpty {
                Divider()
                Text(L10n.Plugins.pin).font(.system(size: 12, weight: .semibold))
                ForEach(proposal.package.destinations) { destination in
                    Toggle(
                        AgentPluginPackageLoader.localizedString(
                            key: destination.navigation.titleKey,
                            package: proposal.package
                        ),
                        isOn: Binding(
                            get: { pinnedDestinationIDs.contains(destination.qualifiedID) },
                            set: { enabled in
                                if enabled && pinnedDestinationIDs.count < AgentPluginRegistry.maximumPinnedDestinations {
                                    pinnedDestinationIDs.insert(destination.qualifiedID)
                                } else if !enabled {
                                    pinnedDestinationIDs.remove(destination.qualifiedID)
                                }
                            }
                        )
                    )
                }
            }
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(L10n.Plugins.cancel, action: onCancel)
                Button(L10n.Plugins.install) {
                    onInstall(pinnedDestinationIDs)
                }
                .buttonStyle(AgentPluginPrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 390)
    }
}

private struct AgentPluginGitInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var reference = ""
    let onSubmit: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Plugins.gitTitle).font(.headline)
            TextField(L10n.Plugins.gitRepository, text: $repository)
            TextField(L10n.Plugins.gitReference, text: $reference)
            Spacer()
            HStack {
                Spacer()
                Button(L10n.Plugins.cancel) { dismiss() }
                Button(L10n.Plugins.inspect) {
                    onSubmit(repository, reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reference)
                }
                .buttonStyle(AgentPluginPrimaryActionButtonStyle())
                .disabled(repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 210)
    }
}

private struct AgentPluginPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.7))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.35 }
        return isPressed ? 0.72 : 1
    }
}

private struct AgentPluginApprovalActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor.opacity(isEnabled ? 0.95 : 0.5))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(isEnabled ? 0.20 : 0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.05 }
        return isPressed ? 0.18 : 0.11
    }
}

private struct AgentPluginSettingRow: View {
    let pluginID: AgentPluginID
    let setting: AgentPluginSettingContribution
    @State private var value: String

    init(pluginID: AgentPluginID, setting: AgentPluginSettingContribution) {
        self.pluginID = pluginID
        self.setting = setting
        _value = State(initialValue: AgentPluginSettingsStore.value(pluginID: pluginID, setting: setting))
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(setting.titleKey))
                    .font(.system(size: 11, weight: .medium))
                if let description = setting.descriptionKey {
                    Text(localized(description))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            editor
                .frame(width: 230)
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch setting.type {
        case .boolean:
            Toggle("", isOn: Binding(
                get: { value == "true" },
                set: { save($0 ? "true" : "false") }
            ))
            .labelsHidden()
        case .enumeration:
            Picker("", selection: Binding(get: { value }, set: save)) {
                ForEach(setting.options, id: \.self) { option in
                    Text(localized(option)).tag(option)
                }
            }
            .labelsHidden()
        case .secret:
            SecureField("", text: Binding(get: { value }, set: save))
        case .string, .number:
            TextField("", text: Binding(get: { value }, set: save))
        }
    }

    private func save(_ newValue: String) {
        value = newValue
        AgentPluginSettingsStore.setValue(newValue, pluginID: pluginID, setting: setting)
    }

    private func localized(_ key: String) -> String {
        AgentPluginRegistry.shared.localizedString(key, pluginID: pluginID)
    }
}
