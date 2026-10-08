import Foundation
import CryptoKit

/// Shared with willdeep-core::runtime_parameters. Values contain no credentials.
nonisolated struct AgentRuntimeParameters: Codable, Equatable, Sendable {
    static let schemaID = "willdeep.runtime-parameters.v1"
    static let fileName = "runtime-parameters.json"
    var schema = schemaID
    var maxTurns = 200
    var tokenBudget: Int?
    var goalTokenBudget: Int?
    var goalWallClockMinutes = 240
    var goalMaxContinuations = 64
    var inputSuggestions = true
    var smallModelRouting = true
    var autoDispatchReadOnly = false
    var maxDeepCallsPerHarness = 1

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, maxTurns = "max_turns", tokenBudget = "token_budget"
        case goalTokenBudget = "goal_token_budget", goalWallClockMinutes = "goal_wall_clock_minutes"
        case goalMaxContinuations = "goal_max_continuations", inputSuggestions = "input_suggestions"
        case smallModelRouting = "small_model_routing", autoDispatchReadOnly = "auto_dispatch_read_only"
        case maxDeepCallsPerHarness = "max_deep_calls_per_harness"
    }

    enum Failure: Error, LocalizedError {
        case invalid
        var errorDescription: String? {
            String(localized: "runtime-parameters.invalid", defaultValue: "The shared runtime configuration is invalid. Check runtime-parameters.json before continuing.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(maxTurns, forKey: .maxTurns)
        try container.encode(tokenBudget, forKey: .tokenBudget)
        try container.encode(goalTokenBudget, forKey: .goalTokenBudget)
        try container.encode(goalWallClockMinutes, forKey: .goalWallClockMinutes)
        try container.encode(goalMaxContinuations, forKey: .goalMaxContinuations)
        try container.encode(inputSuggestions, forKey: .inputSuggestions)
        try container.encode(smallModelRouting, forKey: .smallModelRouting)
        try container.encode(autoDispatchReadOnly, forKey: .autoDispatchReadOnly)
        try container.encode(maxDeepCallsPerHarness, forKey: .maxDeepCallsPerHarness)
    }

    func validate() throws {
        guard schema == Self.schemaID, (1...1000).contains(maxTurns),
              (1...10080).contains(goalWallClockMinutes),
              (1...10000).contains(goalMaxContinuations),
              (0...16).contains(maxDeepCallsPerHarness),
              [tokenBudget, goalTokenBudget].allSatisfy({ $0.map { (1000...10_000_000).contains($0) } ?? true })
        else { throw Failure.invalid }
    }

    static var defaultURL: URL {
        AgentAttentionPreferencesStore.defaultConfigURL().deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
              let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        // The schema contains only scalar values and one fixed string. Check
        // duplicate keys because Foundation otherwise silently takes the last.
        let keys = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*:"#)
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard keys.count == CodingKeys.allCases.count else { throw Failure.invalid }
        for key in ["max_turns", "token_budget", "goal_token_budget", "goal_wall_clock_minutes", "goal_max_continuations", "max_deep_calls_per_harness"] {
            if object[key] is NSNull { continue }
            guard let number = object[key] as? NSNumber,
                  !["c", "d", "f"].contains(String(cString: number.objCType)) else { throw Failure.invalid }
        }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate()
            return value
        } catch { throw Failure.invalid }
    }

    static func load(from url: URL = defaultURL) throws -> Self? {
        do { return try decode(Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw Failure.invalid }
    }

    @MainActor static func resolve(shared: AgentSharedRuntimeConfig = .load(), profileURL: URL = defaultURL) throws -> Self {
        if let profile = try load(from: profileURL) { return profile }
        guard shared.runtimeParameterErrors.isEmpty else { throw Failure.invalid }
        var value = Self()
        value.maxTurns = shared.maxTurns ?? value.maxTurns
        value.tokenBudget = shared.tokenBudget
        value.goalTokenBudget = shared.goalTokenBudget
        value.goalWallClockMinutes = shared.goalWallClockMinutes ?? AgentGoalRunSettings.loadHours() * 60
        value.goalMaxContinuations = shared.goalMaxContinuations ?? value.goalMaxContinuations
        value.inputSuggestions = shared.inputSuggestions ?? AgentSettingsStore.loadInputSuggestionsEnabled()
        value.smallModelRouting = shared.smallModelRouting ?? value.smallModelRouting
        value.autoDispatchReadOnly = shared.autoDispatchReadOnly ?? value.autoDispatchReadOnly
        value.maxDeepCallsPerHarness = AgentSettingsStore.loadDeepAdmissionBudget(sharedConfig: shared)
        try value.validate()
        return value
    }

    var canonical: String {
        let token = tokenBudget.map(String.init) ?? "null"
        let goalToken = goalTokenBudget.map(String.init) ?? "null"
        return "{\"schema\":\"\(Self.schemaID)\",\"max_turns\":\(maxTurns),\"token_budget\":\(token),\"goal_token_budget\":\(goalToken),\"goal_wall_clock_minutes\":\(goalWallClockMinutes),\"goal_max_continuations\":\(goalMaxContinuations),\"input_suggestions\":\(inputSuggestions),\"small_model_routing\":\(smallModelRouting),\"auto_dispatch_read_only\":\(autoDispatchReadOnly),\"max_deep_calls_per_harness\":\(maxDeepCallsPerHarness)}"
    }

    var fingerprint: String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var routingConfig: AgentSharedRuntimeConfig {
        var value = AgentSharedRuntimeConfig()
        value.smallModelRouting = smallModelRouting
        value.autoDispatchReadOnly = autoDispatchReadOnly
        value.maxDeepCallsPerHarness = maxDeepCallsPerHarness
        return value
    }

    /// A post-response boundary ceiling; missing usage is not a zero receipt.
    func turnBudgetReached(input: Int, output: Int, usageKnown: Bool) -> Bool {
        guard let tokenBudget else { return false }
        guard usageKnown else { return true }
        let total = input.addingReportingOverflow(output)
        return total.overflow || total.partialValue >= tokenBudget
    }
}
