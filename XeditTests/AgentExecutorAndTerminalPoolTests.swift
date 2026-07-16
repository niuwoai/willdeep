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

    @Test("delegated terminal pool uses reusable sh tabs with a hard cap")
    func delegatedTerminalPoolPolicy() {
        #expect(AgentTerminalTab.delegatedShellExecutable == "/bin/sh")
        #expect(AgentInteractiveTerminalController.maximumDelegatedShellTabs == 3)
        #expect(AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 0))
        #expect(AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 2))
        #expect(!AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 3))
        #expect(!AgentInteractiveTerminalController.canCreateDelegatedShellTab(existingCount: 4))
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

    @Test("composer uses semantic model and worker icons")
    func composerSemanticIcons() {
        #expect(ModelPickerPill.modelSymbol == "brain.head.profile")
        #expect(AgentExecutionAgent.willDeep.symbol == "person.fill")
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
