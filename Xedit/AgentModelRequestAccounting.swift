import Foundation
import CoreFoundation

/// Wrap the transport AND stream consumption, not only the receipt of headers.
/// Each retry must call this again; cumulative logical-retry usage is reported
/// outside this boundary and must not be booked a second time.
@MainActor
enum AgentModelRequestAccounting {
    static func run<T>(ledger: AgentModelRequestLedger?, configuration: AgentConfiguration,
                       requestBody: Data? = nil,
                       onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
                       operation: (@escaping @Sendable (AgentClientEvent) async -> Void) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard let ledger else { return try await operation(onEvent) }
        let id = UUID()
        let providerID = configuration.providerID
        let modelID = configuration.model
        // No actor-blocking file I/O. These detached tasks only persist local
        // receipts; they never start or retry a provider operation after Stop.
        try await Task.detached {
            let reservation = AgentModelRequestReservation.tokens(for: requestBody)
            try ledger.begin(id: id, providerID: providerID, modelID: modelID, reservedTokens: reservation)
        }.value
        return try await collectAndFinish(id: id, ledger: ledger, onEvent: onEvent, operation: operation)
    }

    /// Production adapters must send the returned request, not their original
    /// encoding. Each internal fallback/retry receives a fresh reservation.
    static func run<T>(ledger: AgentModelRequestLedger?, configuration: AgentConfiguration,
                       request: URLRequest, format: AgentModelRequestFormat,
                       safelyQuantifiableInput: Bool = true,
                       ownerGate: AgentRequestOwnerGate? = nil,
                       onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
                       operation: (URLRequest, @escaping @Sendable (AgentClientEvent) async -> Void) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try ownerGate?.check()
        guard let ledger else { return try await operation(request, onEvent) }
        guard let body = request.httpBody else { throw AgentModelRequestLedger.Failure.unknownExposure }
        let id = UUID(), providerID = configuration.providerID, modelID = configuration.model
        let preparedBody = try await Task.detached {
            try ledger.admit(id: id, providerID: providerID, modelID: modelID) { remaining in
                if !safelyQuantifiableInput, remaining != nil { throw AgentModelRequestLedger.Failure.unknownExposure }
                let prepared = try AgentModelRequestReservation.prepare(body, format: format, remaining: remaining)
                return (prepared.body, safelyQuantifiableInput ? prepared.tokens : nil)
            }
        }.value
        var preparedRequest = request
        preparedRequest.httpBody = preparedBody
        return try await collectAndFinish(id: id, ledger: ledger, onEvent: onEvent) { consume in
            try ownerGate?.check()
            return try await operation(preparedRequest, consume)
        }
    }

    private static func collectAndFinish<T>(id: UUID, ledger: AgentModelRequestLedger,
                       onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
                       operation: (@escaping @Sendable (AgentClientEvent) async -> Void) async throws -> T) async throws -> T {
        let collector = UsageCollector()
        let result: Result<T, Error>
        do {
            try Task.checkCancellation()
            let value = try await operation { event in
                await collector.consume(event)
                await onEvent(event)
            }
            try Task.checkCancellation()
            result = .success(value)
        } catch { result = .failure(error) }
        let outcome: AgentModelRequestLedger.Outcome
        switch result {
        case .success: outcome = .succeeded
        case .failure(let error): outcome = (error is CancellationError || Task.isCancelled) ? .cancelled : .failed
        }
        let receipt = await AgentModelRequestLedger.Receipt(outcome: outcome, usage: collector.usage)
        // Finalization is awaited even after cancellation. If it fails the
        // prepared row remains uncertain; never infer zero cost or auto-replay.
        try await Task.detached { try ledger.finish(id: id, receipt: receipt) }.value
        return try result.get()
    }

    private actor UsageCollector {
        var usage: AgentModelRequestLedger.Usage?
        func consume(_ event: AgentClientEvent) {
            guard case .usageReported(let prompt, let completion, let total, let cached, let cacheWrite, let reasoning) = event else { return }
            let value = AgentModelRequestLedger.Usage(prompt: prompt, completion: completion, total: total,
                cachedPrompt: cached, cacheWritePrompt: cacheWrite, reasoning: reasoning)
            // Adapters emit cumulative usage within one physical response.
            // Repeated cumulative events replace, rather than sum, that usage.
            usage = value.isValid ? value : nil
        }
    }
}

/// An estimate for admission, NOT a tokenizer or an exact billing ceiling.
/// Never guess hidden history, media or hosted-tool consumption. Missing an
/// actual provider output bound also leaves exposure unquantified. Only the
/// estimate is persisted; the request body (and credentials) is never stored.
nonisolated enum AgentModelRequestReservation {
    static let inputTemplateAllowance = 4_096

    static func tokens(for body: Data?) -> Int? {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              !hasUnquantifiedInput(object) else { return nil }
        let generation = object["generationConfig"] as? [String: Any]
        let rawLimit = object["max_completion_tokens"] ?? object["max_output_tokens"]
            ?? object["max_tokens"] ?? generation?["maxOutputTokens"]
        guard let number = rawLimit as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        // One byte per input token plus a template allowance is deliberately
        // conservative for ordinary text, but provider usage remains authority.
        let input = body.count.addingReportingOverflow(inputTemplateAllowance)
        guard !input.overflow else { return nil }
        let total = input.partialValue.addingReportingOverflow(number.intValue)
        return total.overflow ? nil : total.partialValue
    }

    static func hasUnquantifiedInput(_ value: Any) -> Bool {
        if let items = value as? [Any] { return items.contains(where: hasUnquantifiedInput) }
        guard let object = value as? [String: Any] else { return false }
        let hiddenKeys: Set<String> = ["previous_response_id", "conversation", "image_url", "file_id",
                                      "inlineData", "fileData", "inline_data", "file_data"]
        if !hiddenKeys.isDisjoint(with: object.keys) { return true }
        if let type = object["type"] as? String,
           ["image", "document", "input_image", "input_audio", "input_file", "video",
            "web_search", "web_search_preview", "file_search", "code_interpreter", "computer_use_preview", "mcp"].contains(type) {
            return true
        }
        // All hosted Responses tools except local function declarations have
        // server-side work whose input cannot be estimated from this JSON.
        if let tools = object["tools"] as? [[String: Any]], tools.contains(where: { tool in
            if let type = tool["type"] as? String { return type != "function" && type != "custom" }
            return tool["input_schema"] == nil && tool["functionDeclarations"] == nil
                && tool["function_declarations"] == nil
        }) { return true }
        // Local declaration schemas describe possible arguments, not actual
        // media payloads. Their bytes are still included in the input estimate.
        return object.contains { key, value in key != "tools" && hasUnquantifiedInput(value) }
    }
}
