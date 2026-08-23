//
//  AgentPluginSidebarViews.swift
//  WillDeep
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentPluginPrimaryNavigationSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var registry = AgentPluginRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Text(L10n.Plugins.sidebarHeader)
                .font(AgentDesign.sidebarSectionFont)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            ForEach(registry.snapshot.pinnedDestinations) { destination in
                AgentPluginNavigationRow(
                    destination: destination,
                    title: registry.localizedTitle(for: destination),
                    isSelected: appState.agentPrimaryDestination == .plugin(destination.qualifiedID)
                ) {
                    appState.agentPrimaryDestination = .plugin(destination.qualifiedID)
                    appState.agentSidePanelKind = nil
                    appState.agentSidePanelRequest = nil
                }
                .onDrag {
                    NSItemProvider(object: destination.qualifiedID as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: AgentPluginNavigationDropDelegate(
                        targetID: destination.qualifiedID,
                        registry: registry
                    )
                )
                .contextMenu {
                    if !destination.defaultPinned {
                        Button(L10n.Plugins.unpin) {
                            registry.unpin(destinationID: destination.qualifiedID)
                        }
                    }
                    Button(L10n.Plugins.settings) {
                        appState.agentPrimaryDestination = .pluginCenter
                    }
                }
            }

            if registry.snapshot.pinnedDestinations.isEmpty {
                SidebarActionRow(
                    icon: "plus.square.dashed",
                    title: L10n.Plugins.addPlugin,
                    shortcut: nil
                ) {
                    appState.agentPrimaryDestination = .pluginCenter
                    appState.agentSidePanelKind = nil
                    appState.agentSidePanelRequest = nil
                }
            } else {
                SidebarActionRow(
                    icon: "ellipsis.circle",
                    title: L10n.Plugins.morePlugins,
                    shortcut: nil,
                    isSelected: appState.agentPrimaryDestination == .pluginCenter
                ) {
                    appState.agentPrimaryDestination = .pluginCenter
                    appState.agentSidePanelKind = nil
                    appState.agentSidePanelRequest = nil
                }
            }
        }
        .tint(.primary)
    }
}

private struct AgentPluginNavigationRow: View {
    @EnvironmentObject private var appState: AppState
    let destination: AgentPluginDestinationDescriptor
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentPluginIcon(
                    icon: destination.navigation.icon,
                    packageURL: destination.packageURL
                )
                .frame(width: 14, height: 14)
                .foregroundStyle(iconColor)
                Text(title)
                    .font(AgentDesign.scaledSidebarRowFont(baseFontSize: appState.agentChatBaseFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AgentDesign.sidebarSelectionCornerRadius)
                    .fill(rowBackground)
                    .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }

    private var rowBackground: Color {
        let palette = appState.editorSettings.interfaceSkin.palette
        if isSelected { return palette.selectionFill }
        if isHovered { return palette.hoverFill }
        return .clear
    }

    private var iconColor: Color {
        if isSelected { return .primary }
        return isHovered ? .primary.opacity(0.72) : .secondary
    }
}

struct AgentPluginIcon: View {
    let icon: String?
    let packageURL: URL

    var body: some View {
        if let systemName {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var systemName: String? {
        guard let icon, icon.hasPrefix("sf:") else { return nil }
        let value = String(icon.dropFirst(3))
        return value.isEmpty ? nil : value
    }

    private var image: NSImage? {
        guard let icon, !icon.hasPrefix("sf:"),
              let url = try? AgentPluginPackageLoader.safeResourceURL(
                relativePath: icon,
                packageURL: packageURL
              ),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

private struct AgentPluginNavigationDropDelegate: DropDelegate {
    let targetID: String
    let registry: AgentPluginRegistry

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let sourceID = object as? String else { return }
            Task { @MainActor in
                registry.movePinned(destinationID: sourceID, before: targetID)
            }
        }
        return true
    }
}

struct AgentPluginDeclarativeSidebarHost: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var registry = AgentPluginRegistry.shared
    @ObservedObject private var sessionState = AgentPluginDestinationSessionState.shared
    let destination: AgentPluginDestinationDescriptor

    @State private var document: AgentPluginSidebarDocument?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && document == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Plugins.loadingSidebar)
                        .font(AgentDesign.secondaryFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: AgentDesign.sidebarRowHeight)
            } else if let document {
                ForEach(document.components) { component in
                    componentView(component)
                }
                if let errorMessage {
                    errorRow(errorMessage)
                }
            } else if let errorMessage {
                errorRow(errorMessage)
            } else {
                Text(L10n.Plugins.emptySidebar)
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .tint(.primary)
        .task(id: taskIdentity) {
            await loadDocument()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentMCPResourcesDidChange)) { notification in
            guard let resource = destination.companionSidebar.resource,
                  notification.userInfo?[AgentMCPResourceNotificationKey.serverID] as? String
                    == "plugin:\(destination.pluginID):\(resource.server)" else {
                return
            }
            let changedURI = notification.userInfo?[AgentMCPResourceNotificationKey.uri] as? String
            if changedURI == nil || changedURI == resource.uri {
                sessionState.requestRefresh(destinationID: destination.qualifiedID)
            }
        }
    }

    private var taskIdentity: String {
        let generation = sessionState.refreshGenerations[destination.qualifiedID, default: 0]
        return "\(destination.qualifiedID):\(generation)"
    }

    private func componentView(_ component: AgentPluginSidebarComponent) -> AnyView {
        switch component.kind {
        case .section, .list:
            return AnyView(VStack(alignment: .leading, spacing: 2) {
                if let titleKey = component.titleKey {
                    Text(localized(titleKey))
                        .font(AgentDesign.sidebarSectionFont)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }
                ForEach(component.children) { child in
                    componentView(child)
                }
            }
            .padding(.bottom, 8))
        case .disclosure:
            return AnyView(VStack(alignment: .leading, spacing: 2) {
                Button {
                    if expandedIDs.contains(component.id) {
                        expandedIDs.remove(component.id)
                    } else {
                        expandedIDs.insert(component.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expandedIDs.contains(component.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(localized(component.titleKey))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: AgentDesign.sidebarRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expandedIDs.contains(component.id) {
                    ForEach(component.children) { child in
                        componentView(child)
                    }
                }
            })
        case .row, .button:
            return AnyView(pluginRow(component))
        case .label:
            return AnyView(Text(localized(component.titleKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5))
        case .icon:
            return AnyView(Group {
                if let systemImage = component.systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                }
            })
        case .badge:
            return AnyView(Text(component.value ?? localized(component.titleKey))
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .padding(.horizontal, 14))
        case .status:
            return AnyView(HStack(spacing: 7) {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                Text(component.value ?? localized(component.titleKey))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5))
        case .progress:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                if component.titleKey != nil {
                    Text(localized(component.titleKey)).font(.system(size: 11))
                }
                ProgressView(value: max(0, min(component.progress ?? 0, 1)))
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6))
        case .separator:
            return AnyView(Divider().padding(.horizontal, 14).padding(.vertical, 6))
        case .emptyState:
            return AnyView(stateText(component, fallback: L10n.Plugins.emptySidebar))
        case .loadingState:
            return AnyView(HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localized(component.titleKey, fallback: L10n.Plugins.loadingSidebar))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8))
        case .errorState:
            return AnyView(stateText(component, fallback: L10n.Plugins.errorSidebar))
        }
    }

    private func pluginRow(_ component: AgentPluginSidebarComponent) -> some View {
        let selected = sessionState.selectedItemID(for: destination.qualifiedID) == component.id
        let palette = appState.editorSettings.interfaceSkin.palette
        return Button {
            if let command = component.command {
                run(command: command, arguments: component.arguments)
            } else {
                sessionState.select(itemID: component.id, destinationID: destination.qualifiedID)
            }
        } label: {
            HStack(spacing: 9) {
                if let systemImage = component.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(width: 17)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(component.titleKey))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let subtitleKey = component.subtitleKey {
                        Text(localized(subtitleKey))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let value = component.value {
                    Text(value)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: component.subtitleKey == nil ? AgentDesign.sidebarRowHeight : 44)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AgentDesign.sidebarSelectionCornerRadius)
                    .fill(selected ? palette.selectionFill : .clear)
                    .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(registry.sidebarRowContextCommands(
                for: destination,
                explicitCommandIDs: component.contextCommands
            )) { command in
                Button(registry.localizedString(command.titleKey, pluginID: destination.pluginID)) {
                    run(command: command.id, arguments: component.arguments)
                }
            }
        }
    }

    private func stateText(_ component: AgentPluginSidebarComponent, fallback: String) -> some View {
        Text(localized(component.titleKey, fallback: fallback))
            .font(AgentDesign.secondaryFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Plugins.errorSidebar)
                .font(.system(size: 11, weight: .medium))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Button(L10n.Plugins.retry) {
                    sessionState.requestRefresh(destinationID: destination.qualifiedID)
                }
                Button(L10n.Plugins.openMCPSettings) {
                    EditorSettingsNavigation.shared.open(.mcp, appState: appState)
                }
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func localized(_ key: String?, fallback: String = "") -> String {
        guard let key, !key.isEmpty else { return fallback }
        return registry.localizedString(key, pluginID: destination.pluginID)
    }

    private func run(command: String, arguments: [String: String]) {
        Task {
            _ = try? await AgentPluginCommandExecutor.execute(
                pluginID: destination.pluginID,
                commandID: command,
                arguments: arguments,
                destinationID: destination.qualifiedID,
                appState: appState
            )
        }
    }

    private func loadDocument() async {
        isLoading = true
        errorMessage = nil
        var fallbackDocument: AgentPluginSidebarDocument?
        if let schema = destination.companionSidebar.schema {
            do {
                let url = try AgentPluginPackageLoader.safeResourceURL(
                    relativePath: schema,
                    packageURL: destination.packageURL
                )
                let data = try Data(contentsOf: url)
                guard data.count <= AgentPluginPackageLoader.maximumManifestBytes else {
                    throw AgentPluginPackageError.oversizedManifest(schema)
                }
                let decoded = try JSONDecoder().decode(AgentPluginSidebarDocument.self, from: data)
                try validateRuntimeDocument(decoded)
                fallbackDocument = decoded
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if let resource = destination.companionSidebar.resource {
            do {
                let payload = try await AgentMCPBridge.readPluginResource(
                    pluginID: destination.pluginID,
                    serverName: resource.server,
                    uri: resource.uri
                )
                Task {
                    try? await AgentMCPBridge.subscribePluginResource(
                        pluginID: destination.pluginID,
                        serverName: resource.server,
                        uri: resource.uri
                    )
                }
                let text = try AgentPluginMCPResourcePayload.text(from: payload)
                guard let data = text.data(using: .utf8) else {
                    throw AgentPluginPackageError.unreadableManifest(resource.uri)
                }
                guard data.count <= AgentPluginPackageLoader.maximumManifestBytes else {
                    throw AgentPluginPackageError.oversizedManifest(resource.uri)
                }
                let decoded = try JSONDecoder().decode(AgentPluginSidebarDocument.self, from: data)
                try validateRuntimeDocument(decoded)
                document = decoded
                errorMessage = nil
            } catch {
                document = fallbackDocument
                errorMessage = error.localizedDescription
            }
        } else {
            document = fallbackDocument
        }
        isLoading = false
    }

    private func validateRuntimeDocument(_ document: AgentPluginSidebarDocument) throws {
        let commandIDs = Set(registry.commands(for: destination.pluginID).map(\.id))
        let localizationKeys = try AgentPluginPackageLoader.validateDeclarativeDocument(
            document,
            commandIDs: commandIDs
        )
        try AgentPluginPackageLoader.validateEnglishLocalization(
            keys: localizationKeys,
            packageURL: destination.packageURL
        )
    }
}

nonisolated enum AgentPluginMCPResourcePayload {
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    struct Document: Equatable, Sendable {
        let uri: String?
        let mimeType: String?
        let text: String
    }

    static func text(from payload: String) throws -> String {
        try document(from: payload).text
    }

    static func document(from payload: String) throws -> Document {
        guard let data = payload.data(using: .utf8),
              data.count <= maximumPayloadBytes else {
            throw AgentPluginPackageError.oversizedManifest("MCP resource")
        }
        guard
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let contents = dictionary["contents"] as? [[String: Any]] else {
            if !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Document(uri: nil, mimeType: nil, text: payload)
            }
            throw AgentPluginPackageError.unreadableManifest("MCP resource")
        }
        for content in contents {
            let uri = content["uri"] as? String
            let mimeType = content["mimeType"] as? String
            if let text = content["text"] as? String {
                return Document(uri: uri, mimeType: mimeType, text: text)
            }
            if let blob = content["blob"] as? String,
               let decoded = Data(base64Encoded: blob),
               let text = String(data: decoded, encoding: .utf8) {
                return Document(uri: uri, mimeType: mimeType, text: text)
            }
        }
        throw AgentPluginPackageError.unreadableManifest("MCP resource contents")
    }

    static func mcpAppDocument(from payload: String, expectedURI: String) throws -> Document {
        let resource = try document(from: payload)
        guard resource.uri == expectedURI,
              resource.mimeType?.lowercased() == "text/html;profile=mcp-app",
              resource.text.utf8.count <= maximumPayloadBytes,
              !resource.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentPluginPackageError.invalidContribution(
                "MCP App resources must return text/html;profile=mcp-app for \(expectedURI)"
            )
        }
        return resource
    }
}
