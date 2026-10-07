//
//  AgentMCPHostRequestsTests.swift
//  XeditTests
//
//  插件 MCP 进程反向请求宿主出图（`willdeep/images/generate`）。
//
//  守这几件事：只有插件来源的 stdio 服务能用；请求参数与页面桥走同一个校验器；
//  宿主替服务端干活的那段时间不算进服务端的超时；插件在 initialize 时能知道
//  宿主支不支持；宿主办反向请求期间，插件对别的请求的应答照常送达、进程不被
//  结束（网关探活也不去碰活着的连接）。出图本身用替身，不打外网、不花钱。
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentMCPHostRequestsTests {
    private func pluginServer(command: String = "/usr/bin/ruby", args: [String] = [], timeout: TimeInterval = 10) -> AgentMCPServerConfig {
        AgentMCPServerConfig(
            id: "plugin:willdeep-video-studio:video-studio",
            name: "video-studio", source: .plugin, transport: .stdio,
            command: command, args: args, startupTimeout: timeout
        )
    }

    private func fakeImage(_ pluginID: AgentPluginID, _ request: AgentPluginImageRequest) -> AgentPluginImageResult {
        AgentPluginImageResult(
            mediaURL: "willdeep-plugin://bundle/__media__/fake.png",
            filePath: "/tmp/\(pluginID)/fake.png",
            model: request.model,
            providerID: "some-im"
        )
    }

    @Test("只有插件来源的 stdio 服务能拿到插件 ID")
    func pluginIDIsParsedOnlyForPluginStdioServers() {
        #expect(AgentMCPHostRequests.pluginID(for: pluginServer()) == "willdeep-video-studio")
        let user = AgentMCPServerConfig(id: "plugin:evil:x", name: "x", source: .user, transport: .stdio, command: "/bin/echo")
        #expect(AgentMCPHostRequests.pluginID(for: user) == nil, "手工配置的服务就算 id 长得像插件也不认")
        var http = pluginServer()
        http.transport = .streamableHTTP
        #expect(AgentMCPHostRequests.pluginID(for: http) == nil)
    }

    @Test("initialize 只对插件服务宣告反向请求能力")
    func initializeAdvertisesCapabilityOnlyForPlugins() {
        let pluginExtensions = (AgentMCPBridge.initializeParams(for: pluginServer())["capabilities"] as? [String: Any])?["extensions"] as? [String: Any]
        let advertised = pluginExtensions?[AgentMCPHostRequests.capabilityKey] as? [String: Any]
        #expect(advertised?["methods"] as? [String] == ["willdeep/images/generate", "willdeep/ai/complete", "willdeep/roundtable/run"])
        #expect(pluginExtensions?["io.modelcontextprotocol/ui"] != nil, "原有的 UI 扩展不能丢")

        let user = AgentMCPServerConfig(name: "x", source: .user, transport: .stdio, command: "/bin/echo")
        let userExtensions = (AgentMCPBridge.initializeParams(for: user)["capabilities"] as? [String: Any])?["extensions"] as? [String: Any]
        #expect(userExtensions?[AgentMCPHostRequests.capabilityKey] == nil)
    }

    @Test("区分服务端请求、通知与响应")
    func recognizesServerRequests() {
        #expect(AgentMCPHostRequests.isServerRequest(["jsonrpc": "2.0", "id": "h1", "method": "willdeep/images/generate"]))
        #expect(!AgentMCPHostRequests.isServerRequest(["jsonrpc": "2.0", "method": "notifications/resources/updated"]))
        #expect(!AgentMCPHostRequests.isServerRequest(["jsonrpc": "2.0", "id": 3, "result": [:]]))
    }

    @Test("非插件服务、未知方法、坏参数都回 JSON-RPC 错误，不静默")
    func rejectsWhatItShould() async {
        AgentMCPHostRequests.setImageGeneratorForTesting { pluginID, request in self.fakeImage(pluginID, request) }
        defer { AgentMCPHostRequests.setImageGeneratorForTesting(nil) }

        let user = AgentMCPServerConfig(name: "x", source: .user, transport: .stdio, command: "/bin/echo")
        let fromUser = await AgentMCPHostRequests.respond(
            to: ["id": "h1", "method": AgentMCPHostRequests.imageGenerateMethod, "params": ["prompt": "a cat"]], server: user
        )
        #expect((fromUser["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.methodNotFound)

        let unknown = await AgentMCPHostRequests.respond(to: ["id": "h2", "method": "willdeep/nope"], server: pluginServer())
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.methodNotFound)
        #expect(unknown["id"] as? String == "h2", "错误响应要带回原 id，否则服务端会一直等")

        let emptyPrompt = await AgentMCPHostRequests.respond(
            to: ["id": "h3", "method": AgentMCPHostRequests.imageGenerateMethod, "params": ["prompt": "  "]], server: pluginServer()
        )
        #expect((emptyPrompt["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.invalidParams)

        let badModel = await AgentMCPHostRequests.respond(
            to: ["id": "h4", "method": AgentMCPHostRequests.imageGenerateMethod, "params": ["prompt": "a cat", "model": "dall-e-9"]], server: pluginServer()
        )
        #expect((badModel["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.invalidParams)
    }

    @Test("出图失败把原因带回服务端")
    func generatorFailureIsReported() async {
        AgentMCPHostRequests.setImageGeneratorForTesting { _, _ in throw AgentPluginAIError.imagePermissionDenied }
        defer { AgentMCPHostRequests.setImageGeneratorForTesting(nil) }
        let response = await AgentMCPHostRequests.respond(
            to: ["id": "h5", "method": AgentMCPHostRequests.imageGenerateMethod, "params": ["prompt": "a cat"]], server: pluginServer()
        )
        let error = response["error"] as? [String: Any]
        #expect(error?["code"] as? Int == AgentMCPHostRequests.ErrorCode.failed)
        #expect((error?["message"] as? String)?.contains("ai.image") == true)
    }

    @Test("问模型：与页面桥同一个校验器，附图路径原样交给实现，结果带回模型名")
    func aiCompleteUsesPageValidatorAndReturnsText() async {
        let seen = RequestRecorder()
        AgentMCPHostRequests.setAICompleterForTesting { pluginID, request in
            seen.record(pluginID: pluginID, request: request)
            return AgentPluginAIResult(text: "```short_drama_review\n{}\n```", model: "qwen3.8-max", providerID: "dashscope")
        }
        defer { AgentMCPHostRequests.setAICompleterForTesting(nil) }

        let response = await AgentMCPHostRequests.respond(
            to: ["id": "a1", "method": AgentMCPHostRequests.aiCompleteMethod, "params": [
                "system": "你是审核员",
                "provider": "dashscope", "model": "qwen3.8-max",
                "messages": [["role": "user", "content": "审这张图", "imagePaths": ["/tmp/x/a.png"]]],
            ]],
            server: pluginServer()
        )
        let result = response["result"] as? [String: Any]
        #expect(result?["model"] as? String == "qwen3.8-max")
        #expect((result?["text"] as? String)?.contains("short_drama_review") == true)
        #expect(result?["toolCalls"] as? [Any] != nil, "toolCalls 恒在，空数组表示用正文回答")
        let request = seen.last()
        #expect(request?.pluginID == "willdeep-video-studio")
        #expect(request?.messages.first?.role == .system)
        #expect(request?.messages.last?.imagePaths == ["/tmp/x/a.png"], "路径钳制在实现里做，这里不能先丢掉")
    }

    @Test("问模型：空请求回 -32602，模型失败回 -32000 并带原因")
    func aiCompleteRejectsAndReportsFailures() async {
        AgentMCPHostRequests.setAICompleterForTesting { _, _ in throw AgentPluginAIError.permissionDenied }
        defer { AgentMCPHostRequests.setAICompleterForTesting(nil) }

        let empty = await AgentMCPHostRequests.respond(
            to: ["id": "a2", "method": AgentMCPHostRequests.aiCompleteMethod, "params": ["messages": []]], server: pluginServer()
        )
        #expect((empty["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.invalidParams)

        let denied = await AgentMCPHostRequests.respond(
            to: ["id": "a3", "method": AgentMCPHostRequests.aiCompleteMethod, "params": ["messages": [["role": "user", "content": "hi"]]]],
            server: pluginServer()
        )
        let error = denied["error"] as? [String: Any]
        #expect(error?["code"] as? Int == AgentMCPHostRequests.ErrorCode.failed)
        #expect((error?["message"] as? String)?.isEmpty == false)

        let user = AgentMCPServerConfig(name: "x", source: .user, transport: .stdio, command: "/bin/echo")
        let fromUser = await AgentMCPHostRequests.respond(
            to: ["id": "a4", "method": AgentMCPHostRequests.aiCompleteMethod, "params": ["messages": [["role": "user", "content": "hi"]]]],
            server: user
        )
        #expect((fromUser["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.methodNotFound)
    }

    private final class RequestRecorder: @unchecked Sendable {
        struct Seen { let pluginID: String; let messages: [AgentPluginAIMessage] }
        private let lock = NSLock()
        private var value: Seen?
        func record(pluginID: String, request: AgentPluginAIRequest) {
            lock.lock(); value = Seen(pluginID: pluginID, messages: request.messages); lock.unlock()
        }
        func last() -> Seen? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("端到端：工具调用期间反向出图，宿主干活的时间不算服务端超时")
    func stdioServerCanRequestImagesMidToolCall() async throws {
        let calls = CallRecorder()
        AgentMCPHostRequests.setImageGeneratorForTesting { pluginID, request in
            calls.record(pluginID: pluginID, request: request)
            // 比服务端超时（1 秒）长：等待循环若不在处理完后重新计时，这里必然超时。
            try await Task.sleep(nanoseconds: 2_500_000_000)
            return self.fakeImage(pluginID, request)
        }
        defer { AgentMCPHostRequests.setImageGeneratorForTesting(nil) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-host-requests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.rb")
        try Self.fakeServerScript.write(to: script, atomically: true, encoding: .utf8)

        let server = pluginServer(args: [script.path], timeout: 1)
        defer { AgentMCPBridge.invalidatePluginConnections(pluginID: "willdeep-video-studio") }

        let raw = try await AgentMCPBridge.requestForTesting(
            server: server, method: "tools/call",
            params: ["name": "draw", "arguments": ["prompt": "a red lantern", "model": "nano-banana-2", "size": "1024x1536"]]
        )
        let result = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])

        let host = try #require(result["host"] as? [String: Any])
        #expect(host["id"] as? String == "host-1")
        let image = try #require(host["result"] as? [String: Any], "应当拿到出图结果而不是错误：\(host)")
        #expect(image["filePath"] as? String == "/tmp/willdeep-video-studio/fake.png")
        #expect(image["model"] as? String == "nano-banana-2")

        let advertised = result["advertised"] as? [String]
        #expect(advertised == AgentMCPHostRequests.supportedMethods, "插件在 initialize 里就能看到宿主支持出图")
        #expect(calls.all().map(\.pluginID) == ["willdeep-video-studio"])
        #expect(calls.all().first?.prompt == "a red lantern")
    }

    @Test("反向请求超过处理上限回 -32001，不等实现办完")
    func reverseRequestGivesUpAfterLimit() async {
        AgentMCPHostRequests.setImageGeneratorForTesting { pluginID, request in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return self.fakeImage(pluginID, request)
        }
        defer { AgentMCPHostRequests.setImageGeneratorForTesting(nil) }

        let clock = ContinuousClock()
        let begin = clock.now
        let response = await AgentMCPHostRequests.respond(
            to: ["id": "slow-1", "method": AgentMCPHostRequests.imageGenerateMethod, "params": ["prompt": "a cat"]],
            server: pluginServer(),
            within: 0.3
        )
        #expect(clock.now - begin < .seconds(3), "到上限就该交回，不能等出图的 5 秒")
        #expect((response["error"] as? [String: Any])?["code"] as? Int == AgentMCPHostRequests.ErrorCode.timedOut)
        #expect(response["id"] as? String == "slow-1")
    }

    /// 2026-09-27 短剧工坊：外部客户端经网关调 `image.generate`，插件从 HTTP 入口的
    /// 工作线程发反向请求出图；宿主此时没在等 stdio 应答，原来就在读 stdout 的线程上
    /// 同步办这张图。其间网关探活的 `tools/list` 应答读不进来，超时后插件被结束，
    /// 那张图也断了。
    @Test("回归：宿主替插件出图期间，插件对别的请求的应答照常送达，进程不被结束")
    func otherResponsesFlowWhileHostHandlesReverseRequest() async throws {
        let generation = GenerationProbe()
        AgentMCPHostRequests.setImageGeneratorForTesting { pluginID, request in
            generation.markStarted()
            // 比服务端超时（2 秒）长：探活的应答若要等出图办完，必然先超时。
            try await Task.sleep(nanoseconds: 4_000_000_000)
            generation.markFinished()
            return self.fakeImage(pluginID, request)
        }
        defer { AgentMCPHostRequests.setImageGeneratorForTesting(nil) }

        let script = try Self.writeScript(Self.threadedServerScript)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let server = pluginServer(args: [script.path], timeout: 2)
        defer { AgentMCPBridge.invalidatePluginConnections(pluginID: "willdeep-video-studio") }

        let kickoff = try await Self.request(server, "tools/call", ["name": "draw_in_background"])
        #expect(kickoff["started"] as? Bool == true)
        try await Self.waitUntil("宿主开始替插件出图") { generation.started }

        // 网关探活：这时宿主还在替插件出图。
        let listed = try await Self.request(server, "tools/list", [:])
        #expect(!generation.finished, "应答要在出图办完之前送达，不能被堵在读 stdout 的线程后面")
        let pid = try #require(listed["pid"] as? Int)

        // 出图办完后插件拿到了答复，并且还是同一个进程。
        var reply: [String: Any]?
        let deadline = Date().addingTimeInterval(15)
        while reply == nil, Date() < deadline {
            let probe = try await Self.request(server, "tools/call", ["name": "host_reply"])
            #expect(probe["pid"] as? Int == pid, "插件进程被换掉了：宿主结束了正在等出图的插件")
            reply = probe["host"] as? [String: Any]
            if reply == nil { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        let host = try #require(reply, "插件没收到出图的答复")
        let image = try #require(host["result"] as? [String: Any], "应当拿到出图结果而不是错误：\(host)")
        #expect(image["filePath"] as? String == "/tmp/willdeep-video-studio/fake.png")
    }

    @Test("插件回 JSON-RPC 错误不重启进程")
    func errorResponseKeepsProcessAlive() async throws {
        let script = try Self.writeScript(Self.threadedServerScript)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let server = pluginServer(args: [script.path], timeout: 2)
        defer { AgentMCPBridge.invalidatePluginConnections(pluginID: "willdeep-video-studio") }

        let before = try #require(try await Self.request(server, "tools/list", [:])["pid"] as? Int)
        await #expect(throws: AgentToolError.self) {
            _ = try await Self.request(server, "tools/call", ["name": "no_such_tool"])
        }
        let after = try #require(try await Self.request(server, "tools/list", [:])["pid"] as? Int)
        #expect(after == before, "服务端好好地回了错误，连接没坏，不该重启它")
    }

    @Test("网关探活：连接活着就不再发 tools/list，不排在忙着的请求后面")
    func gatewayProbeSkipsLiveConnection() async throws {
        let generation = GenerationProbe()
        AgentMCPHostRequests.setImageGeneratorForTesting { pluginID, request in
            generation.markStarted()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            generation.markFinished()
            return self.fakeImage(pluginID, request)
        }
        defer { AgentMCPHostRequests.setImageGeneratorForTesting(nil) }

        let script = try Self.writeScript(Self.fakeServerScript)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let server = pluginServer(args: [script.path], timeout: 1)
        defer { AgentMCPBridge.invalidatePluginConnections(pluginID: "willdeep-video-studio") }

        #expect(try await AgentMCPBridge.ensureStartedForGatewayForTesting(server: server), "没在运行时要探，顺带拉起")
        #expect(try await !AgentMCPBridge.ensureStartedForGatewayForTesting(server: server), "已经活着就不再探")

        // 一条经 stdio 的工具调用在等宿主出图，连接的串行队列被它占着。
        let drawing = Task {
            try await AgentMCPBridge.requestForTesting(
                server: server, method: "tools/call",
                params: ["name": "draw", "arguments": ["prompt": "a red lantern"]]
            )
        }
        try await Self.waitUntil("宿主开始替插件出图") { generation.started }
        #expect(try await !AgentMCPBridge.ensureStartedForGatewayForTesting(server: server))
        #expect(!generation.finished, "探活不能排在出图的工具调用后面干等")

        let raw = try await drawing.value
        let result = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect((result["host"] as? [String: Any])?["result"] != nil, "那张图照常办完：\(result)")

        // 连接被回收之后，下一次探活要重新拉起。
        await AgentMCPBridge.invalidatePluginConnections(pluginID: "willdeep-video-studio")
        #expect(try await AgentMCPBridge.ensureStartedForGatewayForTesting(server: server))
    }

    private static func writeScript(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-host-requests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.rb")
        try source.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private static func request(
        _ server: AgentMCPServerConfig,
        _ method: String,
        _ params: [String: Any]
    ) async throws -> [String: Any] {
        let raw = try await AgentMCPBridge.requestForTesting(server: server, method: method, params: params)
        return try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private static func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw WaitTimedOut(what: what, seconds: timeout)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private struct WaitTimedOut: Error, CustomStringConvertible {
        let what: String
        let seconds: TimeInterval
        var description: String { "等了 \(Int(seconds)) 秒仍未满足：\(what)" }
    }

    private final class GenerationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var didStart = false
        private var didFinish = false
        func markStarted() { lock.lock(); didStart = true; lock.unlock() }
        func markFinished() { lock.lock(); didFinish = true; lock.unlock() }
        var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }
    }

    private final class CallRecorder: @unchecked Sendable {
        struct Call { let pluginID: String; let prompt: String }
        private let lock = NSLock()
        private var calls: [Call] = []
        func record(pluginID: String, request: AgentPluginImageRequest) {
            lock.lock(); calls.append(Call(pluginID: pluginID, prompt: request.prompt)); lock.unlock()
        }
        func all() -> [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    /// 最小的插件 MCP 服务：initialize 时记下宿主宣告的能力；tools/call 时先向
    /// 宿主发一条出图请求，读到响应后再把它连同宣告的能力一起作为工具结果交回。
    /// 刻意用 macOS 自带 ruby 2.6 能跑的写法。
    private static let fakeServerScript = #"""
    require "json"
    $stdout.sync = true
    advertised = nil
    while (line = $stdin.gets)
      message = JSON.parse(line) rescue next
      next unless message["id"]
      case message["method"]
      when "initialize"
        extensions = (message.dig("params", "capabilities", "extensions") || {})
        advertised = (extensions["io.willdeep/host-requests"] || {})["methods"]
        puts JSON.generate("jsonrpc" => "2.0", "id" => message["id"], "result" => { "capabilities" => {} })
      when "tools/call"
        arguments = message.dig("params", "arguments") || {}
        puts JSON.generate("jsonrpc" => "2.0", "id" => "host-1", "method" => "willdeep/images/generate", "params" => arguments)
        host = nil
        while (reply = $stdin.gets)
          parsed = JSON.parse(reply) rescue next
          if parsed["id"] == "host-1"
            host = parsed
            break
          end
        end
        puts JSON.generate("jsonrpc" => "2.0", "id" => message["id"], "result" => { "host" => host, "advertised" => advertised })
      else
        puts JSON.generate("jsonrpc" => "2.0", "id" => message["id"], "result" => {})
      end
    end
    """#

    /// 照短剧工坊 0.30.0-rc2 的线程模型：stdio 请求在主循环里即时应答，出图在
    /// 工作线程里等宿主（插件 HTTP 入口来的请求就是这样）。
    /// - `draw_in_background`：立刻回 `started`，稍后由工作线程发出图请求 `bg-1`。
    ///   先回再发，是为了让出图请求到达时宿主正闲着——事故现场就是这个时序。
    /// - `host_reply`：交回目前收到的 `bg-1` 答复（还没有就是 null）和进程号。
    /// - 其他工具回 JSON-RPC 错误；`tools/list` 等其他方法回进程号。
    private static let threadedServerScript = #"""
    require "json"
    $stdout.sync = true
    OUT = Mutex.new
    def emit(object)
      OUT.synchronize { $stdout.puts(JSON.generate(object)) }
    end
    host_reply = nil
    while (line = $stdin.gets)
      message = JSON.parse(line) rescue next
      unless message["method"]
        host_reply = message if message["id"] == "bg-1"
        next
      end
      next unless message["id"]
      case message["method"]
      when "initialize"
        emit("jsonrpc" => "2.0", "id" => message["id"], "result" => { "capabilities" => {} })
      when "tools/call"
        case message.dig("params", "name")
        when "draw_in_background"
          emit("jsonrpc" => "2.0", "id" => message["id"], "result" => { "started" => true })
          Thread.new do
            sleep 0.3
            emit("jsonrpc" => "2.0", "id" => "bg-1", "method" => "willdeep/images/generate",
                 "params" => { "prompt" => "a paper lantern" })
          end
        when "host_reply"
          emit("jsonrpc" => "2.0", "id" => message["id"], "result" => { "host" => host_reply, "pid" => Process.pid })
        else
          emit("jsonrpc" => "2.0", "id" => message["id"], "error" => { "code" => -32602, "message" => "Unknown tool" })
        end
      else
        emit("jsonrpc" => "2.0", "id" => message["id"], "result" => { "tools" => [], "pid" => Process.pid })
      end
    end
    """#
}
