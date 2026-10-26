//
//  AgentHostDataPathGuardTests.swift
//  WillDeepTests
//
//  WillDeep 自己的数据目录（`~/Library/Application Support/WillDeep`、
//  `~/.willdeep`）对 Agent 是写保护的。起因：一位用户的会话历史文件
//  `agent-sessions/<UUID>.json` 消失，宿主 store 从不删非空会话，唯一能删
//  它的是完全访问档下自动放行的 `rm -rf`。三个入口共用一份判据：shell
//  门禁（打字确认 + 完全访问黑名单）、原生文件工具（拒绝）、读取（放行）。
//

import Foundation
import Testing
import WillDeepCore
@testable import WillDeep

@Suite("宿主数据目录写保护")
struct AgentHostDataPathGuardTests {
    private static let sessionsHomeRelative = "Library/Application Support/WillDeep/agent-sessions"
    private static var realHome: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    /// 几种拼法都得落到同一个目录：`~`、`$HOME`、`${HOME}`、绝对路径。
    private static let destructiveSpellings: [String] = [
        "rm -rf ~/Library/Application\\ Support/WillDeep/agent-sessions",
        "rm -rf \"$HOME/Library/Application Support/WillDeep/agent-sessions\"",
        "rm -rf \"${HOME}/Library/Application Support/WillDeep/agent-sessions\"",
        "rm -rf '\(realHome)/Library/Application Support/WillDeep/agent-sessions'",
        // 通配删内容与删目录是同一件事。
        "rm -f ~/Library/Application\\ Support/WillDeep/agent-sessions/*.json",
        // 删祖先目录一样会带走会话。
        "rm -rf ~/Library/Application\\ Support",
        // 移走、截断、重定向覆盖。
        "mv ~/Library/Application\\ Support/WillDeep/agent-sessions /tmp/gone",
        "echo '{}' > ~/Library/Application\\ Support/WillDeep/agent-sessions/x.json",
        "sudo rm -rf ~/Library/Application\\ Support/WillDeep",
        "rm -rf ~/.willdeep/approvals.jsonl",
    ]

    private static let readSpellings: [String] = [
        "cat ~/Library/Application\\ Support/WillDeep/agent-sessions/x.json",
        "ls -la \"$HOME/Library/Application Support/WillDeep/agent-sessions\"",
        "tail -n 50 ~/Library/Application\\ Support/WillDeep/AgentAudit/judge.jsonl",
        "grep -c toolName ~/Library/Application\\ Support/WillDeep/AgentAudit/sandbox.jsonl",
    ]

    @Test("删除/改写宿主数据目录的 shell 命令必须打字确认", arguments: destructiveSpellings)
    func destructiveShellCommandRequiresTypedConfirmation(command: String) {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-host-data-guard-workspace")
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: workspace)
        #expect(decision.mode == .escalated, "\(command): \(decision.reason)")
        #expect(decision.requiresTypedConfirmation, "\(command): \(decision.reason)")
        #expect(decision.reason.contains("WillDeep's own data"), "\(command): \(decision.reason)")
        // 打字确认一票否决送裁判。
        #expect(!AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))
    }

    @Test("完全访问的黑名单同口径拦下宿主数据目录破坏", arguments: destructiveSpellings)
    func fullAccessDenylistCatchesHostDataDestruction(command: String) {
        #expect(
            AgentMaliciousCommandDenylist.match(command: command)?.ruleID == "willdeep-own-data-destruction",
            "应命中黑名单：\(command)"
        )
    }

    @Test("完全访问不自动放行宿主数据目录破坏，回落人工审批")
    @MainActor
    func fullAccessDoesNotSilentlyApproveHostDataDestruction() async {
        let appState = AppState()
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-host-data-guard-workspace")
        for command in [
            "rm -rf ~/Library/Application\\ Support/WillDeep/agent-sessions",
            "rm -rf \"$HOME/Library/Application Support/WillDeep/agent-sessions\"",
        ] {
            let source = await appState.autoApprovalSource(
                toolName: "run_command",
                arguments: ["command": .string(command)],
                risk: .danger,
                rootDirectory: workspace,
                approvalMode: .fullAccess
            )
            #expect(source == nil, "完全访问不该自动放行：\(command)")
        }
    }

    @Test("读取宿主数据目录不受影响", arguments: readSpellings)
    func readingHostDataStaysAllowed(command: String) {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-host-data-guard-workspace")
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: workspace)
        #expect(!decision.requiresTypedConfirmation, "\(command): \(decision.reason)")
        #expect(!decision.reason.contains("WillDeep's own data"), "\(command): \(decision.reason)")
        #expect(AgentMaliciousCommandDenylist.match(command: command) == nil, "读不该进黑名单：\(command)")
    }

    @Test("完全访问下读取宿主数据目录照常放行")
    @MainActor
    func fullAccessStillApprovesReads() async {
        let appState = AppState()
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-host-data-guard-workspace")
        let source = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("cat ~/Library/Application\\ Support/WillDeep/agent-sessions/x.json")],
            risk: .danger,
            rootDirectory: workspace,
            approvalMode: .fullAccess
        )
        #expect(source == .fullAccess)
    }

    @Test("工作区内无关的 rm 不受影响")
    @MainActor
    func unrelatedWorkspaceRemovalIsUnaffected() async {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-host-data-guard-workspace").standardizedFileURL
        let cleanup = AgentSandboxPolicy.commandDecision(command: "rm -rf node_modules", rootDirectory: workspace)
        #expect(cleanup.mode == .workspaceWrite, "\(cleanup.reason)")
        #expect(!cleanup.requiresTypedConfirmation)
        #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(command: "rm -rf node_modules", rootDirectory: workspace))

        let absolute = "rm -rf \(workspace.path)/build"
        #expect(AgentMaliciousCommandDenylist.match(command: absolute) == nil)
        #expect(AgentMaliciousCommandDenylist.match(command: "rm -rf ~/Library/Caches/willdeep-scratch") == nil)

        let appState = AppState()
        let source = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string(absolute)],
            risk: .danger,
            rootDirectory: workspace,
            approvalMode: .fullAccess
        )
        #expect(source == .fullAccess)
    }

    @Test("write_file 拒绝写入宿主数据目录，并且不进新建文档快车道")
    @MainActor
    func externalWriteToolRefusesHostDataPath() async {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-host-data-guard-workspace")
        let arguments: [String: AgentJSONValue] = [
            "path": .string("~/\(Self.sessionsHomeRelative)/willdeep-guard-test-\(UUID().uuidString).json"),
            "content": .string("{}"),
        ]
        #expect(AgentExternalFileWritePolicy.target(arguments: arguments, rootDirectory: workspace)?.isSensitive == true)
        #expect(!AgentExternalFileWritePolicy.canAutoApproveNewDocument(arguments: arguments, rootDirectory: workspace))

        let context = AgentToolContext(rootDirectory: workspace)
        var thrown: AgentToolError?
        do {
            _ = try await AgentExternalFileTools.writeFile(arguments: arguments, context: context)
        } catch let error as AgentToolError {
            thrown = error
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        guard case .protectedHostDataPath(_, let protectedRoot)? = thrown else {
            Issue.record("expected protectedHostDataPath, got \(String(describing: thrown))")
            return
        }
        #expect(protectedRoot.hasSuffix("/Library/Application Support/WillDeep"))
        #expect(thrown?.errorDescription?.contains("session history") == true)
    }

    @Test("把宿主数据目录当工作区打开时，create_file/edit_file 仍然拒绝写入")
    @MainActor
    func workspaceFileToolsRefuseHostDataPath() async {
        let hostData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WillDeep", isDirectory: true)
        let context = AgentToolContext(rootDirectory: hostData)
        var thrown: AgentToolError?
        do {
            _ = try await AgentToolRunner.createFile(
                arguments: [
                    "path": .string("agent-sessions/willdeep-guard-test-\(UUID().uuidString).json"),
                    "content": .string("{}"),
                ],
                context: context
            )
        } catch let error as AgentToolError {
            thrown = error
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        guard case .protectedHostDataPath? = thrown else {
            Issue.record("expected protectedHostDataPath, got \(String(describing: thrown))")
            return
        }
    }

    @Test("路径按 realpath 比对：经软链接到达受保护目录一样命中")
    func symlinkIntoHostDataDirectoryIsResolved() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("willdeep-guard-home-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent(Self.sessionsHomeRelative, isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        let link = home.appendingPathComponent("wd-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("Library/Application Support/WillDeep"))

        let hit = AgentHostDataPathPolicy.mutationHit(
            tokens: ["rm", "-rf", "\(link.path)/agent-sessions"],
            workingDirectory: nil,
            home: home
        )
        #expect(hit != nil)
        // 相对路径按 cwd 落地。
        let relative = AgentHostDataPathPolicy.mutationHit(
            tokens: ["rm", "-rf", "agent-sessions"],
            workingDirectory: home.appendingPathComponent("Library/Application Support/WillDeep"),
            home: home
        )
        #expect(relative != nil)
        // 没有 cwd 的相对路径不猜。
        #expect(AgentHostDataPathPolicy.mutationHit(tokens: ["rm", "-rf", "agent-sessions"], workingDirectory: nil, home: home) == nil)
        // 同名但不在主目录下的路径不算。
        let elsewhere = fileManager.temporaryDirectory.appendingPathComponent("elsewhere/Library/Application Support/WillDeep/agent-sessions").path
        #expect(AgentHostDataPathPolicy.mutationHit(tokens: ["rm", "-rf", elsewhere], workingDirectory: nil, home: home) == nil)
    }
}
