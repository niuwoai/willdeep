//
//  AppUpdateDiagnosticTests.swift
//  WillDeepTests
//
//  Keeps update diagnostics useful without serializing NSError.userInfo,
//  which may contain unrelated application state or credentials.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AppUpdateDiagnosticTests {
    @Test("diagnostic keeps the error chain and excludes arbitrary user info")
    func testDiagnosticRedactsArbitraryUserInfo() {
        let sensitiveMarker = "must-not-appear-in-update-log"
        let underlyingError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "Installer is not writable"]
        )
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 4005,
            userInfo: [
                NSLocalizedDescriptionKey: "Installer launch failed",
                NSLocalizedFailureReasonErrorKey: "Authorization was denied",
                NSUnderlyingErrorKey: underlyingError,
                "access_token": sensitiveMarker,
            ]
        )

        let diagnostic = AppUpdateDiagnostic(
            error: error,
            timestamp: Date(timeIntervalSince1970: 0),
            appVersion: "1.272.0-rc6",
            buildVersion: "406",
            operatingSystemVersion: "macOS test",
            bundlePath: "/Applications/WillDeep.app"
        )

        #expect(diagnostic.reference == "SUSparkleErrorDomain/4005")
        #expect(diagnostic.technicalText.contains("SUSparkleErrorDomain/4005"))
        #expect(diagnostic.technicalText.contains("NSCocoaErrorDomain/513"))
        #expect(diagnostic.technicalText.contains("Authorization was denied"))
        #expect(!diagnostic.technicalText.contains(sensitiveMarker))
        #expect(!diagnostic.technicalText.contains("access_token"))
        #expect(diagnostic.isInstallerLaunchFailure)
    }

    @Test("user cancellation does not open a second diagnostic alert")
    func testCancellationIsSilent() {
        let diagnostic = AppUpdateDiagnostic(
            error: NSError(domain: "SUSparkleErrorDomain", code: 4007),
            appVersion: "1.272.0-rc6",
            buildVersion: "406",
            operatingSystemVersion: "macOS test",
            bundlePath: "/Applications/WillDeep.app"
        )

        #expect(!diagnostic.shouldPresentToUser)
    }

    @Test("diagnostic log is appended at the requested location")
    func testDiagnosticLogAppend() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let logURL = temporaryDirectory.appendingPathComponent("update.log")
        let diagnostic = AppUpdateDiagnostic(
            error: NSError(
                domain: "SUSparkleErrorDomain",
                code: 4005,
                userInfo: [NSLocalizedDescriptionKey: "Installer launch failed"]
            ),
            timestamp: Date(timeIntervalSince1970: 0),
            appVersion: "1.272.0-rc6",
            buildVersion: "406",
            operatingSystemVersion: "macOS test",
            bundlePath: "/Applications/WillDeep.app"
        )

        let writtenURL = AppUpdateDiagnosticLog.append(diagnostic, to: logURL)
        #expect(writtenURL == logURL)
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("app_version=1.272.0-rc6"))
        #expect(text.contains("SUSparkleErrorDomain/4005"))
    }

    @Test("diagnostic alert copy is localized")
    func testDiagnosticAlertCopyExists() {
        #expect(!L10n.AppUpdate.diagnosticTitle.isEmpty)
        #expect(!L10n.AppUpdate.diagnosticCopy.isEmpty)
        #expect(!L10n.AppUpdate.diagnosticInstallerLaunchHint.isEmpty)
        #expect(!L10n.AppUpdate.diagnosticShowLog.isEmpty)
        #expect(!L10n.AppUpdate.diagnosticClose.isEmpty)
        #expect(!L10n.AppUpdate.diagnosticMessage("domain/1", "summary").isEmpty)
    }
}
