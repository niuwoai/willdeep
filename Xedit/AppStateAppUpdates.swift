//
//  AppStateAppUpdates.swift
//  WillDeep
//
//  Background polling and Sparkle install action for some.im managed app updates.
//

import Foundation

@MainActor
extension AppState {
    private static let appUpdateInitialDelay: UInt64 = 60_000_000_000
    private static let appUpdatePollInterval: UInt64 = 17 * 60 * 1_000_000_000

    func startAppUpdateChecks() {
        AppUpdateController.shared.start()
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
        guard availableAppUpdate != nil else { return }
        AppUpdateController.shared.checkForUpdates()
    }
}
