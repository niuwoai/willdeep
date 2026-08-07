//
//  AgentExecutorProtocolTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Structured agent executor protocol")
struct AgentExecutorProtocolTests {
    @Test("Claude prompt uses stdin and stream JSON")
    func claudeSpecificationKeepsPromptOutOfArguments() throws {
        let prompt = "Fix 'quotes' and $(touch /tmp/should-not-run)\nThen explain."
        let specification = AgentExecutorProcessFactory.claudeCode(
            executable: "/usr/bin/true",
            prompt: prompt,
            permissionMode: "acceptEdits",
            model: "sonnet",
            imagePaths: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: [:],
            sandboxMode: .readOnly
        )

        #expect(!specification.arguments.contains(where: { $0.contains(prompt) }))
        #expect(specification.arguments.contains("stream-json"))
        #expect(specification.arguments.contains("--input-format"))
        #expect(String(decoding: specification.standardInput, as: UTF8.self) == prompt + "\n")
    }

    @Test("Codex prompt uses stdin and JSONL")
    func codexSpecificationKeepsPromptOutOfArguments() throws {
        let prompt = "Inspect `git diff`; do not execute $(false)."
        let specification = AgentExecutorProcessFactory.codexCLI(
            executable: "/usr/bin/true",
            prompt: prompt,
            permissionMode: "workspaceWrite",
            model: nil,
            workspacePath: "/tmp/workspace",
            imagePaths: [],
            workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
            environment: [:],
            sandboxMode: .workspaceWrite
        )

        #expect(!specification.arguments.contains(where: { $0.contains(prompt) }))
        #expect(specification.arguments.contains("--json"))
        #expect(specification.arguments.last == "-")
        #expect(String(decoding: specification.standardInput, as: UTF8.self) == prompt + "\n")
    }

    @Test("Claude and Codex resume exact structured sessions")
    func specificationsResumeSessions() {
        let claude = AgentExecutorProcessFactory.claudeCode(
            executable: "/usr/bin/true",
            prompt: "Continue.",
            permissionMode: "acceptEdits",
            model: nil,
            sessionID: "claude-session",
            imagePaths: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: [:],
            sandboxMode: .workspaceWrite
        )
        let codex = AgentExecutorProcessFactory.codexCLI(
            executable: "/usr/bin/true",
            prompt: "Continue.",
            permissionMode: "workspaceWrite",
            model: nil,
            sessionID: "codex-session",
            workspacePath: "/tmp",
            imagePaths: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: [:],
            sandboxMode: .workspaceWrite
        )

        let claudeResumeIndex = claude.arguments.firstIndex(of: "--resume")
        #expect(claudeResumeIndex != nil)
        if let claudeResumeIndex {
            #expect(claude.arguments[claudeResumeIndex + 1] == "claude-session")
        }
        #expect(codex.arguments.contains("resume"))
        #expect(codex.arguments.suffix(2) == ["codex-session", "-"])
    }

    @Test("Claude stream normalizes session, tool, usage, and result")
    func claudeDecoderNormalizesLifecycle() {
        let decoder = ClaudeCodeStreamEventDecoder()
        let initEvents = decoder.decode(
            line: #"{"type":"system","subtype":"init","session_id":"session-1","model":"claude-test","tools":["Read","Edit"]}"#
        )
        let toolEvents = decoder.decode(
            line: #"{"type":"assistant","session_id":"session-1","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Edit","input":{"file_path":"a.swift"}}]}}"#
        )
        let resultEvents = decoder.decode(
            line: #"{"type":"result","session_id":"session-1","is_error":false,"result":"done","duration_ms":1200,"total_cost_usd":0.02,"usage":{"input_tokens":10,"cache_read_input_tokens":3,"output_tokens":4}}"#
        )

        #expect(initEvents.first?.kind == .sessionStarted)
        #expect(initEvents.first?.sessionID == "session-1")
        #expect(toolEvents.first?.kind == .toolStarted)
        #expect(toolEvents.first?.toolName == "Edit")
        #expect(resultEvents.contains(where: { $0.kind == .usage && $0.usage?.inputTokens == 10 }))
        #expect(resultEvents.last?.kind == .finished)
        #expect(resultEvents.last?.detail == "done")
    }

    @Test("Codex JSONL normalizes thread, file change, and usage")
    func codexDecoderNormalizesLifecycle() {
        let decoder = CodexJSONLEventDecoder()
        let threadEvents = decoder.decode(
            line: #"{"type":"thread.started","thread_id":"thread-1"}"#
        )
        let fileEvents = decoder.decode(
            line: #"{"type":"item.completed","item":{"id":"item-1","type":"file_change","changes":[{"path":"Xedit/App.swift","kind":"update"}]}}"#
        )
        let turnEvents = decoder.decode(
            line: #"{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":8}}"#
        )

        #expect(threadEvents.first?.kind == .sessionStarted)
        #expect(threadEvents.first?.sessionID == "thread-1")
        #expect(fileEvents.first?.kind == .fileChanged)
        #expect(fileEvents.first?.filePath == "Xedit/App.swift")
        #expect(turnEvents.contains(where: { $0.kind == .usage && $0.usage?.outputTokens == 8 }))
        #expect(turnEvents.last?.kind == .finished)
    }

    @Test("Codex app-server completes a bidirectional approval round trip")
    func codexAppServerApprovalRoundTrip() async throws {
        let prompt = "Inspect the workspace without putting this prompt in argv."
        let fakeServer = #"""
        require "json"
        STDOUT.sync = true
        def emit(value)
          STDOUT.puts(JSON.generate(value))
        end
        while (line = STDIN.gets)
          message = JSON.parse(line)
          case message["id"]
          when "initialize"
            emit({"id"=>"initialize", "result"=>{"serverInfo"=>{"name"=>"fake"}}})
          when "thread"
            emit({"id"=>"thread", "result"=>{"thread"=>{"id"=>"thread-app-server"}}})
          when "turn"
            emit({"id"=>"turn", "result"=>{"turn"=>{"id"=>"turn-1", "status"=>"inProgress"}}})
            emit({
              "id"=>41,
              "method"=>"item/commandExecution/requestApproval",
              "params"=>{
                "itemId"=>"command-1",
                "threadId"=>"thread-app-server",
                "turnId"=>"turn-1",
                "startedAtMs"=>1,
                "command"=>"git status",
                "cwd"=>"/tmp",
                "reason"=>"Inspect changes",
                "availableDecisions"=>["accept", "decline"]
              }
            })
            approval = JSON.parse(STDIN.gets)
            abort("approval was not accepted") unless approval.dig("result", "decision") == "accept"
            emit({
              "method"=>"item/completed",
              "params"=>{
                "threadId"=>"thread-app-server",
                "turnId"=>"turn-1",
                "item"=>{"id"=>"message-1", "type"=>"agentMessage", "text"=>"done"}
              }
            })
            emit({
              "method"=>"thread/tokenUsage/updated",
              "params"=>{
                "threadId"=>"thread-app-server",
                "tokenUsage"=>{"last"=>{"inputTokens"=>7, "cachedInputTokens"=>2, "outputTokens"=>3}}
              }
            })
            emit({
              "method"=>"turn/completed",
              "params"=>{
                "threadId"=>"thread-app-server",
                "turn"=>{"id"=>"turn-1", "status"=>"completed"}
              }
            })
          end
        end
        """#
        let approvalProbe = CodexApprovalProbe()
        let eventProbe = CodexEventProbe()
        let configuration = AgentCodexAppServerConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            prompt: prompt,
            model: nil,
            sessionID: nil,
            imagePaths: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: ProcessInfo.processInfo.environment,
            sandboxMode: .escalated,
            permissionMode: "workspaceWrite",
            secretRedactionValues: [],
            serverArguments: ["-e", fakeServer]
        )
        let turn = AgentCodexAppServerTurn(
            configuration: configuration,
            approvalHandler: { request in
                await approvalProbe.record(request)
                return .accept
            },
            eventHandler: { events in
                await eventProbe.append(events)
            },
            processHandler: { _ in }
        )

        let result = try await turn.run()
        let approval = await approvalProbe.request
        let events = await eventProbe.events
        let completedApproval = events.contains { event in
            event.kind == .permissionRequested
                && event.status == .completed
        }
        let completedMessage = events.contains { event in
            event.kind == .message && event.detail == "done"
        }
        let usageWithCache = events.contains { event in
            event.kind == .usage
                && event.usage?.cachedInputTokens == 2
        }

        #expect(result.sessionID == "thread-app-server")
        #expect(result.status == .completed)
        #expect(approval?.kind == .command)
        #expect(approval?.command == "git status")
        #expect(completedApproval)
        #expect(completedMessage)
        #expect(usageWithCache)
        #expect(events.last?.kind == .finished)
    }

    @Test("Transport capabilities select ACP only with host control")
    func transportCapabilitiesAreExplicit() {
        let acp = AgentExecutorCapabilityResolver.select(
            executor: .claudeCode,
            isRemote: false,
            usesDaemon: false,
            usesVisibleTerminal: false,
            hasHostApproval: true,
            hasACPAdapter: true
        )
        let fallback = AgentExecutorCapabilityResolver.select(
            executor: .claudeCode,
            isRemote: false,
            usesDaemon: false,
            usesVisibleTerminal: false,
            hasHostApproval: false,
            hasACPAdapter: true
        )
        let visible = AgentExecutorCapabilityResolver.select(
            executor: .claudeCode,
            isRemote: false,
            usesDaemon: false,
            usesVisibleTerminal: true,
            hasHostApproval: true,
            hasACPAdapter: true
        )

        #expect(acp.transport == .agentClientProtocol)
        #expect(acp.hostApprovals)
        #expect(acp.reverseFileSystem)
        #expect(acp.reverseTerminal)
        #expect(fallback.transport == .structuredProcess)
        #expect(!fallback.hostApprovals)
        #expect(visible.transport == .visibleTerminal)
        #expect(
            AgentToolRunner.claudeCodeCLIPermissionMode("default")
                == "dontAsk"
        )
        #expect(
            AgentToolRunner.claudeCodeCLIPermissionMode("acceptEdits")
                == "acceptEdits"
        )
        #expect(
            AgentToolRunner.claudeCodeCLIPermissionMode(
                "acceptEdits",
                unattended: true
            ) == "bypassPermissions"
        )
    }

    @Test("无人值守 Claude 使用跳过权限确认参数且提示词仍走 stdin")
    func unattendedClaudeSpecificationSkipsPermissionPrompts() {
        let specification = AgentExecutorProcessFactory.claudeCode(
            executable: "/usr/bin/true",
            prompt: "Run without an attached operator.",
            permissionMode: "bypassPermissions",
            model: nil,
            imagePaths: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: [:],
            sandboxMode: .workspaceWrite
        )

        #expect(specification.arguments.contains("--dangerously-skip-permissions"))
        #expect(!specification.arguments.contains("bypassPermissions"))
        #expect(String(decoding: specification.standardInput, as: UTF8.self)
            == "Run without an attached operator.\n")
    }

    @Test("ACP round trip delegates approval, files, and terminal to host")
    @MainActor
    func acpHostDelegationRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-acp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let readPath = root.appendingPathComponent("read.txt").path
        let writePath = root.appendingPathComponent("write.txt").path
        let prompt = "Keep this ACP prompt out of argv."
        let fakeServer = #"""
        require "json"
        STDOUT.sync = true
        def emit(value)
          STDOUT.puts(JSON.generate(value))
        end
        def receive
          JSON.parse(STDIN.gets || abort("unexpected EOF"))
        end
        initialize_request = receive
        abort("missing fs capability") unless initialize_request.dig("params", "clientCapabilities", "fs", "readTextFile")
        abort("missing terminal capability") unless initialize_request.dig("params", "clientCapabilities", "terminal")
        emit({"jsonrpc"=>"2.0", "id"=>"initialize", "result"=>{"protocolVersion"=>1, "agentCapabilities"=>{}}})
        session_request = receive
        abort("expected new session") unless session_request["method"] == "session/new"
        emit({"jsonrpc"=>"2.0", "id"=>"session", "result"=>{"sessionId"=>"acp-session-1"}})
        prompt_request = receive
        abort("prompt did not use ACP content blocks") unless prompt_request.dig("params", "prompt", 0, "text") == "\#(prompt)"

        emit({
          "jsonrpc"=>"2.0", "id"=>10, "method"=>"session/request_permission",
          "params"=>{
            "sessionId"=>"acp-session-1",
            "options"=>[
              {"optionId"=>"allow-once", "kind"=>"allow_once"},
              {"optionId"=>"allow-always", "kind"=>"allow_always"},
              {"optionId"=>"reject-once", "kind"=>"reject_once"}
            ],
            "toolCall"=>{
              "toolCallId"=>"command-call", "title"=>"Run printf", "kind"=>"execute",
              "rawInput"=>{"command"=>"/usr/bin/printf acp-terminal"}
            }
          }
        })
        command_approval = receive
        abort("command approval not selected") unless command_approval.dig("result", "outcome", "optionId") == "allow-once"
        emit({
          "jsonrpc"=>"2.0", "id"=>11, "method"=>"terminal/create",
          "params"=>{
            "sessionId"=>"acp-session-1",
            "command"=>"/usr/bin/printf acp-terminal",
            "cwd"=>"\#(root.path)", "outputByteLimit"=>4096
          }
        })
        terminal = receive.dig("result", "terminalId")
        abort("terminal id missing") unless terminal
        emit({"jsonrpc"=>"2.0", "id"=>12, "method"=>"terminal/wait_for_exit", "params"=>{"sessionId"=>"acp-session-1", "terminalId"=>terminal}})
        terminal_exit = receive
        abort("terminal failed") unless terminal_exit.dig("result", "exitCode") == 0
        emit({"jsonrpc"=>"2.0", "id"=>13, "method"=>"terminal/output", "params"=>{"sessionId"=>"acp-session-1", "terminalId"=>terminal}})
        terminal_output = receive
        abort("terminal output missing") unless terminal_output.dig("result", "output").include?("acp-terminal")
        emit({"jsonrpc"=>"2.0", "id"=>14, "method"=>"terminal/release", "params"=>{"sessionId"=>"acp-session-1", "terminalId"=>terminal}})
        receive

        emit({"jsonrpc"=>"2.0", "id"=>20, "method"=>"fs/read_text_file", "params"=>{"sessionId"=>"acp-session-1", "path"=>"\#(readPath)"}})
        read_response = receive
        abort("host editor buffer was not read") unless read_response.dig("result", "content") == "unsaved editor buffer"
        emit({
          "jsonrpc"=>"2.0", "id"=>21, "method"=>"session/request_permission",
          "params"=>{
            "sessionId"=>"acp-session-1",
            "options"=>[{"optionId"=>"allow-file", "kind"=>"allow_once"}],
            "toolCall"=>{
              "toolCallId"=>"file-call", "title"=>"Write file", "kind"=>"edit",
              "locations"=>[{"path"=>"\#(writePath)"}],
              "rawInput"=>{"path"=>"\#(writePath)"}
            }
          }
        })
        file_approval = receive
        abort("file approval not selected") unless file_approval.dig("result", "outcome", "optionId") == "allow-file"
        emit({
          "jsonrpc"=>"2.0", "id"=>22, "method"=>"fs/write_text_file",
          "params"=>{"sessionId"=>"acp-session-1", "path"=>"\#(writePath)", "content"=>"written through host"}
        })
        receive
        emit({
          "jsonrpc"=>"2.0", "method"=>"session/update",
          "params"=>{
            "sessionId"=>"acp-session-1",
            "update"=>{"sessionUpdate"=>"agent_message_chunk", "content"=>{"type"=>"text", "text"=>"ACP done"}}
          }
        })
        emit({
          "jsonrpc"=>"2.0", "id"=>"prompt",
          "result"=>{"stopReason"=>"end_turn", "usage"=>{"inputTokens"=>9, "outputTokens"=>4}}
        })
        """#
        let approvalProbe = ACPApprovalProbe()
        let eventProbe = ACPEventProbe()
        let writeProbe = ACPWriteProbe()
        let configuration = AgentACPConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            adapterArguments: ["-e", fakeServer],
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            prompt: prompt,
            model: nil,
            sessionID: nil,
            imagePaths: [],
            workingDirectory: root,
            environment: ProcessInfo.processInfo.environment,
            sandboxMode: .escalated,
            permissionMode: "default",
            secretRedactionValues: []
        )
        #expect(!configuration.adapterArguments.contains(prompt))
        let turn = AgentACPClientTurn(
            configuration: configuration,
            approvalHandler: { request in
                await approvalProbe.record(request)
                return .accept
            },
            readHandler: { _ in "unsaved editor buffer" },
            writeHandler: { url, content in
                writeProbe.record(url: url, content: content)
            },
            eventHandler: { events in
                await eventProbe.append(events)
            },
            processHandler: { _ in }
        )

        let result = try await turn.run()
        let approvals = await approvalProbe.requests
        let events = await eventProbe.events
        let receivedAssistantMessage = events.contains { event in
            event.kind == .message && event.detail == "ACP done"
        }
        let receivedUsage = events.contains { event in
            event.kind == .usage && event.usage?.inputTokens == 9
        }

        #expect(result.sessionID == "acp-session-1")
        #expect(result.status == .completed)
        #expect(approvals.contains(where: { $0.kind == .command }))
        #expect(approvals.contains(where: { $0.kind == .fileChange }))
        #expect(writeProbe.url?.path == writePath)
        #expect(writeProbe.content == "written through host")
        #expect(receivedAssistantMessage)
        #expect(receivedUsage)
        #expect(events.last?.kind == .finished)
    }

    @Test("ACP reuses one adapter process for resumed prompts")
    @MainActor
    func acpPersistentProcessSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-acp-persistent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "persistent-\(UUID().uuidString)"
        let firstPrompt = "first ACP turn"
        let secondPrompt = "second ACP turn"
        let fakeServer = #"""
        require "json"
        STDOUT.sync = true
        def emit(value)
          STDOUT.puts(JSON.generate(value))
        end
        def receive
          JSON.parse(STDIN.gets || abort("unexpected EOF"))
        end
        initialize_request = receive
        abort("expected initialize") unless initialize_request["method"] == "initialize"
        emit({"jsonrpc"=>"2.0", "id"=>"initialize", "result"=>{"protocolVersion"=>1}})
        session_request = receive
        abort("expected one new session") unless session_request["method"] == "session/new"
        emit({"jsonrpc"=>"2.0", "id"=>"session", "result"=>{"sessionId"=>"\#(sessionID)"}})
        first = receive
        abort("first prompt mismatch") unless first["method"] == "session/prompt" && first.dig("params", "prompt", 0, "text") == "\#(firstPrompt)"
        emit({"jsonrpc"=>"2.0", "id"=>"prompt", "result"=>{"stopReason"=>"end_turn"}})
        second = receive
        abort("second prompt restarted protocol") unless second["method"] == "session/prompt"
        abort("second prompt mismatch") unless second.dig("params", "prompt", 0, "text") == "\#(secondPrompt)"
        emit({"jsonrpc"=>"2.0", "id"=>"prompt", "result"=>{"stopReason"=>"end_turn"}})
        """#
        let processProbe = ACPProcessProbe()
        let baseArguments = ["-e", fakeServer]
        let firstConfiguration = AgentACPConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            adapterArguments: baseArguments,
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            prompt: firstPrompt,
            model: nil,
            sessionID: nil,
            imagePaths: [],
            workingDirectory: root,
            environment: ProcessInfo.processInfo.environment,
            sandboxMode: .escalated,
            permissionMode: "default",
            secretRedactionValues: []
        )
        let firstTurn = AgentACPClientTurn(
            configuration: firstConfiguration,
            approvalHandler: nil,
            readHandler: nil,
            writeHandler: nil,
            eventHandler: { _ in },
            processHandler: { pid in await processProbe.record(pid) }
        )
        let firstResult = try await firstTurn.run()

        let secondConfiguration = AgentACPConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            adapterArguments: baseArguments,
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            prompt: secondPrompt,
            model: nil,
            sessionID: firstResult.sessionID,
            imagePaths: [],
            workingDirectory: root,
            environment: ProcessInfo.processInfo.environment,
            sandboxMode: .escalated,
            permissionMode: "default",
            secretRedactionValues: []
        )
        let secondTurn = AgentACPClientTurn(
            configuration: secondConfiguration,
            approvalHandler: nil,
            readHandler: nil,
            writeHandler: nil,
            eventHandler: { _ in },
            processHandler: { pid in await processProbe.record(pid) }
        )
        let secondResult = try await secondTurn.run()
        let processIDs = await processProbe.values

        #expect(secondResult.sessionID == firstResult.sessionID)
        #expect(processIDs.count == 2)
        #expect(processIDs.first == processIDs.last)
    }

    @Test("ACP workspace guard rejects symlink escapes")
    func acpWorkspaceGuardRejectsSymlinkEscape() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-acp-guard-\(UUID().uuidString)")
        let workspace = temporaryRoot.appendingPathComponent("workspace")
        let outside = temporaryRoot.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let link = workspace.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        let escapedPath = link.appendingPathComponent("secret.txt").path
        let fakeServer = #"""
        require "json"
        STDOUT.sync = true
        def emit(value)
          STDOUT.puts(JSON.generate(value))
        end
        initialize_request = JSON.parse(STDIN.gets)
        emit({"jsonrpc"=>"2.0", "id"=>initialize_request["id"], "result"=>{"protocolVersion"=>1, "agentCapabilities"=>{}}})
        session_request = JSON.parse(STDIN.gets)
        emit({"jsonrpc"=>"2.0", "id"=>session_request["id"], "result"=>{"sessionId"=>"guard-session"}})
        prompt_request = JSON.parse(STDIN.gets)
        emit({
          "jsonrpc"=>"2.0", "id"=>41, "method"=>"fs/read_text_file",
          "params"=>{"sessionId"=>"guard-session", "path"=>"\#(escapedPath)"}
        })
        response = JSON.parse(STDIN.gets)
        abort("symlink escape was not rejected") unless response.dig("error", "message").to_s.include?("outside the workspace")
        emit({
          "jsonrpc"=>"2.0", "id"=>prompt_request["id"],
          "result"=>{"stopReason"=>"end_turn"}
        })
        """#
        let configuration = AgentACPConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            adapterArguments: ["-e", fakeServer],
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            prompt: "Verify workspace containment.",
            model: nil,
            sessionID: nil,
            imagePaths: [],
            workingDirectory: workspace,
            environment: ProcessInfo.processInfo.environment,
            sandboxMode: .escalated,
            permissionMode: "default",
            secretRedactionValues: []
        )
        let turn = AgentACPClientTurn(
            configuration: configuration,
            approvalHandler: nil,
            readHandler: { _ in "must not be called" },
            writeHandler: nil,
            eventHandler: { _ in },
            processHandler: { _ in }
        )

        let result = try await turn.run()
        #expect(result.sessionID == "guard-session")
        #expect(result.status == .completed)
    }
}

private actor CodexApprovalProbe {
    private(set) var request: AgentDelegatedApprovalRequest?

    func record(_ request: AgentDelegatedApprovalRequest) {
        self.request = request
    }
}

private actor CodexEventProbe {
    private(set) var events: [AgentExecutorEvent] = []

    func append(_ values: [AgentExecutorEvent]) {
        events.append(contentsOf: values)
    }
}

private actor ACPApprovalProbe {
    private(set) var requests: [AgentDelegatedApprovalRequest] = []

    func record(_ request: AgentDelegatedApprovalRequest) {
        requests.append(request)
    }
}

private actor ACPEventProbe {
    private(set) var events: [AgentExecutorEvent] = []

    func append(_ values: [AgentExecutorEvent]) {
        events.append(contentsOf: values)
    }
}

private actor ACPProcessProbe {
    private(set) var values: [Int32] = []

    func record(_ value: Int32) {
        values.append(value)
    }
}

@MainActor
private final class ACPWriteProbe {
    private(set) var url: URL?
    private(set) var content: String?

    func record(url: URL, content: String) {
        self.url = url
        self.content = content
    }
}

@Suite("Structured agent process registry")
@MainActor
struct AgentExecutorProcessRegistryTests {
    /// How long a test waits for the process to reach a terminal state.
    private static let fullSuiteCompletionAllowanceSeconds: TimeInterval = 45
    /// Liveness cap handed to the job itself. It has to stay under the wait
    /// allowance above, or the wait gives up before the timeout it is meant to
    /// observe. None of these tests asserts timeout behaviour — they assert
    /// content — so the old 5s only ever acted as a load-sensitive kill switch:
    /// piping 272 KB through stdin outran it under a full-load parallel run and
    /// the job came back SIGTERMed as `.timedOut`.
    private static let fullSuiteJobTimeoutSeconds: TimeInterval = 30

    @Test("Fast process retains session, usage, and final result")
    func fastProcessRetainsAllStructuredEvents() async throws {
        let output = [
            #"{"type":"thread.started","thread_id":"thread-fast"}"#,
            #"{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"finished quickly"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3}}"#
        ].joined(separator: "\\n")
        let specification = AgentExecutorProcessSpecification(
            executor: .codexCLI,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%b\\n' \"$1\"", "structured-agent-test", output],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: ProcessInfo.processInfo.environment,
            standardInput: Data(),
            sandboxMode: .escalated,
            displayCommand: "structured test",
            decoder: CodexJSONLEventDecoder()
        )
        let registry = AgentJobRegistry()
        let job = try registry.startExecutor(
            specification: specification,
            runtimeID: UUID(),
            timeoutSeconds: Self.fullSuiteJobTimeoutSeconds
        )
        let completed = try await waitUntilFinished(
            registry: registry,
            id: job.id
        )

        #expect(completed.status == .completed)
        #expect(completed.executorSessionID == "thread-fast")
        #expect(completed.executorUsage?.inputTokens == 2)
        #expect(completed.executorUsage?.outputTokens == 3)
        #expect(registry.executorResultText(id: job.id) == "finished quickly")
    }

    @Test("Foreground structured process does not publish background completion")
    func foregroundProcessSuppressesCompletion() async throws {
        let runtimeID = UUID()
        let specification = AgentExecutorProcessSpecification(
            executor: .codexCLI,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: ProcessInfo.processInfo.environment,
            standardInput: Data(),
            sandboxMode: .escalated,
            displayCommand: "structured foreground test",
            decoder: CodexJSONLEventDecoder()
        )
        let registry = AgentJobRegistry()
        let job = try registry.startExecutor(
            specification: specification,
            runtimeID: runtimeID,
            timeoutSeconds: Self.fullSuiteJobTimeoutSeconds,
            publishesCompletion: false
        )
        _ = try await waitUntilFinished(registry: registry, id: job.id)

        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 0)
    }

    @Test("Structured events redact resolved secrets before publication")
    func structuredEventsRedactSecrets() async throws {
        let secret = "secret-value-123"
        let output = [
            #"{"type":"thread.started","thread_id":"thread-secret"}"#,
            #"{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"token: \#(secret)"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#
        ].joined(separator: "\\n")
        let specification = AgentExecutorProcessSpecification(
            executor: .codexCLI,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%b\\n' \"$1\"", "structured-agent-test", output],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: ProcessInfo.processInfo.environment,
            standardInput: Data(),
            sandboxMode: .escalated,
            displayCommand: "structured redaction test",
            decoder: CodexJSONLEventDecoder()
        )
        let registry = AgentJobRegistry()
        let job = try registry.startExecutor(
            specification: specification,
            runtimeID: UUID(),
            timeoutSeconds: Self.fullSuiteJobTimeoutSeconds,
            secretRedactionValues: [secret]
        )
        _ = try await waitUntilFinished(registry: registry, id: job.id)
        let encodedEvents = registry.executorEvents(id: job.id)
            .compactMap(\.rawJSON)
            .joined(separator: "\n")

        #expect(!encodedEvents.contains(secret))
        #expect(encodedEvents.contains("[secret]"))
        #expect(!registry.executorResultText(id: job.id).contains(secret))
    }

    @Test("Structured process consumes a large prompt through stdin")
    func structuredProcessConsumesLargeStandardInput() async throws {
        let prompt = String(repeating: "structured-input-", count: 16_384)
        let specification = AgentExecutorProcessSpecification(
            executor: .codexCLI,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                #"bytes="$(wc -c | awk '{print $1}')"; printf '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"bytes=%s"}}\n{"type":"turn.completed"}\n' "$bytes""#
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: ProcessInfo.processInfo.environment,
            standardInput: Data(prompt.utf8),
            sandboxMode: .escalated,
            displayCommand: "structured stdin test",
            decoder: CodexJSONLEventDecoder()
        )
        let registry = AgentJobRegistry()
        let job = try registry.startExecutor(
            specification: specification,
            runtimeID: UUID(),
            timeoutSeconds: Self.fullSuiteJobTimeoutSeconds
        )
        let completed = try await waitUntilFinished(
            registry: registry,
            id: job.id
        )

        #expect(completed.status == .completed)
        #expect(
            registry.executorResultText(id: job.id)
                == "bytes=\(prompt.utf8.count)"
        )
    }

    @Test("Provider failure overrides a zero process exit code")
    func providerFailureOverridesZeroExit() async throws {
        let output = #"{"type":"turn.failed","error":{"message":"provider rejected turn"}}"#
        let specification = AgentExecutorProcessSpecification(
            executor: .codexCLI,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$1\"", "structured-agent-test", output],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: ProcessInfo.processInfo.environment,
            standardInput: Data(),
            sandboxMode: .escalated,
            displayCommand: "structured failure test",
            decoder: CodexJSONLEventDecoder()
        )
        let registry = AgentJobRegistry()
        let job = try registry.startExecutor(
            specification: specification,
            runtimeID: UUID(),
            timeoutSeconds: Self.fullSuiteJobTimeoutSeconds
        )
        let completed = try await waitUntilFinished(
            registry: registry,
            id: job.id
        )

        #expect(completed.exitCode == 0)
        #expect(completed.status == .failed)
        #expect(
            registry.executorResultText(id: job.id)
                .contains("provider rejected turn")
        )
    }

    private func waitUntilFinished(
        registry: AgentJobRegistry,
        id: UUID
    ) async throws -> AgentBackgroundJob {
        let deadline = Date().addingTimeInterval(
            Self.fullSuiteCompletionAllowanceSeconds
        )
        while Date() < deadline {
            if let job = registry.job(id: id), !job.isAlive {
                return job
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Structured agent process did not finish before timeout.")
        return try #require(registry.job(id: id))
    }
}
