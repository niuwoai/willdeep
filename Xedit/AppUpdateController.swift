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
        logAutomaticUpdateState()
    }

    func checkForUpdates() {
        guard !Self.isRunningTests else { return }
        start()
        updaterController.checkForUpdates(nil)
    }

    /// Whether Sparkle may download and install updates on its own schedule.
    ///
    /// Backed by Sparkle's own preference, not a second one of ours: the setter
    /// persists into the host bundle's defaults, and Sparkle's docs are explicit
    /// that keeping a parallel user default is wrong. Reading it also stops the
    /// update alert's checkbox and the Settings toggle from disagreeing — they
    /// are now two views of one value.
    var automaticallyDownloadsUpdates: Bool {
        get {
            guard !Self.isRunningTests else { return false }
            start()
            return updaterController.updater.automaticallyDownloadsUpdates
        }
        set {
            guard !Self.isRunningTests else { return }
            start()
            updaterController.updater.automaticallyDownloadsUpdates = newValue
            Self.log("automatic updates set to \(newValue)")
        }
    }

    /// Whether the option can be offered at all. Sparkle returns false when
    /// automatic checks are off or `SUAllowsAutomaticUpdates` disallows it, and
    /// a toggle that silently does nothing is worse than a disabled one.
    var canEnableAutomaticDownloads: Bool {
        guard !Self.isRunningTests else { return false }
        start()
        return updaterController.updater.allowsAutomaticUpdates
    }

    /// Logged once at startup so the next "it never auto-updates" report can be
    /// answered from the log instead of from a guess. Sparkle's own verbose
    /// logging stays off; these three values are the ones that decide the
    /// behaviour.
    private func logAutomaticUpdateState() {
        let updater = updaterController.updater
        Self.log(
            "automatic update state: checks=\(updater.automaticallyChecksForUpdates) "
                + "downloads=\(updater.automaticallyDownloadsUpdates) "
                + "allowed=\(updater.allowsAutomaticUpdates) "
                + "interval=\(Int(updater.updateCheckInterval))s "
                + "lastCheck=\(updater.lastUpdateCheckDate?.description ?? "never")"
        )
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
