import Foundation
import Testing
@testable import WillDeep

@Suite @MainActor
struct AgentWorkspaceTemplateApprovalTests {
    private let root = URL(fileURLWithPath: "/tmp/willdeep-template-tests")
    private let screenshotCommand = "git diff -- internal/config/config.go .env.example deploy/k8s/configmap.yaml"

    @Test("the reported git diff is read-only and statically approved")
    func screenshotRegression() async {
        let decision = AgentSandboxPolicy.commandDecision(command: screenshotCommand, rootDirectory: root)
        #expect(SafeCommand.classify(command: screenshotCommand) == .alwaysSafe)
        #expect(decision.mode == .readOnly)
        #expect(!decision.requiresTypedConfirmation)
        #expect(!decision.credentialSensitive)
        let source = await AppState().autoApprovalSource(
            toolName: "run_command", arguments: ["command": .string(screenshotCommand)],
            risk: .write, rootDirectory: root, approvalMode: .smart
        )
        #expect(source == .staticAllowlist)
    }

    @Test(arguments: [".env.example", ".env.sample", "config/.env.template"])
    func publicTemplatesAreReadOnly(_ path: String) {
        let decision = AgentSandboxPolicy.commandDecision(command: "git diff -- \(path)", rootDirectory: root)
        #expect(decision.mode == .readOnly)
        #expect(!decision.credentialSensitive)
    }

    @Test(arguments: [".env", ".env.local", ".env.production", ".env.example.bak", "../.env.example", "/etc/.env.example", "secrets/.env.example", ".ssh/.env.example"])
    func credentialsAndExternalPathsStayGated(_ path: String) {
        let decision = AgentSandboxPolicy.commandDecision(command: "git diff -- \(path)", rootDirectory: root)
        #expect(decision.requiresTypedConfirmation)
        #expect(decision.credentialSensitive)
    }

    @Test("a template symlink cannot expose a credential file", arguments: [".env", ".env.sample", "../outside/.env.template"])
    func symlinkCannotEscape(_ target: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent(".env.example")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent(target))
        #expect(!AgentWorkspaceTemplatePolicy.isPublicTemplate(link.path, workingDirectory: directory, roots: [directory]))
    }

    @Test("directory symlinks and parent traversals cannot bypass the template boundary")
    func directorySymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("secrets"))
        for path in ["config/.env.example", "config/../.env.example"] {
            #expect(!AgentWorkspaceTemplatePolicy.isPublicTemplate(path, workingDirectory: directory, roots: [directory]))
        }
    }

    @Test(arguments: ["git diff --ext-diff", "git diff --textconv", "git -c diff.external=helper diff", "git diff --output=result.patch"])
    func externalHelpersAndWritesAreNotReadOnly(_ command: String) {
        #expect(SafeCommand.classify(command: command) != .alwaysSafe)
    }

    @Test("approval copy describes credential access rather than inventing writes")
    func commandCopyReflectsImpact() {
        let read = AgentApprovalNoticeCopy.descriptor(toolName: "run_command", arguments: ["command": .string("git diff"), "cwd": .string(root.path)])
        let credential = AgentApprovalNoticeCopy.descriptor(toolName: "run_command", arguments: ["command": .string("git diff -- .env"), "cwd": .string(root.path)])
        #expect(read.metadata.contains(String(localized: "只读检查，不修改工作区文件", table: "WorkerArchitecture")))
        #expect(credential.metadata.contains(String(localized: "可能读取凭据或敏感文件", table: "WorkerArchitecture")))
        #expect(!credential.metadata.contains("可能更新工作区文件"))
    }
}
