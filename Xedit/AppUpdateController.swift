//
//  AppUpdateController.swift
//  WillDeep
//
//  Sparkle owns the privileged install handoff: it downloads and verifies the
//  signed DMG, waits for WillDeep to terminate, atomically replaces the app,
//  rolls back on failure, and relaunches the installed version.
//

import AppKit
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
    private var isManualCheckPending = false

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
        isManualCheckPending = true
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
        let diagnostic = AppUpdateDiagnostic(error: error)
        Self.log("Sparkle update check aborted: \(diagnostic.technicalText)")

        Task { @MainActor in
            let logURL = AppUpdateDiagnosticLog.append(diagnostic)
            let shouldPresent = isManualCheckPending && diagnostic.shouldPresentToUser
            isManualCheckPending = false

            if shouldPresent {
                presentDiagnostic(diagnostic, logURL: logURL)
            }
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let diagnostic = AppUpdateDiagnostic(error: error)
        Self.log("Sparkle did not find update: \(diagnostic.technicalText)")

        Task { @MainActor in
            isManualCheckPending = false
        }
    }

    private func presentDiagnostic(_ diagnostic: AppUpdateDiagnostic, logURL: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.AppUpdate.diagnosticTitle
        let summary = if diagnostic.isInstallerLaunchFailure {
            "\(diagnostic.summary)\n\(L10n.AppUpdate.diagnosticInstallerLaunchHint)"
        } else {
            diagnostic.summary
        }
        alert.informativeText = if logURL == nil {
            L10n.AppUpdate.diagnosticMessageWithoutLog(diagnostic.reference, summary)
        } else {
            L10n.AppUpdate.diagnosticMessage(diagnostic.reference, summary)
        }

        alert.addButton(withTitle: L10n.AppUpdate.diagnosticClose)
        alert.addButton(withTitle: L10n.AppUpdate.diagnosticCopy)
        if logURL != nil {
            alert.addButton(withTitle: L10n.AppUpdate.diagnosticShowLog)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(diagnostic.technicalText, forType: .string)
        } else if response == .alertThirdButtonReturn, let logURL {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    private nonisolated static func log(_ message: String) {
        NSLog("[WillDeep] %@", message)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

nonisolated struct AppUpdateDiagnostic: Sendable, Equatable {
    private static let maximumErrorDepth = 4
    private static let installerLaunchFailureErrorCode = 4005
    private static let installationCanceledErrorCode = 4007
    private static let userCanceledDownloadErrorCode = 4008

    struct ErrorEntry: Sendable, Equatable {
        let domain: String
        let code: Int
        let description: String
        let failureReason: String?
        let recoverySuggestion: String?
    }

    let timestamp: Date
    let appVersion: String
    let buildVersion: String
    let operatingSystemVersion: String
    let bundlePath: String
    let errors: [ErrorEntry]

    init(
        error: Error,
        timestamp: Date = Date(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        bundlePath: String = Bundle.main.bundlePath
    ) {
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.bundlePath = bundlePath

        var entries: [ErrorEntry] = []
        var errorCursor: NSError? = error as NSError
        while let currentError = errorCursor, entries.count < Self.maximumErrorDepth {
            entries.append(
                ErrorEntry(
                    domain: Self.singleLine(currentError.domain),
                    code: currentError.code,
                    description: Self.singleLine(currentError.localizedDescription),
                    failureReason: currentError.localizedFailureReason.map(Self.singleLine),
                    recoverySuggestion: currentError.localizedRecoverySuggestion.map(Self.singleLine)
                )
            )
            errorCursor = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        errors = entries
    }

    var reference: String {
        guard let firstError = errors.first else { return "unknown/0" }
        return "\(firstError.domain)/\(firstError.code)"
    }

    var summary: String {
        errors.first?.description ?? "Unknown update error"
    }

    var isInstallerLaunchFailure: Bool {
        guard let firstError = errors.first else { return false }
        return firstError.domain == "SUSparkleErrorDomain"
            && firstError.code == Self.installerLaunchFailureErrorCode
    }

    var shouldPresentToUser: Bool {
        guard let code = errors.first?.code else { return true }
        return code != Self.installationCanceledErrorCode && code != Self.userCanceledDownloadErrorCode
    }

    var technicalText: String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "timestamp=\(formatter.string(from: timestamp))",
            "app_version=\(appVersion)",
            "build=\(buildVersion)",
            "macos=\(operatingSystemVersion)",
            "bundle_path=\(bundlePath)",
        ]
        for (index, error) in errors.enumerated() {
            lines.append("error[\(index)]=\(error.domain)/\(error.code): \(error.description)")
            if let failureReason = error.failureReason, failureReason != error.description {
                lines.append("failure_reason[\(index)]=\(failureReason)")
            }
            if let recoverySuggestion = error.recoverySuggestion {
                lines.append("recovery_suggestion[\(index)]=\(recoverySuggestion)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

nonisolated enum AppUpdateDiagnosticLog {
    private static let maximumLogSize = 256 * 1_024

    static func append(_ diagnostic: AppUpdateDiagnostic, to explicitURL: URL? = nil) -> URL? {
        guard let logURL = explicitURL ?? defaultURL else { return nil }
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let separator = fileManager.fileExists(atPath: logURL.path) ? "\n\n" : ""
            guard let entry = "\(separator)\(diagnostic.technicalText)\n".data(using: .utf8) else {
                return nil
            }
            let existingSize = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
            if existingSize + entry.count > maximumLogSize {
                try entry.write(to: logURL, options: .atomic)
            } else if fileManager.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: entry)
                try handle.close()
            } else {
                try entry.write(to: logURL, options: .atomic)
            }
            return logURL
        } catch {
            let nsError = error as NSError
            NSLog(
                "[WillDeep] Failed to write update diagnostic log: %@/%ld %@",
                nsError.domain,
                nsError.code,
                nsError.localizedDescription
            )
            return nil
        }
    }

    private static var defaultURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("update.log", isDirectory: false)
    }
}
