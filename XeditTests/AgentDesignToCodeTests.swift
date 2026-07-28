//
//  AgentDesignToCodeTests.swift
//  WillDeepTests
//

import CoreGraphics
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentDesignToCodeTests {
    @Test
    func attachedVisualSkillProducesHostRunContractWithSourcePath() throws {
        let skill = try #require(AgentSkillDirectory.bundledSkill(identifier: "design-to-code"))
        let block = try #require(AgentDesignToCode.promptBlock(
            skills: [skill],
            imagePaths: ["/tmp/reference-ui.png"]
        ))

        #expect(block.contains("/tmp/reference-ui.png"))
        #expect(block.contains("design_to_code_acceptance"))
        #expect(block.contains("Computer Use"))
        #expect(block.contains("embedded_browser_status"))
        #expect(block.contains("file://"))
        #expect(block.contains("A final answer is allowed only after"))
    }

    @Test
    func completionGateRequiresImplementationCaptureAndPassingAcceptance() {
        let messageID = UUID()
        let edit = call(messageID: messageID, name: "edit_file")
        let capture = call(messageID: messageID, name: "embedded_browser_capture_screenshot")
        let needsIteration = call(
            messageID: messageID,
            name: "design_to_code_acceptance",
            payload: "Acceptance status: NEEDS_ITERATION"
        )
        let pass = call(
            messageID: messageID,
            name: "design_to_code_acceptance",
            payload: "Acceptance status: PASS"
        )
        let empty: [AgentToolCall] = []

        #expect(AgentDesignToCode.completionGateNotice(toolCalls: empty[...])?.contains("production file edit") == true)
        #expect(AgentDesignToCode.completionGateNotice(toolCalls: [edit][...])?.contains("screenshot") == true)
        #expect(AgentDesignToCode.completionGateNotice(toolCalls: [edit, capture][...])?.contains("compared") == true)
        #expect(AgentDesignToCode.completionGateNotice(toolCalls: [edit, capture, needsIteration][...])?.contains("did not pass") == true)
        #expect(AgentDesignToCode.completionGateNotice(toolCalls: [edit, capture, pass][...]) == nil)
    }

    @Test
    func acceptanceWritesReportAndPassesIdenticalRenderedImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-DesignToCodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = ImageWorkflowSupport.render(
            width: 120,
            height: 80,
            background: .white
        ) { context in
            context.setFillColor(red: 0.12, green: 0.42, blue: 0.78, alpha: 1)
            context.fill(CGRect(x: 18, y: 16, width: 84, height: 48))
        }
        let sourceURL = root.appendingPathComponent("source.png")
        let renderedURL = root.appendingPathComponent("rendered.png")
        try ImageWorkflowSupport.save(image, to: sourceURL, format: "png")
        try ImageWorkflowSupport.save(image, to: renderedURL, format: "png")

        let result = try AgentDesignToCodeTools.acceptance(
            arguments: [
                "source_path": .string(sourceURL.path),
                "rendered_path": .string(renderedURL.path),
                "surface": .string("embedded_browser"),
                "viewport": .string("120x80"),
            ],
            context: AgentToolContext(rootDirectory: root, sandboxMode: .workspaceWrite)
        )

        #expect(result.payload.contains("Acceptance status: PASS"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("design-qa.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".willdeep/design-to-code/visual-diff.png").path))
        #expect(result.images.count == 1)
    }

    @Test
    func acceptanceToolIsRegisteredAsWriteTier() throws {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: "design_to_code_acceptance"))
        #expect(descriptor.risk == .write)
        #expect(descriptor.parameters.contains { $0.name == "source_path" && $0.required })
        #expect(descriptor.parameters.contains { $0.name == "rendered_path" && $0.required })
        #expect(descriptor.parameters.contains { $0.name == "surface" && $0.required })
    }

    @Test
    func ocrCoverageIgnoresResponsiveLineWrappingWithoutAcceptingUnrelatedCopy() {
        let source = [
            "Agent 想执行以下命令",
            "grep -n ^requirepass /etc/redis/redis.conf",
            "是否继续？",
        ]
        let wrappedRender = [
            "Agent 想执行",
            "以下命令",
            "grep -n",
            "^requirepass /etc/redis/redis.conf",
            "是否继续？",
        ]
        let unrelatedRender = ["欢迎回来", "这里没有需要确认的操作"]

        #expect(AgentDesignToCodeTools.normalizedOCRCoverage(
            sourceTexts: source,
            renderedTexts: wrappedRender
        ) == 100)
        #expect(AgentDesignToCodeTools.normalizedOCRCoverage(
            sourceTexts: source,
            renderedTexts: unrelatedRender
        ) < 20)
    }

    @Test
    @MainActor
    func screenshotSlashCommandHasOneMainAgentRoute() {
        let commands = SlashCommand.builtIn(state: AppState())
            .filter { $0.title == "/screenshot-to-code" }

        #expect(commands.count == 1)
        #expect(commands.first?.id == "screenshot-to-code")
        #expect(commands.first?.argumentMode.requiresArguments == true)
    }

    @Test
    @MainActor
    func screenshotSlashCommandPreservesOrdinaryPlanAndActivatesExpert() {
        let runtime = AgentRuntime(session: AgentSession(title: "Design to code"))
        runtime.interactionMode = .normal
        runtime.currentPlan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "Old plan")],
            summary: "Old plan"
        )

        AgentDesignToCode.prepareRuntimeForSlashExecution(runtime, framework: "html")

        #expect(runtime.interactionMode == .normal)
        #expect(runtime.currentPlan?.steps.map(\.text) == ["Old plan"])
        #expect(runtime.activeExperts == AgentDesignToCode.webExperts)
        #expect(AgentDesignToCode.prefersWebExecution(framework: "SwiftUI") == false)
        #expect(AgentDesignToCode.prefersWebExecution(framework: nil) == true)
    }

    @Test
    func composerCtaRoutesByWorkspaceInsteadOfLocalizedKeywords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-DesignToCodeRoute-\(UUID().uuidString)", isDirectory: true)
        let web = root.appendingPathComponent("web", isDirectory: true)
        let native = root.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FileManager.default.createFile(atPath: web.appendingPathComponent("index.html").path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: native.appendingPathComponent("Package.swift").path, contents: Data()))

        #expect(AgentDesignToCode.preferredSkillIdentifier(workspaceRootPath: web.path) == "design-to-code")
        #expect(AgentDesignToCode.preferredSkillIdentifier(workspaceRootPath: native.path) == "figma-swiftui")
        #expect(AgentDesignToCode.preferredSkillIdentifier(workspaceRootPath: nil) == "design-to-code")
        #expect(AgentDesignToCode.webExperts == [.webCoding, .browserOps])
        #expect(AgentSidePanelKind.embeddedBrowser.requiredExpert == .browserOps)
    }

    private func call(
        messageID: UUID,
        name: String,
        payload: String = "ok"
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: messageID,
            externalID: UUID().uuidString,
            toolName: name,
            arguments: [:],
            risk: name == "edit_file" || name == "design_to_code_acceptance" ? .write : .read,
            status: .succeeded,
            result: AgentToolResult(summary: "ok", payload: payload)
        )
    }
}
