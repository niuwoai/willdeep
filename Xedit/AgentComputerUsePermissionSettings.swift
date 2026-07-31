//
//  AgentComputerUsePermissionSettings.swift
//  WillDeep
//
//  Settings status and one-click Accessibility permission request for the
//  separately signed WillDeep Computer Use helper.
//

import AppKit
import Combine
import SwiftUI

@MainActor
private final class AgentComputerUsePermissionSettingsModel: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool?
    @Published private(set) var screenCaptureGranted: Bool?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRequesting = false

    func refresh() async {
        do {
            let result = try await AgentComputerUseBridge.shared.invoke(action: "permissions")
            accessibilityGranted = (result["accessibility_granted"] as? Bool) == true
            screenCaptureGranted = (result["screen_capture_granted"] as? Bool) == true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPermission(accessibility: Bool, screenCapture: Bool) async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        do {
            let reservation = try await AgentComputerUseExecution.prepareMaintenanceReservation(
                toolName: "computer_use_request_permissions"
            )
            defer {
                Task {
                    await AgentComputerUseExecution.finishMaintenanceReservation(reservation)
                }
            }

            _ = try await AgentComputerUseBridge.shared.invoke(
                action: "request_permissions",
                arguments: [
                    "accessibility": .bool(accessibility),
                    "screen_capture": .bool(screenCapture),
                ]
            )
            if screenCapture {
                await AgentComputerUseBridge.shared.restart()
            }
            await pollForPermissionChange(
                accessibility: accessibility,
                screenCapture: screenCapture
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pollForPermissionChange(accessibility: Bool, screenCapture: Bool) async {
        for _ in 0..<15 {
            await refresh()
            let accessibilityReady = !accessibility || accessibilityGranted == true
            let screenCaptureReady = !screenCapture || screenCaptureGranted == true
            if accessibilityReady && screenCaptureReady { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

struct AgentComputerUsePermissionSettingsSection: View {
    @StateObject private var model = AgentComputerUsePermissionSettingsModel()

    var body: some View {
        Section(L10n.ComputerUseSettings.sectionTitle) {
            permissionRow(
                title: L10n.ComputerUseSettings.accessibilityTitle,
                detail: L10n.ComputerUseSettings.accessibilityDetail,
                granted: model.accessibilityGranted,
                request: { await model.requestPermission(accessibility: true, screenCapture: false) }
            )

            permissionRow(
                title: L10n.ComputerUseSettings.screenCaptureTitle,
                detail: L10n.ComputerUseSettings.screenCaptureDetail,
                granted: model.screenCaptureGranted,
                request: { await model.requestPermission(accessibility: false, screenCapture: true) }
            )

            if let errorMessage = model.errorMessage {
                Text(L10n.ComputerUseSettings.statusFailed(errorMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(L10n.ComputerUseSettings.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool?,
        request: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(granted == true ? Color.green : Color.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(permissionStatusText(granted))
                    .font(.caption)
                    .foregroundStyle(granted == true ? Color.green : Color.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if granted != true {
                Button(L10n.ComputerUseSettings.requestButton) {
                    Task { await request() }
                }
                .disabled(model.isRequesting || granted == nil)
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.ComputerUseSettings.refreshButtonHelp)
            .disabled(model.isRequesting)
        }
    }

    private func permissionStatusText(_ granted: Bool?) -> String {
        guard let granted else { return L10n.ComputerUseSettings.statusChecking }
        return granted
            ? L10n.ComputerUseSettings.statusGranted
            : L10n.ComputerUseSettings.statusNotGranted
    }
}
