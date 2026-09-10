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
            let update = try await AppUpdateChecker.fetchAvailableUpdate(currentVersion: currentVersion)
            // The banner is the only affordance this update has, and clicking
            // it runs a user-initiated Sparkle check, which erases the skip
            // record. So a banner that ignores skipping does not merely annoy
            // — it undoes the skip. See AppUpdateSkipState.
            if let update, AppUpdateSkipState.skipsUpdate(candidateBundleVersion: update.bundleVersion) {
                availableAppUpdate = nil
            } else {
                availableAppUpdate = update
            }
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
