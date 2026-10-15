import Foundation

nonisolated struct AgentRSIApprovedPreviewComplete: Error {}
/// The capability is issued by the host budget broker for one active trial.
/// A local JSON "approved" flag is never an authorization mechanism.
@MainActor final class AgentRSIApprovedBroker {
    nonisolated static let proposalSHA256 = "a3ae36e96d268f8aaab8a02efacea61cb68f58c1d3bf812b9a38311890736606"
    nonisolated static let model = "deepseek-v4-flash"
    @TaskLocal static var current: AgentRSIApprovedBroker?
    let origin: URL
    let trialID: String
    private let capability: String
    private let session: URLSession
    private var sequence = 0
    private let previewOnly: Bool
    private(set) var firstRequest: Data?
    private(set) var receipts: [AgentCanonicalJSON] = []
    private(set) var observedToolPayloads = Set<String>()
    func close() { session.invalidateAndCancel() }
    init(origin: String, capability: String, trialID: String, session: URLSession? = nil, previewOnly: Bool = false) throws {
        guard var parts = URLComponents(string: origin), parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              !capability.isEmpty, !trialID.isEmpty else { throw AgentRSIError.paidNotApproved }
        parts.path = ""
        guard let url = parts.url else { throw AgentRSIError.paidNotApproved }
        self.origin = url; self.capability = capability; self.trialID = trialID
        self.previewOnly = previewOnly
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: configuration, delegate: AgentRegistryRedirectPolicy(), delegateQueue: nil)
    }
    func configuration() -> AgentConfiguration {
        AgentConfiguration(providerID: "custom", baseURL: origin.absoluteString + "/v1", model: Self.model,
                           routingMode: .flash, apiKey: capability, customKindOverride: .openAIChat)
    }
    func preview(messages: [AgentMessage], tools: [AgentToolDescriptor]) throws -> Data {
        let encoded = try OpenAIChatAdapter.encodeChatRequest(model: Self.model, messages: messages, tools: tools, supportsImages: false)
        guard var body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw AgentRSIError.invalidContract }
        body["stream"] = false; body.removeValue(forKey: "stream_options")
        body["temperature"] = 0; body["max_tokens"] = 4000
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func run(configuration: AgentConfiguration, messages: [AgentMessage], tools: [AgentToolDescriptor],
             ledger: AgentModelRequestLedger?, ownerGate: AgentRequestOwnerGate?,
             onEvent: @escaping @Sendable (AgentClientEvent) async -> Void) async throws {
        guard configuration.providerID == "custom", configuration.model == Self.model,
              configuration.baseURL == self.configuration().baseURL, sequence < 4 else { throw AgentRSIError.paidNotApproved }
        sequence += 1
        var request = URLRequest(url: origin.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.httpBody = try preview(messages: messages, tools: tools)
        request.timeoutInterval = 120
        request.setValue("Bearer " + capability, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trialID, forHTTPHeaderField: "X-RSI-Trial-Id")
        request.setValue(String(sequence), forHTTPHeaderField: "X-RSI-Request-Sequence")
        request.setValue(Self.proposalSHA256, forHTTPHeaderField: "X-RSI-Proposal-Sha256")
        if firstRequest == nil { firstRequest = request.httpBody }
        if previewOnly { throw AgentRSIApprovedPreviewComplete() }
        try await AgentModelRequestAccounting.run(ledger: ledger, configuration: configuration, request: request,
            format: .compatibleChat, ownerGate: ownerGate, onEvent: onEvent) { prepared, consume in
            let (data, response) = try await session.data(for: prepared)
            guard let http = response as? HTTPURLResponse, http.url == request.url,
                  (200...299).contains(http.statusCode), data.count <= 2 * 1024 * 1024 else { throw AgentAssetError.server }
            let routed = http.value(forHTTPHeaderField: "X-Routed-Model")
            let identifier = http.value(forHTTPHeaderField: "X-Request-Id")
            let receipt = http.value(forHTTPHeaderField: "X-RSI-Receipt-Id")
            let approved = http.value(forHTTPHeaderField: "X-RSI-Approved-Model")
            guard approved == Self.model, let routed, !routed.isEmpty,
                  let identifier, !identifier.isEmpty, let receipt, !receipt.isEmpty else { throw AgentRSIError.missingEvidence }
            AgentExecutionTrace.current?.record("broker_receipt") {
                $0.requestID = AgentExecutionTrace.physicalRequestID; $0.providerRequestID = identifier
                $0.provider = "some-im"; $0.model = routed; $0.status = receipt
            }
            await consume(.requestIdentified(identifier))
            let result = try JSONDecoder().decode(Response.self, from: data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let usageBytes = try JSONSerialization.data(withJSONObject: object?["usage"] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
            receipts.append(.object(["request_id": .string(identifier), "receipt_id": .string(receipt),
                "response_id": .string(result.id), "routed_model": .string(routed), "body_model": .string(result.model),
                "usage": try AgentRSIContract.raw(usageBytes), "response_sha256": .string(AgentPackageV1.hash(data))]))
            guard !result.model.isEmpty, result.choices.count == 1,
                  let usage = result.usage, (0...16000).contains(usage.prompt_tokens), (0...4000).contains(usage.completion_tokens),
                  (0...16000).contains(usage.total_tokens),
                  usage.total_tokens == usage.prompt_tokens + usage.completion_tokens else { throw AgentRSIError.missingEvidence }
            for message in messages where message.role == .tool {
                observedToolPayloads.insert(AgentPackageV1.hash(Data(message.content.utf8)))
            }
            AgentExecutionTrace.current?.record("provider_response") {
                $0.requestID = AgentExecutionTrace.physicalRequestID; $0.providerRequestID = result.id
                $0.provider = "some-im"; $0.model = result.model
            }
            await consume(.usageReported(prompt: usage.prompt_tokens, completion: usage.completion_tokens, total: usage.total_tokens,
                cachedPrompt: nil, cacheWritePrompt: nil, reasoning: usage.completion_tokens_details?.reasoning_tokens ?? 0))
            let choice = result.choices[0]
            if let content = choice.message.content, !content.isEmpty { await consume(.textDelta(content)) }
            let calls = choice.message.tool_calls ?? []
            if !calls.isEmpty {
                await consume(.toolCallsUpdated(calls.map { .init(externalID: $0.id, toolName: $0.function.name, argumentsJSON: $0.function.arguments) }))
            }
            guard !(choice.message.content ?? "").isEmpty || !calls.isEmpty else { throw AgentRSIError.missingEvidence }
            await consume(.finishedTurn(choice.finish_reason))
        }
    }
    private struct Response: Decodable {
        let id: String
        let model: String
        let choices: [Choice]
        let usage: Usage?
        struct Choice: Decodable { let message: Message; let finish_reason: String? }
        struct Message: Decodable { let content: String?; let tool_calls: [Call]? }
        struct Call: Decodable { let id: String; let function: Function }
        struct Function: Decodable { let name: String; let arguments: String }
        struct Usage: Decodable {
            let prompt_tokens: Int; let completion_tokens: Int; let total_tokens: Int
            let completion_tokens_details: Details?
        }
        struct Details: Decodable { let reasoning_tokens: Int? }
    }
}
