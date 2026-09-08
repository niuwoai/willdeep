import Foundation

nonisolated enum AgentSubagentSchedulingPolicy {
    static func runsInBackground(_ arguments: [String: AgentJSONValue]) -> Bool {
        guard arguments["run_in_background"]?.boolValue() == true,
              arguments["independent_task"]?.boolValue() == true else { return false }
        return arguments["parent_parallel_work"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

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

/// 用户看得见的六个工种。顺序即 `publicBuiltIn` 的顺序，两边由
/// AgentWorkerArchitectureTests 钉住。
///
/// 「调查」与「通用」是两件事，别再合成一格：调查是只读的查证工种
/// （scout 及其同族的 reader / deep / git 溯源 / 日志巡检），通用是没有
/// 更合适工种时的兜底，它可以在已声明范围内改文件。此前 `investigate`
/// 这一格挂的是 `generalist` 的 id 却叫「调查」，统计面板于是把整个调查
/// 家族的次数记在一个写着 generalist 的行上，名不副实。
nonisolated enum AgentWorkerRole: String, CaseIterable, Identifiable, Sendable {
    case scout, general, implement, verify, review, operate
    var id: String { rawValue }
    var profileID: String {
        switch self {
        case .scout: return "scout"
        case .general: return "generalist"
        case .implement: return "implementer"
        case .verify: return "tester"
        case .review: return "reviewer"
        case .operate: return "ops_runner"
        }
    }
    var title: String {
        switch self {
        case .scout: return String(localized: "调查", table: "WorkerArchitecture")
        case .general: return String(localized: "通用", table: "WorkerArchitecture")
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
    static let compactWindow = 65_536
    static let standardWindow = 131_072
    static let extendedWindow = 262_144
    static let maximumWindow = 1_048_576

    /// The budgets offered in settings, smallest first. A budget is a ceiling
    /// on what we send, never a claim about the model: dispatch still clamps
    /// it to the provider's supported window, so picking 1M on a 128K model
    /// buys nothing rather than producing an over-long request.
    static let selectableWindows = [compactWindow, standardWindow, extendedWindow, maximumWindow]

    /// Round token counts read as 64K / 1M; anything else (a value pinned in
    /// config.toml, say) keeps its exact number rather than being rounded into
    /// a label that no longer matches what dispatch uses.
    static func windowLabel(_ tokens: Int) -> String {
        if tokens > 0, tokens % 1_048_576 == 0 { return "\(tokens / 1_048_576)M" }
        if tokens > 0, tokens % 1_024 == 0 { return "\(tokens / 1_024)K" }
        return String(tokens)
    }

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
            contextWindowTokens: extendedWindow
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
