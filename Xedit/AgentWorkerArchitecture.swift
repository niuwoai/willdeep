import Foundation

nonisolated enum AgentWorkerTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, advanced, expert
    var id: String { rawValue }
    var next: Self? {
        switch self {
        case .standard: return .advanced
        case .advanced: return .expert
        case .expert: return nil
        }
    }
    var title: String {
        switch self {
        case .standard: return String(localized: "基础", table: "WorkerArchitecture")
        case .advanced: return String(localized: "进阶", table: "WorkerArchitecture")
        case .expert: return String(localized: "专家", table: "WorkerArchitecture")
        }
    }
}

nonisolated enum AgentWorkerRole: String, CaseIterable, Identifiable, Sendable {
    case investigate, implement, verify, review, operate
    var id: String { rawValue }
    var profileID: String {
        switch self {
        case .investigate: return "generalist"
        case .implement: return "implementer"
        case .verify: return "tester"
        case .review: return "reviewer"
        case .operate: return "ops_runner"
        }
    }
    var title: String {
        switch self {
        case .investigate: return String(localized: "调查", table: "WorkerArchitecture")
        case .implement: return String(localized: "实现", table: "WorkerArchitecture")
        case .verify: return String(localized: "验证", table: "WorkerArchitecture")
        case .review: return String(localized: "审查", table: "WorkerArchitecture")
        case .operate: return String(localized: "运维", table: "WorkerArchitecture")
        }
    }
    static func matching(_ profileID: String) -> Self? {
        allCases.first { $0.profileID == profileID }
    }
}

/// Exactly three shared model slots. No keys or job prompts are stored here.
/// An explicit provider entry is authoritative; nil uses only the parent's
/// provider, never an unrelated signed-in public account.
nonisolated struct AgentWorkerTierModels: Codable, Equatable, Sendable {
    static let standardWindow = 131_072
    static let extendedWindow = 262_144
    var bindings: [String: AgentSubagentProfile.ModelBinding] = [:]

    subscript(tier: AgentWorkerTier) -> AgentSubagentProfile.ModelBinding {
        get { bindings[tier.rawValue] ?? Self.defaultBinding(tier) }
        set {
            var binding = newValue
            binding.workerTier = nil
            bindings[tier.rawValue] = binding
        }
    }

    static func defaultBinding(_ tier: AgentWorkerTier) -> AgentSubagentProfile.ModelBinding {
        let model: String
        switch tier {
        case .standard: model = AgentSubagentModelCompatibility.baseModel
        case .advanced: model = "deepseek-v4-flash"
        case .expert: model = "gpt-5.6-sol"
        }
        return .init(
            preferredProviderID: AgentProviderPreset.someIMID,
            model: model,
            contextWindowTokens: tier == .standard ? standardWindow : extendedWindow
        )
    }

    /// Known hosted trade aliases migrate to the shared basic tier, while
    /// explicit third-party models and private-provider names stay untouched.
    static func tier(for binding: AgentSubagentProfile.ModelBinding) -> AgentWorkerTier? {
        if let tier = binding.workerTier,
           binding.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           binding.preferredProviderEntryID == nil, binding.preferredProviderID == nil {
            return tier
        }
        guard binding.preferredProviderID == AgentProviderPreset.someIMID,
              binding.preferredProviderEntryID == nil,
              let model = binding.model,
              AgentSubagentModelCompatibility.legacyModels.contains(model) else { return nil }
        return .standard
    }
}

extension AgentProfileStore {
    private static let workerTiersKey = "com.willdeep.workerModelTiers.v1"

    func workerTierModels() -> AgentWorkerTierModels {
        guard let data = defaults.data(forKey: Self.workerTiersKey),
              let models = try? JSONDecoder().decode(AgentWorkerTierModels.self, from: data)
        else { return AgentWorkerTierModels() }
        return models
    }

    func save(workerTierModels: AgentWorkerTierModels) {
        guard let data = try? JSONEncoder().encode(workerTierModels) else { return }
        defaults.set(data, forKey: Self.workerTiersKey)
    }
}
