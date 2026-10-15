import Foundation

/// Public fixture transport only. Every URL is intercepted; unknown hosts
/// fail locally. No method forwards, redirects, retries or opens a socket.
nonisolated final class AgentRSIFreeReviewProvider: URLProtocol, @unchecked Sendable {
    final class Context: @unchecked Sendable {
        let fixture: String, report: String, instructions: String, trace: AgentExecutionTrace
        var requestBodies: [Data] = []
        var observedToolHashes = Set<String>()
        init(fixture: String, report: String, instructions: String, trace: AgentExecutionTrace) {
            self.fixture = fixture; self.report = report; self.instructions = instructions; self.trace = trace
        }
    }
    private static let lock = NSRecursiveLock()
    private nonisolated(unsafe) static var contexts: [String: Context] = [:]
    static func register(host: String, context: Context) { lock.lock(); defer { lock.unlock() }; contexts[host] = context }
    static func unregister(host: String) { lock.lock(); defer { lock.unlock() }; contexts.removeValue(forKey: host) }
    static func snapshot(host: String) -> (bodies: [Data], observed: Set<String>) {
        lock.lock(); defer { lock.unlock() }; return (contexts[host]?.requestBodies ?? [], contexts[host]?.observedToolHashes ?? [])
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            Self.lock.lock(); defer { Self.lock.unlock() }
            guard let host = request.url?.host, let context = Self.contexts[host],
                  request.url?.path == "/v1/chat/completions" else { throw AgentRSIError.paidNotApproved }
            let data = try body()
            guard data.count <= 256 * 1024 else { throw AgentRSIError.invalidContract }
            var parser = AgentCanonicalJSON.Parser(data: data, allowNumbers: true)
            let object = try parser.parse()
            context.requestBodies.append(data)
            guard context.requestBodies.count <= 4 else { throw AgentRSIError.quota }
            let messages = object["messages"].elements
            guard messages.contains(where: { $0["content"].text?.contains(context.instructions) == true }) else { throw AgentRSIError.missingEvidence }
            let lines = context.fixture.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let observed = messages.last { message in
                guard message["role"].text == "tool", let text = message["content"].text else { return false }
                return lines.allSatisfy { text.contains($0) }
            }
            if let text = observed?["content"].text { context.observedToolHashes.insert(AgentPackageV1.hash(Data(text.utf8))) }
            let read = observed != nil
            let delta: AgentCanonicalJSON = read ? .object(["content": .string(context.report)]) : .object([
                "tool_calls": .array([.object(["index": .integer(0), "id": .string("free-fixture-read"), "type": .string("function"),
                    "function": .object(["name": .string("read_file"), "arguments": .string("{\"path\":\"fixture.txt\"}")])])])])
            let chunk = AgentCanonicalJSON.object(["choices": .array([.object(["delta": delta, "finish_reason": .string(read ? "stop" : "tool_calls")])]),
                "usage": .object(["prompt_tokens": .integer(100), "completion_tokens": .integer(20), "total_tokens": .integer(120)])])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream", "X-Request-ID": "free-mock-" + UUID().uuidString])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(("data: " + chunk.canonical + "\n\ndata: [DONE]\n\n").utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func body() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw AgentRSIError.invalidContract }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw AgentRSIError.invalidContract }
            if count == 0 { break }; data.append(bytes, count: count)
        }
        return data
    }
}
