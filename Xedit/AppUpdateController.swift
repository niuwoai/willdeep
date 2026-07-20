//
//  AppUpdateController.swift
//  WillDeep
//
//  Sparkle owns the privileged install handoff: it downloads and verifies the
//  signed DMG, waits for WillDeep to terminate, atomically replaces the app,
//  rolls back on failure, and relaunches the installed version.
//

import Foundation
import Sparkle

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdateController()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var hasStarted = false

    private override init() {
        super.init()
    }

    func start() {
        guard !hasStarted, !Self.isRunningTests else { return }
        updaterController.startUpdater()
        hasStarted = true
    }

    func checkForUpdates() {
        guard !Self.isRunningTests else { return }
        start()
        updaterController.checkForUpdates(nil)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            let urlString = AppUpdateChecker.managedAppcastURL()?.absoluteString
            if let urlString {
                Self.log("Sparkle appcast URL: \(urlString)")
            } else {
                Self.log("Sparkle appcast URL is unavailable.")
            }
            return urlString
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.log("Sparkle update check aborted: \(Self.describe(error))")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Self.log("Sparkle did not find update: \(Self.describe(error))")
    }

    private nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var details = "\(nsError.domain) code=\(nsError.code): \(nsError.localizedDescription)"
        if !nsError.userInfo.isEmpty {
            details += " userInfo=\(nsError.userInfo)"
        }
        return details
    }

    private nonisolated static func log(_ message: String) {
        NSLog("[WillDeep] %@", message)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
