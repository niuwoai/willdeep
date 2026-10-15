import Foundation

/// Each request receives its own response observer; concurrent sessions and
/// auxiliary calls cannot overwrite another task's reported physical model.
enum AgentRoutedModelResponseObserver {
    @TaskLocal static var receive: (@MainActor @Sendable (String) -> Void)? = nil

    static func capture(_ response: HTTPURLResponse, providerID: String) {
        guard providerID == AgentProviderPreset.someIMID,
              (200..<300).contains(response.statusCode),
              let raw = response.value(forHTTPHeaderField: "X-Routed-Model") else { return }
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 128,
              model.rangeOfCharacter(from: .newlines) == nil else { return }
        AgentExecutionTrace.current?.record("model_routed") {
            $0.requestID = AgentExecutionTrace.physicalRequestID
            $0.provider = providerID; $0.model = model
        }
        receive?(model)
    }
}

// Historical route metadata remains decodable; no task classifier runs.
nonisolated enum SomeIMManagedComplexity: String, Codable, Equatable {
    case low
    case high

    var tier: AgentManagedCapabilityTier {
        switch self {
        case .low: return .low
        case .high: return .high
        }
    }
}

nonisolated enum SomeIMManagedRouting {
    static let repetitionLineThreshold = 6
    private static let minRepeatLineLength = 12

    static func extractJSONObject(from raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    static func detectDeterministicFailure(assistantText: String) -> String? {
        let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty_output" }
        var counts: [String: Int] = [:]
        for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= minRepeatLineLength else { continue }
            counts[line, default: 0] += 1
            if counts[line, default: 0] >= repetitionLineThreshold {
                return "repetition_loop"
            }
        }
        return nil
    }

    struct SomeIMOutputQualityDecision: Equatable {
        var shouldRetry: Bool
        var failureType: String
        var judgeAvailable = true
    }

    /// Only observable generation failures can trigger a task-local takeover.
    /// Normal answers never incur a second model request. Provider/network,
    /// permission and tool failures are handled by their existing recovery paths.
    static func outputQuality(
        assistantText: String, finishReason: String?
    ) -> SomeIMOutputQualityDecision {
        let reason = finishReason?.lowercased()
        guard reason == nil || reason == "stop" || reason == "end_turn" || reason == "completed",
              let failure = detectDeterministicFailure(assistantText: assistantText) else {
            return SomeIMOutputQualityDecision(shouldRetry: false, failureType: "none")
        }
        return SomeIMOutputQualityDecision(shouldRetry: true, failureType: failure)
    }

    static func failureLabel(_ failure: String) -> String {
        switch failure {
        case "empty_output": return L10n.AgentManagedRouting.emptyOutput
        case "repetition_loop": return L10n.AgentManagedRouting.repetitionLoop
        default: return L10n.AgentManagedRouting.generationFailure
        }
    }
}
