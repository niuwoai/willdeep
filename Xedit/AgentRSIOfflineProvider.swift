import Foundation

/// In-process transport fixture. It can never forward a request to the
/// network; even an unexpected URL fails locally. The second response is
/// conditional on the real read_file result containing the fixture token.
nonisolated final class AgentRSIOfflineProvider: URLProtocol, @unchecked Sendable {
    static let host = "agent-rsi.invalid"
    static let token = "RSI_FIXTURE_EVIDENCE_V1"
    static let report = "Verified fixture.txt: RSI_FIXTURE_EVIDENCE_V1. Reproduction: read fixture.txt."
    private static let lock = NSLock()
    private nonisolated(unsafe) static var traces: [String: AgentExecutionTrace] = [:]
    @TaskLocal static var injectedTransportHost: String?
    static func register(host: String, trace: AgentExecutionTrace) { lock.lock(); defer { lock.unlock() }; traces[host] = trace }
    static func unregister(host: String) { lock.lock(); defer { lock.unlock() }; traces.removeValue(forKey: host) }
    private static func trace(host: String?) -> AgentExecutionTrace? {
        lock.lock(); defer { lock.unlock() }; return host.flatMap { traces[$0] }
    }
    static func transportProvider(configuration: AgentConfiguration) -> String {
        // Configuration normalizes unknown preset names to `custom`. The
        // actual transport is still this registered in-process mock, not a
        // paid custom endpoint. Never alter ordinary provider configuration.
        let host = URL(string: configuration.baseURL)?.host
        return host == injectedTransportHost && host != nil && trace(host: host) != nil ? "mock" : configuration.providerID
    }
    @MainActor static func withTransport<T>(session: URLSession, host: String,
        operation: () async throws -> T) async throws -> T {
        guard session.configuration.protocolClasses?.contains(where: { $0 == AgentRSIOfflineProvider.self }) == true,
              trace(host: host) != nil else { throw AgentRSIError.paidNotApproved }
        return try await $injectedTransportHost.withValue(host, operation: operation)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let trace = Self.trace(host: request.url?.host) else { throw AgentRSIError.paidNotApproved }
            var parser = AgentCanonicalJSON.Parser(data: try body(), allowNumbers: true)
            let object = try parser.parse()
            let messages = object["messages"].elements
            let observed = messages.last { $0["role"].text == "tool" && ($0["content"].text?.contains(Self.token) ?? false) }
            let read = observed != nil
            if let text = observed?["content"].text {
                trace.record("fixture_tool_result_observed") { $0.promptSHA256 = AgentPackageV1.hash(Data(text.utf8)) }
            }
            let delta: AgentCanonicalJSON = read ? .object(["content": .string(Self.report)]) : .object([
                "tool_calls": .array([.object(["index": .integer(0), "id": .string("fixture-read"), "type": .string("function"),
                    "function": .object(["name": .string("read_file"), "arguments": .string("{\"path\":\"fixture.txt\"}")])])])])
            let chunk = AgentCanonicalJSON.object(["choices": .array([.object(["delta": delta,
                "finish_reason": .string(read ? "stop" : "tool_calls")])]),
                "usage": .object(["prompt_tokens": .integer(100), "completion_tokens": .integer(20), "total_tokens": .integer(120)])])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream", "X-Request-ID": "offline-" + UUID().uuidString])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(("data: " + chunk.canonical + "\n\ndata: [DONE]\n\n").utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    private func body() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw AgentRSIError.invalidContract }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw AgentRSIError.invalidContract }; if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
