//
//  CommandLineToolInstaller.swift
//  VeilWriter
//
//  Installs the small shell entry point used to launch VeilWriter from Terminal.
//

import Foundation

enum CommandLineToolInstallState: Equatable {
    case installed
    case needsUpdate
    case notInstalled
}

enum CommandLineToolInstaller {
    enum InstallError: LocalizedError {
        case missingAppBundle
        case installerFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAppBundle:
                return "Could not locate the VeilWriter app bundle."
            case .installerFailed(let message):
                return message.isEmpty ? "The command line tool could not be installed." : message
            }
        }
    }

    nonisolated static var toolName: String { "veilwriter" }
    nonisolated static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/veilwriter")
    }

    nonisolated static func install(appBundleURL: URL = Bundle.main.bundleURL) throws {
        guard appBundleURL.pathExtension == "app" else {
            throw InstallError.missingAppBundle
        }

        do {
            try writeScriptDirectly(appBundleURL: appBundleURL)
            return
        } catch {
            try writeScriptThroughUserShell(appBundleURL: appBundleURL)
        }
    }

    nonisolated private static func writeScriptDirectly(appBundleURL: URL) throws {
        let directoryURL = installURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try scriptContent(appBundleURL: appBundleURL)
            .write(to: installURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installURL.path
        )
    }

    nonisolated private static func writeScriptThroughUserShell(appBundleURL: URL) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter-cli-\(UUID().uuidString)")
        try scriptContent(appBundleURL: appBundleURL)
            .write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let installCommand = """
        /bin/mkdir -p \(singleQuotedShellString(installURL.deletingLastPathComponent().path))
        /bin/cp \(singleQuotedShellString(tempURL.path)) \(singleQuotedShellString(installURL.path))
        /bin/chmod 755 \(singleQuotedShellString(installURL.path))
        """

        try runUserShellScript(installCommand)
    }

    nonisolated static func installState(appBundleURL: URL = Bundle.main.bundleURL) -> CommandLineToolInstallState {
        guard FileManager.default.fileExists(atPath: installURL.path) else {
            return .notInstalled
        }

        guard let installedContent = try? String(contentsOf: installURL, encoding: .utf8),
              installedContent == scriptContent(appBundleURL: appBundleURL),
              FileManager.default.isExecutableFile(atPath: installURL.path) else {
            return .needsUpdate
        }

        return .installed
    }

    nonisolated static func scriptContent(appBundleURL: URL = Bundle.main.bundleURL) -> String {
        let preferredAppPath = "/Applications/VeilWriter.app"
        let fallbackAppPath = appBundleURL.path

        return """
        #!/bin/zsh
        set -e

        app_path=\(singleQuotedShellString(preferredAppPath))
        if [[ ! -d "$app_path" ]]; then
          app_path=\(singleQuotedShellString(fallbackAppPath))
        fi

        if [[ $# -eq 0 ]]; then
          exec /usr/bin/open -a "$app_path"
        fi

        exec /usr/bin/open -a "$app_path" -- "$@"
        """
    }

    nonisolated static func singleQuotedShellString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func runUserShellScript(_ shellScript: String) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptStringLiteral(shellScript))"
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw InstallError.installerFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallError.installerFailed(message)
        }
    }

    nonisolated private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
