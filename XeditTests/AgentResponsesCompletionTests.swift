import Foundation
import Testing
@testable import WillDeep

@MainActor
// 看门狗从 30s 放到 120s（见下），suite 时限必须跟着放，否则时限成了新的
// 假红来源；6 个参数化用例共享这一份预算。
@Suite("Responses 完成事件与连接生命周期", .serialized, .timeLimit(.minutes(5)))
struct AgentResponsesCompletionTests {
    private actor Events {
        var text = ""
        var finishes: [String?] = []
        var tokens = 0
        func record(_ event: AgentClientEvent) {
            switch event {
            case .textDelta(let delta): text += delta
            case .finishedTurn(let reason): finishes.append(reason)
            case .usageReported(_, _, let total, _, _, _): tokens = total
            default: break
            }
        }
    }

    private enum Failure: Error { case waitedForSocketEOF }

    @Test("完成、不完整与失败事件立即结束请求，即使服务端仍保持连接",
          arguments: ["response.completed", "response.incomplete", "response.failed"], [true, false])
    func terminalEventEndsOpenConnection(terminal: String, eventHeader: Bool) async throws {
        let id = UUID().uuidString
        func event(_ name: String, body: String) -> String {
            (eventHeader ? "event: \(name)\n" : "") + "data:{\"type\":\"\(name)\",\(body)}\n\n"
        }
        let status = String(terminal.dropFirst("response.".count))
        let payload = event("response.output_text.delta", body: #""delta":"已返回的内容""#)
            + event(terminal, body: #""response":{"id":"fixture-response","status":"\#(status)","output":[],"usage":{"input_tokens":20,"output_tokens":22,"total_tokens":42},"error":{"message":"fixture failure"}}"#)
            + event("response.output_text.delta", body: #""delta":"完成之后不能继续追加""#)
        OpenResponsesProtocol.install(id: id, data: Data(payload.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenResponsesProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Completion-Fixture": id]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            OpenResponsesProtocol.remove(id: id)
        }
        let adapter = OpenAIResponsesAdapter(configuration: .init(providerID: "openai",
            baseURL: "https://responses-completion.invalid/v1", model: "fixture", apiKey: "test-placeholder"), session: session)
        let events = Events()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { @MainActor in
                try await adapter.streamChat(messages: [.init(role: .user, content: "fixture")]) {
                    await events.record($0)
                }
            }
            group.addTask {
                // Full-suite MainActor contention can delay request admission.
                // 30s 仍被击穿过（实测这条报 waitedForSocketEOF）：这个 suite
                // 是 @MainActor，而 adapter 的 streamChat 也要 MainActor，全量
                // 并行跑时一堆 @MainActor suite 抢同一个执行器。放到 120s。
                // 这仍远低于原来那个 180 秒的空转等待，而桩刻意永不发 EOF，
                // 所以能过就只能是语义收尾走通了——判据没有被削弱。
                try await Task.sleep(for: .seconds(120))
                throw Failure.waitedForSocketEOF
            }
            try await group.next()
        }
        #expect(await events.text == "已返回的内容")
        #expect(await events.finishes.count == 1)
        if terminal != "response.failed" { #expect(await events.tokens == 42) }
        // 同一个理由：观察 stopLoading 落地的窗口也只有 1 秒，同样会被主执行器
        // 饥饿击穿。判据是「收尾时取消了连接」，和快慢无关。
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !OpenResponsesProtocol.wasStopped(id: id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(OpenResponsesProtocol.wasStopped(id: id))
    }
}

/// Delivers a complete response but deliberately never sends HTTP EOF. The
/// adapter must finish on the protocol event rather than wait for the socket.
private final class OpenResponsesProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payloads: [String: Data] = [:]
    nonisolated(unsafe) private static var stopped: Set<String> = []

    static func install(id: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        payloads[id] = data
    }

    static func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        payloads[id] = nil
        stopped.remove(id)
    }

    static func wasStopped(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped.contains(id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let payload = request.value(forHTTPHeaderField: "X-Completion-Fixture").flatMap { Self.payloads[$0] }
        Self.lock.unlock()
        guard let payload, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
    }

    override func stopLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Completion-Fixture") else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stopped.insert(id)
    }
}
