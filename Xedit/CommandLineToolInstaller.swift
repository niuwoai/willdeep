//
//  CommandLineToolInstaller.swift
//  WillDeep
//
//  Installs the small shell entry point used to launch WillDeep from Terminal.
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
                return "Could not locate the WillDeep app bundle."
            case .installerFailed(let message):
                return message.isEmpty ? "The command line tool could not be installed." : message
            }
        }
    }

    nonisolated static var toolName: String { "willdeep" }
    nonisolated static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/willdeep")
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
            .appendingPathComponent("willdeep-cli-\(UUID().uuidString)")
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
        let preferredAppPath = "/Applications/WillDeep.app"
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

        encode_path() {
          /usr/bin/perl -CS -MEncode=encode -e '$s = encode("UTF-8", $ARGV[0]); $s =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/eg; print $s' "$1"
        }

        for target in "$@"; do
          if [[ "$target" == *"://"* ]]; then
            /usr/bin/open -a "$app_path" "$target"
            continue
          fi

          if [[ "$target" != /* ]]; then
            target="$PWD/$target"
          fi

          encoded_path="$(encode_path "$target")"
          /usr/bin/open -a "$app_path" "willdeep://open?path=$encoded_path"
        done
        """
    }

    nonisolated static func singleQuotedShellString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func runUserShellScript(_ shellScript: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptStringLiteral(shellScript))"
        ]
        let output: AgentSubprocess.Output
        do {
            output = try AgentSubprocess.runSynchronously(process, timeout: 120)
        } catch {
            throw InstallError.installerFailed(error.localizedDescription)
        }
        guard output.exitStatus == 0, !output.timedOut else {
            let message = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
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
