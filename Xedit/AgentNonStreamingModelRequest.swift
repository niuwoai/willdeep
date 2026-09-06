import Foundation
import CoreFoundation

/// The same reservation/receipt boundary as streaming, including HTTP failures
/// with usage. Only usage metadata is recorded, never prompts or credentials.
@MainActor
enum AgentNonStreamingModelRequest {
    private struct HTTPFailure: Error {
        let data: Data
        let response: URLResponse
    }
    private final class Output {
        var value: (Data, URLResponse)?
    }

    static func run(request: URLRequest, session: URLSession, configuration: AgentConfiguration,
                    format: AgentModelRequestFormat, ledger: AgentModelRequestLedger?,
                    safelyQuantifiableInput: Bool = true,
                    executionBudget: AgentToolExecutionBudget? = nil) async throws -> (Data, URLResponse) {
        let output = Output()
        let operation: @MainActor @Sendable () async throws -> Void = {
            do {
                output.value = try await AgentModelRequestAccounting.run(ledger: ledger,
                    configuration: configuration, request: request, format: format,
                    safelyQuantifiableInput: safelyQuantifiableInput, ownerGate: executionBudget?.ownerGate,
                    onEvent: { _ in }) { prepared, consume in
                    let (data, response) = try await session.data(for: prepared)
                    // Parse off the UI actor. Missing/invalid counts are unknown,
                    // not a zero-cost reply or a reason to refund a reservation.
                    if ledger != nil {
                        let usage = await Task.detached { usageEvent(data: data, format: format) }.value
                        if let usage { await consume(usage) }
                    }
                    guard let http = response as? HTTPURLResponse else { throw AgentClientError.invalidResponse }
                    if !(200..<300).contains(http.statusCode) {
                        throw HTTPFailure(data: data, response: response)
                    }
                    return (data, response)
                }
            } catch let failure as HTTPFailure {
                // The failed receipt is already durable. Preserve the adapter's
                // existing status-specific fallback behavior without resending.
                output.value = (failure.data, failure.response)
            }
        }
        if let executionBudget { try await executionBudget.runModelRequest(operation) }
        else { try Task.checkCancellation(); try await operation(); try Task.checkCancellation() }
        guard let value = output.value else { throw AgentClientError.invalidResponse }
        return value
    }

    nonisolated static func usageEvent(data: Data, format: AgentModelRequestFormat) -> AgentClientEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let key = format == .gemini ? "usageMetadata" : "usage"
        guard let usage = root[key] as? [String: Any] else { return nil }
        let prompt: Int, completion: Int, total: Int
        var cached: Int?, cacheWrite: Int?, reasoning = 0
        switch format {
        case .openAIChat, .compatibleChat, .responses:
            let isResponses = format == .responses
            guard let input = optionalCount(usage[isResponses ? "input_tokens" : "prompt_tokens"]),
                  let output = optionalCount(usage[isResponses ? "output_tokens" : "completion_tokens"]),
                  let reported = count(usage["total_tokens"]) else { return nil }
            prompt = input; completion = output; total = reported
            let inputDetails = usage[isResponses ? "input_tokens_details" : "prompt_tokens_details"] as? [String: Any]
            let outputDetails = usage[isResponses ? "output_tokens_details" : "completion_tokens_details"] as? [String: Any]
            cached = count(inputDetails?["cached_tokens"] ?? usage["prompt_cache_hit_tokens"])
            reasoning = count(outputDetails?["reasoning_tokens"]) ?? 0
        case .anthropic:
            guard let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]) else { return nil }
            cached = count(usage["cache_read_input_tokens"])
            cacheWrite = count(usage["cache_creation_input_tokens"])
            // These are disjoint billed input buckets, unlike OpenAI cache hits.
            guard usage["cache_read_input_tokens"] == nil || cached != nil,
                  usage["cache_creation_input_tokens"] == nil || cacheWrite != nil,
                  let inputTotal = sum([input, cached ?? 0, cacheWrite ?? 0]),
                  let all = sum([inputTotal, output]) else { return nil }
            prompt = inputTotal; completion = output; total = all
        case .gemini:
            guard let input = optionalCount(usage["promptTokenCount"]),
                  let output = optionalCount(usage["candidatesTokenCount"]),
                  let reported = count(usage["totalTokenCount"]) else { return nil }
            prompt = input; completion = output; total = reported
            cached = count(usage["cachedContentTokenCount"])
            reasoning = count(usage["thoughtsTokenCount"]) ?? 0
        }
        guard total >= prompt, total >= completion,
              let minimum = sum([prompt, completion]), total >= minimum else { return nil }
        return .usageReported(prompt: prompt, completion: completion, total: total,
            cachedPrompt: cached, cacheWritePrompt: cacheWrite, reasoning: reasoning)
    }

    nonisolated private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }

    // A reported total alone is sufficient for cumulative admission. Missing
    // breakdowns stay absent from the provider payload; never synthesize total.
    nonisolated private static func optionalCount(_ value: Any?) -> Int? {
        value == nil ? 0 : count(value)
    }

    nonisolated private static func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
