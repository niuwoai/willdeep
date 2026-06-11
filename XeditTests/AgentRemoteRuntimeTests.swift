//
//  AgentRemoteRuntimeTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentRemoteRuntimeTests {
    @Test("old session JSON migrates workspaceRootPath to local WorkspaceLocation")
    func oldSessionJSONMigratesWorkspaceRootPath() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Legacy",
          "workspaceRootPath": "/tmp/legacy-workspace",
          "createdAt": 0,
          "updatedAt": 0,
          "messages": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(AgentSession.self, from: Data(json.utf8))
        #expect(session.workspaceRootPath == "/tmp/legacy-workspace")
        #expect(session.workspaceLocation == .local(path: "/tmp/legacy-workspace"))
    }

    @Test("runtime platform and architecture parsing covers supported remote shapes")
    func platformAndArchParsing() {
        #expect(RuntimePlatform.parse("Darwin") == .macOS)
        #expect(RuntimePlatform.parse("Linux") == .linux)
        #expect(RuntimePlatform.parse("FreeBSD") == .unknown)
        #expect(RuntimeArch.parse("arm64") == .arm64)
        #expect(RuntimeArch.parse("aarch64") == .arm64)
        #expect(RuntimeArch.parse("x86_64") == .x86_64)
        #expect(RuntimeArch.parse("amd64") == .x86_64)
    }

    @Test("remote path validator keeps paths inside workspace")
    func remotePathValidation() throws {
        #expect(try RemotePathValidator.resolve("Sources/main.swift", workspaceRoot: "/srv/app") == "/srv/app/Sources/main.swift")
        #expect(try RemotePathValidator.resolve(".", workspaceRoot: "/srv/app/") == "/srv/app")
        #expect(throws: RemotePathError.self) {
            _ = try RemotePathValidator.resolve("../secret", workspaceRoot: "/srv/app")
        }
        #expect(throws: RemotePathError.self) {
            _ = try RemotePathValidator.resolve("/etc/passwd", workspaceRoot: "/srv/app")
        }
    }

    @Test("ssh backend command construction quotes target and remote command")
    func sshCommandConstructionQuotesParts() {
        let runtime = RuntimeDescriptor(
            displayName: "Build Box",
            host: "build.example.com",
            port: 2222,
            username: "dev",
            identityFilePath: "/Users/me/.ssh/build key",
            defaultWorkspacePath: "/srv/my app"
        )
        let backend = SSHRuntimeBackend(descriptor: runtime)
        let remote = backend.workspaceWrappedCommand("printf 'hello world'")
        let command = backend.sshShellCommand(remoteCommand: remote)
        #expect(command.contains("'/usr/bin/ssh'"))
        #expect(command.contains("'-p' '2222'"))
        #expect(command.contains("'-i' '/Users/me/.ssh/build key'"))
        #expect(command.contains("'dev@build.example.com'"))
        #expect(command.contains("cd '\\''/srv/my app'\\''"))
    }

    @Test("proxy credentials are redacted before persistence")
    func proxyCredentialsAreRedacted() {
        let redacted = SSHRuntimeBackend.redactProxyCredential("http://alice:secret@proxy.example.com:8080")
        #expect(redacted == "http://redacted:redacted@proxy.example.com:8080")
        #expect(SSHRuntimeBackend.redactProxyCredential("http://proxy.example.com:8080") == "http://proxy.example.com:8080")
    }

    @Test("runtime capabilities decode old probe payloads")
    func runtimeCapabilitiesDecodeOldPayloads() throws {
        let json = """
        {
          "hasGit": true,
          "hasRipgrep": false,
          "shellPath": "/bin/bash"
        }
        """
        let capabilities = try JSONDecoder().decode(RuntimeCapabilities.self, from: Data(json.utf8))
        #expect(capabilities.hasGit)
        #expect(capabilities.shellPath == "/bin/bash")
        #expect(capabilities.ghVersion == nil)
        #expect(capabilities.proxyEnvironment.isEmpty)
    }
}
