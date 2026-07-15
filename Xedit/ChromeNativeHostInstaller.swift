//
//  ChromeNativeHostInstaller.swift
//  WillDeep
//
//  Registers the bundled willdeep-agent as Chrome's Native Messaging host.
//  The extension carries a stable manifest key, so its ID is deterministic.
//

import Foundation
import OSLog

enum ChromeNativeHostInstaller {
    static let hostName = "com.willdeep.browser_bridge"
    static let extensionID = "cokjjphgiflfnemlgjaeiicclgkijnia"

    struct Installation: Equatable {
        let launcherURL: URL
        let manifestURL: URL
    }

    enum InstallError: LocalizedError, Equatable {
        case agentNotExecutable

        var errorDescription: String? {
            switch self {
            case .agentNotExecutable:
                return "The bundled willdeep-agent executable is unavailable."
            }
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willdeep.app",
        category: "ChromeNativeHost"
    )

    static func installBundledHost(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> Installation? {
        guard let agentURL = bundle.resourceURL?.appendingPathComponent("willdeep-agent"),
              fileManager.isExecutableFile(atPath: agentURL.path) else {
            return nil
        }
        return try install(
            agentExecutableURL: agentURL,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )
    }

    static func install(
        agentExecutableURL: URL,
        homeDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> Installation {
        guard fileManager.isExecutableFile(atPath: agentExecutableURL.path) else {
            throw InstallError.agentNotExecutable
        }

        let applicationSupportURL = homeDirectoryURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let launcherDirectoryURL = applicationSupportURL
            .appendingPathComponent("WillDeep/ChromeNativeHost", isDirectory: true)
        let launcherURL = launcherDirectoryURL
            .appendingPathComponent("willdeep-chrome-native-host", isDirectory: false)
        let manifestDirectoryURL = applicationSupportURL
            .appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true)
        let manifestURL = manifestDirectoryURL
            .appendingPathComponent("\(hostName).json", isDirectory: false)

        try fileManager.createDirectory(
            at: launcherDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: manifestDirectoryURL,
            withIntermediateDirectories: true
        )

        let launcher = """
        #!/bin/sh
        set -eu
        exec \(shellQuoted(agentExecutableURL.path)) chrome-native-host

        """
        try Data(launcher.utf8).write(to: launcherURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherURL.path
        )

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "WillDeep Browser native messaging bridge",
            "path": launcherURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        var manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        manifestData.append(0x0A)
        try manifestData.write(to: manifestURL, options: .atomic)

        return Installation(launcherURL: launcherURL, manifestURL: manifestURL)
    }

    static func installAtLaunch() {
        do {
            guard try installBundledHost() != nil else {
                logger.notice("Skipped Chrome native host registration because the bundled agent is unavailable")
                return
            }
            logger.info("Chrome native host registration is ready")
        } catch {
            logger.error("Chrome native host registration failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
