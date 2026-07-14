//
//  AppStateAppUpdates.swift
//  WillDeep
//
//  Background polling and download action for some.im managed app updates.
//

import AppKit
import Foundation

@MainActor
extension AppState {
    private static let appUpdateInitialDelay: UInt64 = 60_000_000_000
    private static let appUpdatePollInterval: UInt64 = 17 * 60 * 1_000_000_000

    func startAppUpdateChecks() {
        appUpdateCheckTask?.cancel()
        appUpdateCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.appUpdateInitialDelay)
            while !Task.isCancelled {
                await self?.refreshAvailableAppUpdate()
                try? await Task.sleep(nanoseconds: Self.appUpdatePollInterval)
            }
        }
    }

    func refreshAvailableAppUpdate() async {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        do {
            availableAppUpdate = try await AppUpdateChecker.fetchAvailableUpdate(currentVersion: currentVersion)
        } catch {
            #if DEBUG
            NSLog("[WillDeep] managed update check failed: %@", error.localizedDescription)
            #endif
        }
    }

    func downloadAvailableAppUpdate() {
        guard !isDownloadingAppUpdate, let update = availableAppUpdate else { return }
        isDownloadingAppUpdate = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await AppUpdateChecker.download(meta: update)
                self.isDownloadingAppUpdate = false
                AppUpdateChecker.presentDownloadedUpdate(fileURL: fileURL, meta: update)
            } catch {
                self.isDownloadingAppUpdate = false
                self.presentAppUpdateDownloadError(error)
            }
        }
    }

    private func presentAppUpdateDownloadError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.AppUpdate.downloadFailedTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Alert.binaryFileButtonOk)
        alert.runModal()
    }
}
