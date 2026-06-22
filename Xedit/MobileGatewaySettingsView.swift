//
//  MobileGatewaySettingsView.swift
//  WillDeep
//
//  Settings UI for LAN Mobile Gateway pairing and device control.
//

import SwiftUI

struct MobileGatewaySettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settingsNavigation = EditorSettingsNavigation.shared
    @State private var draft = MobileGatewaySettingsStore.load()
    @State private var portText = String(MobileGatewaySettingsStore.load().port)
    @FocusState private var portFieldFocused: Bool
    /// Advanced info (IP / port / host / executable path) stays hidden by
    /// default — day-to-day the user only needs the QR code. Persisted so
    /// power users who flip it on keep it on.
    @AppStorage("com.willdeep.mobileGateway.showAdvanced") private var showAdvanced = false

    private var coordinator: MobileGatewayCoordinator {
        appState.mobileGatewayCoordinator
    }

    private var gatewayLogPreview: String {
        String(coordinator.recentOutput.suffix(2_000))
    }

    var body: some View {
        Form {
            // Mobile Gateway is lazy-started when the user opens this tab.
            // After that it stays alive for this app session so a paired
            // phone keeps working after Settings is closed.
            Section(L10n.Settings.MobileGateway.controlSection) {
                LabeledContent(L10n.Settings.MobileGateway.statusLabel) {
                    Text(statusText)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent(L10n.Settings.MobileGateway.desktopPeerLabel) {
                    Text(coordinator.desktopPeerIsConnected ? L10n.Settings.MobileGateway.connected : L10n.Settings.MobileGateway.disconnected)
                        .foregroundStyle(coordinator.desktopPeerIsConnected ? .green : .secondary)
                }

                HStack {
                    Button(L10n.Settings.MobileGateway.refreshButton) {
                        Task { await coordinator.refresh() }
                    }
                    .disabled(!coordinator.isRunning)

                    Button(L10n.Settings.MobileGateway.restartButton) {
                        Task {
                            coordinator.stop()
                            await coordinator.start()
                        }
                    }
                }
            }

            // Gateway log — the child's own stdout/stderr. Shown whenever
            // there's output so the user can see "listening on …" or the
            // real failure reason instead of a silent "Starting…".
            if !coordinator.recentOutput.isEmpty {
                Section(L10n.Settings.MobileGateway.logSection) {
                    ScrollView {
                        MobileGatewayMonospacedPreview(text: gatewayLogPreview)
                    }
                    .frame(maxHeight: 140)
                }
            }

            // QR code is the star: a phone scans it to pair. Everything
            // else (IP / port / executable) is diagnostics, tucked behind
            // the advanced toggle below.
            Section(L10n.Settings.MobileGateway.pairingSection) {
                if let payload = coordinator.pairingPayload {
                    VStack(spacing: 12) {
                        SettingsQRCodeView(
                            text: payload.qrJSONString,
                            accessibilityLabel: L10n.Settings.MobileGateway.qrAccessibilityLabel,
                            unavailableText: L10n.Settings.MobileGateway.qrUnavailable,
                            pointSize: 220
                        )
                        Text(L10n.Settings.MobileGateway.scanHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        LabeledContent(L10n.Settings.MobileGateway.expiresLabel) {
                            Text(payload.expiresAt, style: .relative)
                        }
                        HStack(spacing: 8) {
                            Button(L10n.Settings.MobileGateway.copyPayloadButton) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(payload.qrJSONString, forType: .string)
                            }
                            Button {
                                Task { await coordinator.rotatePairingPayload() }
                            } label: {
                                Label(L10n.Settings.MobileGateway.refreshPairingButton, systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                } else {
                    Text(coordinator.isRunning ? L10n.Settings.MobileGateway.noPairingPayload : L10n.Settings.MobileGateway.startToPair)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(L10n.Settings.MobileGateway.advancedToggle, isOn: $showAdvanced)
            }

            if showAdvanced {
                Section(L10n.Settings.MobileGateway.listenSection) {
                    LabeledContent(L10n.Settings.MobileGateway.addressLabel) {
                        MobileGatewayCopyableValue(
                            text: coordinator.displayBaseURL?.absoluteString ?? L10n.Settings.MobileGateway.notRunning
                        )
                    }

                    LabeledContent(L10n.Settings.MobileGateway.protocolLabel) {
                        MobileGatewayCopyableValue(text: coordinator.health?.protocolVersion ?? "mobile-gateway.v1")
                    }

                    if let payload = coordinator.pairingPayload {
                        LabeledContent(L10n.Settings.MobileGateway.pairingBaseURLLabel) {
                            MobileGatewayCopyableValue(text: payload.baseURL)
                        }
                        if !payload.fallbackBaseURLs.isEmpty {
                            LabeledContent(L10n.Settings.MobileGateway.fallbackBaseURLsLabel) {
                                MobileGatewayCopyableValue(text: payload.fallbackBaseURLs.joined(separator: "\n"))
                            }
                        }
                    }

                    TextField(L10n.Settings.MobileGateway.hostPrompt, text: Binding(
                        get: { draft.host },
                        set: { draft.host = $0; saveDraft() }
                    ))
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Text(L10n.Settings.MobileGateway.portInputLabel)
                        Spacer()
                        TextField(L10n.Settings.MobileGateway.portPrompt, text: Binding(
                            get: { portText },
                            set: { updatePortText($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .multilineTextAlignment(.trailing)
                        .focused($portFieldFocused)
                        .onSubmit {
                            commitPortText()
                        }
                        .onCompatibleChange(of: portFieldFocused) { _, isFocused in
                            if !isFocused {
                                commitPortText()
                            }
                        }
                    }

                    TextField(L10n.Settings.MobileGateway.desktopNamePrompt, text: Binding(
                        get: { draft.desktopName },
                        set: { draft.desktopName = $0; saveDraft() }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Toggle(L10n.Settings.MobileGateway.allowPairingToggle, isOn: Binding(
                        get: { draft.allowPairing },
                        set: { draft.allowPairing = $0; saveDraft() }
                    ))

                    TextField(L10n.Settings.MobileGateway.executablePathPrompt, text: Binding(
                        get: { draft.executablePath },
                        set: { draft.executablePath = $0; saveDraft() }
                    ))
                    .textFieldStyle(.roundedBorder)

                    if let resolved = coordinator.resolvedExecutablePath {
                        MobileGatewayCopyableValue(
                            text: L10n.Settings.MobileGateway.resolvedExecutable(resolved),
                            font: .caption
                        )
                    }

                    Text(L10n.Settings.MobileGateway.listenDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.Settings.MobileGateway.devicesSection) {
                if coordinator.devices.isEmpty {
                    Text(L10n.Settings.MobileGateway.noDevices)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.devices) { device in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.headline)
                                Text(deviceSubtitle(device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.isRevoked {
                                Text(L10n.Settings.MobileGateway.revoked)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(role: .destructive) {
                                    Task { await coordinator.revokeDevice(device) }
                                } label: {
                                    Label(L10n.Settings.MobileGateway.revokeButton, systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncDraftFromCoordinator()
            startGatewayIfSelected()
        }
        .onCompatibleChange(of: settingsNavigation.selectedTab) { _, selectedTab in
            guard selectedTab == .mobileGateway else { return }
            syncDraftFromCoordinator()
            startGatewayIfSelected()
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .stopped:
            return L10n.Settings.MobileGateway.stopped
        case .starting:
            return L10n.Settings.MobileGateway.starting
        case .running:
            return L10n.Settings.MobileGateway.running
        case .failed(let message):
            return L10n.Settings.MobileGateway.failed(message)
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .running:
            return .green
        case .failed:
            return .red
        case .starting:
            return .orange
        case .stopped:
            return .secondary
        }
    }

    private func saveDraft(syncPortText: Bool = true) {
        let normalized = draft.normalized
        draft = normalized
        if syncPortText {
            portText = String(normalized.port)
        }
        coordinator.updateSettings(normalized)
    }

    private func updatePortText(_ value: String) {
        let digits = String(value.filter { $0.isNumber }.prefix(5))
        portText = digits
        guard let port = Int(digits), mobileGatewayPortRange.contains(port) else {
            return
        }
        draft.port = port
        saveDraft(syncPortText: false)
    }

    private func commitPortText() {
        guard let port = Int(portText) else {
            draft.port = MobileGatewaySettings.default.port
            saveDraft()
            return
        }
        draft.port = port
        saveDraft()
    }

    private func syncDraftFromCoordinator() {
        draft = coordinator.settings
        portText = String(draft.port)
    }

    private func startGatewayIfSelected() {
        guard settingsNavigation.selectedTab == .mobileGateway else { return }
        Task { await coordinator.start() }
    }

    private func deviceSubtitle(_ device: MobileGatewayDevice) -> String {
        if let lastConnectedAt = device.lastConnectedAt {
            return L10n.Settings.MobileGateway.lastConnected(lastConnectedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return L10n.Settings.MobileGateway.createdAt(device.createdAt.formatted(date: .abbreviated, time: .shortened))
    }
}

private struct MobileGatewayCopyableValue: View {
    let text: String
    var font: Font = .body

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Text(text)
                .font(font)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 320, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct MobileGatewayMonospacedPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(24)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
