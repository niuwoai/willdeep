import Foundation
import Testing
@testable import WillDeep

struct ChromeNativeHostInstallerTests {
    @Test func installsExecutableLauncherAndChromeManifest() throws {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent("ChromeNativeHostInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: homeURL) }

        let agentURL = homeURL
            .appendingPathComponent("WillDeep Agent's", isDirectory: true)
            .appendingPathComponent("willdeep-agent", isDirectory: false)
        try fileManager.createDirectory(
            at: agentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: agentURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentURL.path)

        let installation = try ChromeNativeHostInstaller.install(
            agentExecutableURL: agentURL,
            homeDirectoryURL: homeURL,
            fileManager: fileManager
        )

        #expect(fileManager.isExecutableFile(atPath: installation.launcherURL.path))
        let launcher = try String(contentsOf: installation.launcherURL, encoding: .utf8)
        #expect(launcher.contains("WillDeep Agent'\\''s"))
        #expect(launcher.hasSuffix(" chrome-native-host\n"))

        let manifestData = try Data(contentsOf: installation.manifestURL)
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        #expect(manifest["name"] as? String == ChromeNativeHostInstaller.hostName)
        #expect(manifest["path"] as? String == installation.launcherURL.path)
        #expect(manifest["type"] as? String == "stdio")
        #expect(
            manifest["allowed_origins"] as? [String]
                == ["chrome-extension://\(ChromeNativeHostInstaller.extensionID)/"]
        )
    }

    @Test func rejectsMissingAgentExecutable() throws {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeNativeHostInstallerMissing-\(UUID().uuidString)", isDirectory: true)

        #expect(throws: ChromeNativeHostInstaller.InstallError.agentNotExecutable) {
            try ChromeNativeHostInstaller.install(
                agentExecutableURL: homeURL.appendingPathComponent("missing-agent"),
                homeDirectoryURL: homeURL
            )
        }
    }
}
