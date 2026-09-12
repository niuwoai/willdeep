import Darwin
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentExecutorAndTerminalPoolTests {
    @Test("ChatGPT bundled Codex is preferred while legacy Codex remains supported")
    func codexDiscoveryPrefersChatGPTBundle() {
        let codex = AgentToolRunner.codexCLIExecutablePath(
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { $0 == "/Applications/ChatGPT.app/Contents/Resources/codex" }
        )
        #expect(codex == "/Applications/ChatGPT.app/Contents/Resources/codex")

        let legacyCodex = AgentToolRunner.codexCLIExecutablePath(
            environment: ["PATH": "/usr/bin"],
            isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }
        )
        #expect(legacyCodex == "/Applications/Codex.app/Contents/Resources/codex")

        let catalogEntry = LocalAgentCLI.catalog.first(where: { $0.id == "codex-cli" })
        #expect(catalogEntry?.commonPaths.first
            == "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(catalogEntry?.integration == .directTool("codex_cli"))
    }

    @Test("调度台发现 Codex、Claude 与 Hermes Profile 并安全传参")
    func dispatchCLIProfilesAreDiscoveredAndForwarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WillDeepCLIProfiles-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let userAgents = root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let projectAgents = workspace
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        let hermesProfile = root
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("worker", isDirectory: true)
        for directory in [codexHome, userAgents, projectAgents, hermesProfile] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try "model = \"codex-model\"\n".write(
            to: codexHome.appendingPathComponent("fast.config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: userAgents.appendingPathComponent("reviewer.md"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: projectAgents.appendingPathComponent("implementer.md"),
            atomically: true,
            encoding: .utf8
        )
        try "model:\n  default: hermes-model\n".write(
            to: hermesProfile.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let profiles = LocalAgentCLIProfile.discover(
            workspacePath: workspace.path,
            homeDirectory: root,
            codexHomeDirectory: codexHome
        )
        #expect(profiles.map(\.id) == [
            "codex:fast",
            "claude-agent:implementer",
            "claude-agent:reviewer",
            "hermes:default",
            "hermes:worker",
        ])
        #expect(profiles.first { $0.id == "codex:fast" }?.modelID == "codex-model")
        #expect(profiles.first { $0.id == "hermes:worker" }?.modelID == "hermes-model")

        let codex = AgentToolRunner.codexCLICommandLine(
            executable: "/x/codex",
            prompt: "implement",
            permissionMode: "workspaceWrite",
            model: nil,
            workspacePath: workspace.path,
            profile: "fast"
        )
        #expect(codex.contains("--profile 'fast'"))

        let claude = AgentToolRunner.claudeCodeCommandLine(
            executable: "/x/claude",
            prompt: "review",
            permissionMode: "plan",
            model: nil,
            agent: "reviewer"
        )
        #expect(claude.contains("--agent 'reviewer'"))

        let hermes = AgentToolRunner.hermesCLICommandLine(
            executable: "/x/hermes",
            prompt: "implement",
            model: "hermes-model",
            provider: "someim",
            profile: "worker",
            planningOnly: true,
            homeDirectory: "/Users/tester"
        )
        #expect(hermes.contains("HERMES_HOME='/Users/tester/.hermes/profiles/worker'"))
        #expect(hermes.contains("--model 'hermes-model'"))
        #expect(hermes.contains("--provider 'someim'"))
        #expect(hermes.contains("--toolsets context_engine"))

        let remoteHermes = AgentToolRunner.hermesCLICommandLine(
            executable: "hermes",
            prompt: "review",
            model: nil,
            provider: nil,
            profile: "default",
            homeDirectory: nil
        )
        #expect(remoteHermes.contains("HERMES_HOME=\"$HOME/.hermes\""))
        #expect(!LocalAgentCLIProfile.profileNameIsSafe("bad profile; rm"))
    }

    @Test("delegated terminal pool uses reusable sh tabs with a hard cap")
    func delegatedTerminalPoolPolicy() {
        #expect(AgentTerminalTab.delegatedShellExecutable == "/bin/sh")
        #expect(AgentInteractiveTerminalController.maximumDelegatedShellTabs == 3)
        #expect(AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 0))
        #expect(AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 2))
        #expect(!AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 3))
        #expect(!AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 4))
    }

    @Test("terminal control keys map to exact PTY bytes")
    func terminalControlBytes() {
        #expect(AgentTerminalControl.ctrlC.bytes == [3])
        #expect(AgentTerminalControl.ctrlD.bytes == [4])
        #expect(AgentTerminalControl.ctrlRightBracket.bytes == [29])
        #expect(AgentTerminalControl.enter.bytes == [13])
        #expect(AgentTerminalControl.escape.bytes == [27])
    }

    @Test("PID terminal cleanup escalates when the process tree ignores TERM")
    func terminalProcessTreeTerminationEscalates() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentJobFixtureCommand.idleIgnoringTerm()]
        try process.run()
        let rootPID = process.processIdentifier
        defer {
            if process.isRunning {
                _ = Darwin.kill(rootPID, SIGKILL)
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        AgentProcessSupport.terminateProcessTree(rootPID: rootPID, gracePeriod: 0.1)

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!process.isRunning)
    }

    @MainActor
    @Test("terminal panel bootstrap keeps a running delegated CLI tab active")
    func terminalPanelBootstrapPreservesRunningDelegatedTab() throws {
        let controller = AgentInteractiveTerminalController()
        let settings = EditorTerminalSettings.default
        let sessionID = UUID()
        let boundTab = controller.openLocalTab(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        let delegatedTab = controller.openDelegatedShellTab(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        defer {
            delegatedTab.finishAutomationCommand()
            controller.closeTab(id: delegatedTab.id)
            controller.closeTab(id: boundTab.id)
        }

        try delegatedTab.sendAutomationCommand(":", displayCommand: "Codex CLI")
        controller.bootstrapSidePanel(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )

        #expect(controller.activeTabID == delegatedTab.id)

        delegatedTab.finishAutomationCommand()
        controller.bootstrapSidePanel(
            originAgentSessionID: sessionID,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            settings: settings,
            skin: nil
        )
        #expect(controller.activeTabID == boundTab.id)
    }

    @Test("terminal shortcut badge titles are trimmed and bounded")
    func terminalShortcutBadgeTitlesAreTrimmedAndBounded() {
        let longTitle = String(repeating: "online", count: 8)

        #expect(AgentTerminalTab.shortcutBadgeTitle(for: "  online  ") == "online")
        #expect(AgentTerminalTab.shortcutBadgeTitle(for: longTitle) == String(longTitle.prefix(24)))
        #expect(AgentTerminalTab.shortcutBadgeTitle(for: "   ") == nil)
    }

    @Test("composer uses semantic model and worker icons")
    func composerSemanticIcons() {
        #expect(ModelPickerPill.modelSymbol == "brain.head.profile")
        #expect(AgentExecutionAgent.willDeep.symbol == "hammer.fill")
    }

    @Test("delegated images are private, forwarded to both CLIs, and removable")
    func delegatedImageDoubleInsurance() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WillDeepDelegatedImageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let bytes = Data("visual-fixture".utf8)
        let image = AgentImageAttachment(
            mimeType: "image/png",
            dataBase64: bytes.base64EncodedString()
        )
        let bundle = try AgentDelegatedImageBundle.create(
            images: [image],
            temporaryDirectory: temporaryRoot,
            token: "PRIVATE"
        )
        let imagePath = try #require(bundle.fileURLs.first?.path)
        #expect(try Data(contentsOf: bundle.fileURLs[0]) == bytes)

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: bundle.directoryURL.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: imagePath)[.posixPermissions] as? NSNumber
        )
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(fileMode.intValue & 0o777 == 0o600)

        let arguments: [String: AgentJSONValue] = [
            "image_paths": .array([.string(imagePath)])
        ]
        #expect(AgentToolRunner.delegatedImagePaths(arguments) == [imagePath])

        let codex = AgentToolRunner.codexCLICommandLine(
            executable: "/x/codex",
            prompt: "inspect",
            permissionMode: "workspaceWrite",
            model: nil,
            workspacePath: "/tmp/workspace",
            imagePaths: [imagePath]
        )
        #expect(codex.contains("--image '\(imagePath)' -- 'inspect'"))

        let claude = AgentToolRunner.claudeCodeCommandLine(
            executable: "/x/claude",
            prompt: "inspect \(imagePath)",
            permissionMode: "acceptEdits",
            model: nil,
            imagePaths: [imagePath]
        )
        #expect(claude.contains("--add-dir '\(bundle.directoryURL.path)'"))
        #expect(claude.contains(imagePath))

        bundle.removeAll()
        #expect(!FileManager.default.fileExists(atPath: bundle.directoryURL.path))
    }
}
