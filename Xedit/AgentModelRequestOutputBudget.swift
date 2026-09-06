import Foundation
import CoreFoundation

/// Protocol shape is chosen by the host adapter, never inferred from a model
/// argument. OpenAI-compatible endpoints retain their legacy max_tokens field.
nonisolated enum AgentModelRequestFormat: Equatable, Sendable {
    case openAIChat, compatibleChat, responses, anthropic, gemini
}

extension AgentModelRequestReservation {
    static let boundedDefaultOutputTokens = 8_192
    static let minimumResponsesOutputTokens = 16

    struct Prepared: Sendable {
        let body: Data
        let tokens: Int?
    }

    /// Finite admission is conservative text-only accounting, not a guarantee
    /// about proprietary tokenizers or whether a remote service honors caps.
    /// Unlimited policy preserves the exact original bytes and provider defaults.
    static func prepare(_ body: Data, format: AgentModelRequestFormat, remaining: Int?) throws -> Prepared {
        guard let remaining else { return Prepared(body: body, tokens: tokens(for: body)) }
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              !hasUnquantifiedInput(object) else { throw AgentModelRequestLedger.Failure.unknownExposure }
        let generation = object["generationConfig"] as? [String: Any] ?? [:]
        // One output allocation cannot bound multiple candidates or hosted
        // work. Fail closed until those surfaces have explicit accounting.
        for raw in [object["n"], generation["candidateCount"]].compactMap({ $0 }) {
            guard try positiveInteger(raw) == 1 else { throw AgentModelRequestLedger.Failure.unknownExposure }
        }
        if object["audio"] != nil || object["web_search_options"] != nil ||
            (object["modalities"] as? [String])?.contains(where: { $0 != "text" }) == true ||
            (generation["responseModalities"] as? [String])?.contains(where: { $0.lowercased() != "text" }) == true {
            throw AgentModelRequestLedger.Failure.unknownExposure
        }
        let key: String = switch format {
        case .openAIChat: "max_completion_tokens"
        case .compatibleChat: object["max_completion_tokens"] == nil ? "max_tokens" : "max_completion_tokens"
        case .anthropic: "max_tokens"
        case .responses: "max_output_tokens"
        case .gemini: "maxOutputTokens"
        }
        let rawLimits: [Any] = switch format {
        case .openAIChat, .compatibleChat:
            [object["max_completion_tokens"], object["max_tokens"]].compactMap { $0 }
        case .gemini: [generation[key]].compactMap { $0 }
        default: [object[key]].compactMap { $0 }
        }
        let desired = try rawLimits.map(positiveInteger).min() ?? boundedDefaultOutputTokens
        setLimit(desired, key: key, format: format, object: &object)
        let provisionalBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let input = provisionalBody.count.addingReportingOverflow(inputTemplateAllowance)
        guard !input.overflow, input.partialValue < remaining else { throw AgentModelRequestLedger.Failure.budgetExceeded }
        let output = min(desired, remaining - input.partialValue)
        let minimum = format == .responses ? minimumResponsesOutputTokens : 1
        guard output >= minimum else { throw AgentModelRequestLedger.Failure.budgetExceeded }
        // Do not silently weaken explicitly requested thinking to make a
        // request fit. The output budget includes reasoning, not only prose.
        if let thinking = object["thinking"] as? [String: Any], thinking["type"] as? String == "enabled",
           let raw = thinking["budget_tokens"], output <= (try positiveInteger(raw)) {
            throw AgentModelRequestLedger.Failure.budgetExceeded
        }
        if let thinking = generation["thinkingConfig"] as? [String: Any],
           let raw = thinking["thinkingBudget"] as? NSNumber, raw.intValue > 0,
           output <= (try positiveInteger(raw)) { throw AgentModelRequestLedger.Failure.budgetExceeded }
        setLimit(output, key: key, format: format, object: &object)
        let result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let reservation = tokens(for: result), reservation <= remaining else {
            throw AgentModelRequestLedger.Failure.budgetExceeded
        }
        return Prepared(body: result, tokens: reservation)
    }

    private static func positiveInteger(_ raw: Any) throws -> Int {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.down) == number.doubleValue else {
            throw AgentModelRequestLedger.Failure.invalidReservation
        }
        return number.intValue
    }

    private static func setLimit(_ limit: Int, key: String, format: AgentModelRequestFormat,
                                 object: inout [String: Any]) {
        if format == .gemini {
            var generation = object["generationConfig"] as? [String: Any] ?? [:]
            generation[key] = limit
            object["generationConfig"] = generation
        } else {
            if format == .openAIChat || format == .compatibleChat {
                object.removeValue(forKey: "max_completion_tokens")
                object.removeValue(forKey: "max_tokens")
            }
            object[key] = limit
        }
    }
}
