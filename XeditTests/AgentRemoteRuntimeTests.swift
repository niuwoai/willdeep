//
//  AgentRemoteRuntimeTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentRemoteRuntimeTests {
    @Test("debug and release secrets use isolated Keychain services")
    func keychainServicesAreIsolated() {
        #expect(RemoteRuntimeSecretStore.serviceName(debugBuild: true) == "com.willdeep.agent.debug")
        #expect(RemoteRuntimeSecretStore.serviceName(debugBuild: false) == "com.willdeep.agent")
        #expect(AgentSettingsStore.serviceName(debugBuild: true) == "com.willdeep.agent.debug")
        #expect(AgentSettingsStore.serviceName(debugBuild: false) == "com.willdeep.agent")
        #expect(AgentCredentialStore.serviceName(debugBuild: true) == "com.willdeep.credentials.debug")
        #expect(AgentCredentialStore.serviceName(debugBuild: false) == "com.willdeep.credentials")
    }

    @Test("runtime store starts empty without seeding personal SSH hosts")
    func runtimeStoreStartsEmptyWithoutPersonalHosts() throws {
        let suiteName = "willdeep-runtime-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let previous = AgentRuntimeStore.setTestDefaults(defaults)
        defer {
            AgentRuntimeStore.setTestDefaults(previous)
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(AgentRuntimeStore.loadDescriptors().isEmpty)

        let runtime = RuntimeDescriptor(
            displayName: "Team Build Box",
            host: "build.example.com",
            username: "deploy",
            defaultWorkspacePath: "/srv/app"
        )
        AgentRuntimeStore.saveDescriptors([runtime])

        let loaded = AgentRuntimeStore.loadDescriptors()
        #expect(loaded.map(\.displayName) == ["Team Build Box"])
        #expect(!loaded.contains { $0.displayName == "q3" || $0.host == "q3.example.com" })
    }

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

    @Test("remote workspace sessions get a real sidebar group key")
    func remoteWorkspaceSessionSidebarGroupKey() {
        let runtimeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let session = AgentSession(
            workspaceLocation: .remote(runtimeID: runtimeID, path: "/srv/apps/xedit/")
        )

        #expect(session.workspaceRootPath == nil)
        #expect(session.workspaceSidebarGroupKey == "remote:11111111-1111-1111-1111-111111111111:/srv/apps/xedit")
        #expect(session.workspaceSidebarGroupKey != AgentSession.noWorkspaceSidebarGroupKey)
    }

    @Test("remote workspace presentation stays explicit without a runtime descriptor")
    func remoteWorkspacePresentationFallback() {
        let runtime = RuntimeDescriptor(
            displayName: "q3",
            host: "q3.example.com",
            username: "rocky",
            defaultWorkspacePath: "/srv/apps/wp"
        )

        #expect(WorkspacePresentation.remoteDisplayName(runtime: runtime, path: "/srv/apps/wp") == "q3: wp")
        #expect(WorkspacePresentation.remoteHelp(runtime: runtime, path: "/srv/apps/wp").contains("SSH runtime q3"))
        #expect(WorkspacePresentation.remoteSymbolName(for: runtime) == "terminal.fill")
        #expect(WorkspacePresentation.remoteBadge(for: runtime) == "SSH")

        #expect(WorkspacePresentation.remoteDisplayName(runtime: nil, path: "/srv/apps/wp") == "Remote: wp")
        #expect(WorkspacePresentation.remoteHelp(runtime: nil, path: "/srv/apps/wp") == "Remote workspace: /srv/apps/wp")
        #expect(WorkspacePresentation.remoteSymbolName(for: nil) == "globe")
        #expect(WorkspacePresentation.remoteBadge(for: nil) == "REMOTE")
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

    @Test("ssh backend expands tilde identity file paths before launching ssh")
    func sshCommandConstructionExpandsTildeIdentityPath() {
        let runtime = RuntimeDescriptor(
            displayName: "Build Box",
            host: "build.example.com",
            username: "dev",
            identityFilePath: "~/.ssh/id_rsa",
            defaultWorkspacePath: "/srv/app"
        )
        let backend = SSHRuntimeBackend(descriptor: runtime)
        let command = backend.sshShellCommand(remoteCommand: "true")
        let expandedPath = "\(NSHomeDirectory())/.ssh/id_rsa"
        #expect(command.contains("'-i' '\(expandedPath)'"))
        #expect(!command.contains("'~/.ssh/id_rsa'"))
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

    @Test("runtime descriptor decodes old JSON without terminal profile")
    func runtimeDescriptorDecodesOldJSONWithoutTerminalProfile() throws {
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "displayName": "legacy host",
          "transport": "ssh",
          "host": "legacy.example.com",
          "port": 22,
          "username": "deploy",
          "defaultWorkspacePath": "/srv/app",
          "platform": "linux",
          "arch": "x86_64",
          "capabilities": {
            "hasGit": true,
            "hasRipgrep": true,
            "proxyEnvironment": {}
          }
        }
        """
        let runtime = try JSONDecoder().decode(RuntimeDescriptor.self, from: Data(json.utf8))
        #expect(runtime.displayName == "legacy host")
        #expect(runtime.terminalProfile == nil)
    }

    @Test("terminal profile encodes and normalizes queue settings")
    func terminalProfileEncodingAndQueueOrder() throws {
        let profile = RuntimeTerminalProfile(
            startupDirectory: " /srv/app ",
            startupCommands: [" source .env ", "", "uptime"],
            jumpCommands: [" ssh app2 ", "tmux attach || tmux new"],
            autoRunOnConnect: true,
            commandDelayMilliseconds: 10,
            idleTimeoutSeconds: 400,
            serviceNames: [" nginx ", "", "redis"]
        ).normalized

        #expect(profile.startupDirectory == "/srv/app")
        #expect(profile.startupCommands == ["source .env", "uptime"])
        #expect(profile.jumpCommands == ["ssh app2", "tmux attach || tmux new"])
        #expect(profile.commandDelayMilliseconds == 100)
        #expect(profile.idleTimeoutSeconds == 120)
        #expect(profile.serviceNames == ["nginx", "redis"])
        #expect(profile.queuedConnectCommands == [
            "cd '/srv/app'",
            "source .env",
            "uptime",
            "ssh app2",
            "tmux attach || tmux new"
        ])

        let runtime = RuntimeDescriptor(
            displayName: "ops",
            host: "ops.example.com",
            username: "deploy",
            defaultWorkspacePath: "/srv/app",
            terminalProfile: profile
        )
        let encoded = try JSONEncoder().encode(runtime)
        let decoded = try JSONDecoder().decode(RuntimeDescriptor.self, from: encoded)
        #expect(decoded.terminalProfile == profile)
    }
}
