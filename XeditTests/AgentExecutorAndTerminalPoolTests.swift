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
}
