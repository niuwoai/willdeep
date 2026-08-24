//
//  AgentManagedRoutingModels.swift
//  WillDeep
//
//  some.im managed-routing models split out of AgentModels.swift.
//

import Foundation

// MARK: - some.im managed routing ("省心托管")

/// Capability floor for a some.im managed-routing session. The floor only
/// ever rises within a session ("只升不降"): once a turn proves it needs
/// `.high` / `.premium`, later turns cannot be dropped back to a weaker tier
/// by the lightweight judge. The user can still explicitly choose Flash / Pro /
/// Premium, switch model, or start a new session. See
/// SOME_IM_MANAGED_ROUTING_DESIGN.md.
nonisolated enum AgentManagedCapabilityTier: String, Codable, Equatable, Comparable {
    case low
    case high
    case premium

    var rank: Int {
        switch self {
        case .low: return 0
        case .high: return 1
        case .premium: return 2
        }
    }

    static func < (lhs: AgentManagedCapabilityTier, rhs: AgentManagedCapabilityTier) -> Bool {
        lhs.rank < rhs.rank
    }

    var next: AgentManagedCapabilityTier? {
        switch self {
        case .low: return .high
        case .high: return .premium
        case .premium: return nil
        }
    }
}

/// Persisted per-session state for some.im managed routing. Stored on
/// `AgentSession` (additively decoded — absent on legacy sessions → nil,
/// i.e. "not a managed session").
nonisolated struct AgentManagedRoutingState: Codable, Equatable {
    /// Lowest capability tier this session may use until the user chooses a
    /// different managed tier, switches model, or starts a new session.
    var minimumTier: AgentManagedCapabilityTier
    /// Last main-call model the router resolved to. Diagnostic only.
    var lastSelectedModel: String?
    var lastEscalatedAt: Date?
    var lastEscalationReason: String?

    init(
        minimumTier: AgentManagedCapabilityTier = .low,
        lastSelectedModel: String? = nil,
        lastEscalatedAt: Date? = nil,
        lastEscalationReason: String? = nil
    ) {
        self.minimumTier = minimumTier
        self.lastSelectedModel = lastSelectedModel
        self.lastEscalatedAt = lastEscalatedAt
        self.lastEscalationReason = lastEscalationReason
    }
}

/// Task domain the routing judge classifies a turn into.
nonisolated enum SomeIMManagedDomain: String, Codable, Equatable {
    case coding
    case general
}

nonisolated enum AgentManagedRouteFamily: Equatable {
    case general
    case coding
    case unknown
}

/// Per-assistant-message record of how managed routing resolved this turn.
/// Additive observability metadata (footer chip / usage stats) — persisted
/// with the session, absent (nil) on non-managed turns. `SomeIMManagedComplexity`
/// lives in SomeIMManagedRouting.swift (same module).
nonisolated struct AgentManagedRouteDecision: Codable, Equatable {
    var selectedModel: String
    var tier: AgentManagedCapabilityTier
    var domain: SomeIMManagedDomain
    var complexity: SomeIMManagedComplexity
    /// The router fell back to the local heuristic (judge unavailable / unparsable).
    var didFallback: Bool
    /// An output-quality failure escalated this turn one tier up.
    var didEscalate: Bool
    var failureType: String?

    init(
        selectedModel: String,
        tier: AgentManagedCapabilityTier,
        domain: SomeIMManagedDomain,
        complexity: SomeIMManagedComplexity,
        didFallback: Bool,
        didEscalate: Bool = false,
        failureType: String? = nil
    ) {
        self.selectedModel = selectedModel
        self.tier = tier
        self.domain = domain
        self.complexity = complexity
        self.didFallback = didFallback
        self.didEscalate = didEscalate
        self.failureType = failureType
    }

    /// Short tier label for a footer chip (proper-noun tier names, like the pill).
    var tierLabel: String {
        switch tier {
        case .low: return "Low"
        case .high: return "High"
        case .premium: return "Premium"
        }
    }

    /// Tier plus an escalation (↑) or fallback (~) marker, e.g. "High↑".
    var tierMarkers: String {
        var text = tierLabel
        if didEscalate {
            text += "↑"
        } else if didFallback {
            text += "~"
        }
        return text
    }

    /// Footer family reflects the routing judge's task-domain verdict. Coding
    /// Plan only changes the model family for coding tasks; general tasks stay
    /// on the `someim-auto-*` family.
    var footerFamily: AgentManagedRouteFamily {
        switch domain {
        case .general:
            return .general
        case .coding:
            return .coding
        }
    }

    /// User-facing capability name derived from the actual virtual model.
    /// The coding families call the same three effective levels low/high/
    /// premium, while the footer presents them consistently as flash/pro/
    /// premium alongside the auto family.
    var footerLevelLabel: String {
        let model = selectedModel.lowercased()
        if model.hasSuffix("-premium") { return "premium" }
        if model.hasSuffix("-pro") || model.hasSuffix("-high") { return "pro" }
        if model.hasSuffix("-flash") || model.hasSuffix("-low") { return "flash" }
        switch tier {
        case .low: return "flash"
        case .high: return "pro"
        case .premium: return "premium"
        }
    }

    var footerLevelMarkers: String {
        var text = footerLevelLabel
        if didEscalate {
            text += "↑"
        } else if didFallback {
            text += "~"
        }
        return text
    }

    /// Full footer text derived from the judge domain and actual model level, e.g.
    /// `托管-通用-flash` or `托管-编程-pro↑`.
    var footerChipText: String {
        switch footerFamily {
        case .general:
            return L10n.AgentManagedRouting.generalFooter(footerLevelMarkers)
        case .coding:
            return L10n.AgentManagedRouting.codingFooter(footerLevelMarkers)
        case .unknown:
            return "\(L10n.AgentManagedRouting.footerPrefix) \(tierMarkers)"
        }
    }
}

/// some.im managed-routing model catalogue: the fixed set of main-call model
/// names a judge decision may resolve to, plus the (domain, tier) → model
/// mapping and its inverse. These are virtual model names on the some.im
/// relay, not raw upstream models. See SOME_IM_MANAGED_ROUTING_DESIGN.md
/// ("模型与命名").
nonisolated enum SomeIMManagedModel {
    static let codingPlanLow = "someim-coding-plan-low"
    static let codingPlanHigh = "someim-coding-plan-high"
    static let codingPlanPremium = "someim-coding-plan-premium"
    static let codeLow = "someim-code-low"
    static let codeHigh = "someim-code-high"
    static let codePremium = "someim-code-premium"
    static let autoFlash = "someim-auto-flash"
    static let autoPro = "someim-auto-pro"
    static let autoPremium = "someim-auto-premium"

    /// The lightweight router / output-quality judge model. Backed by a
    /// non-thinking official DeepSeek behind a clean (no-persona) virtual
    /// chain. Never selectable as a turn's main model — hence excluded from
    /// `allowlist`.
    static let judge = "someim-judge"

    /// Dedicated safety classifier whose policy is injected by the some.im
    /// gateway. The client sends only the per-command user payload so the
    /// long, stable policy remains server-managed and cache-friendly.
    static let securityGuard = "someim-security-guard"

    /// Dedicated context-compression model whose fixed compression prompt is
    /// injected by the some.im gateway in replace mode (currently backed by
    /// deepseek-v4-flash, billed at flash tier). The client sends only the
    /// bare transcript; part labels ride in the user payload so the server
    /// prompt stays byte-stable and cache-friendly. See muchtoken
    /// docs/someim-32b-compressor.md. Never a turn's main model.
    static let contextCompressor = "someim-32b-compressor"

    /// Every main-call model a judge decision is allowed to resolve to. A
    /// `target_model` outside this set is rejected and the local
    /// (domain, tier) mapping is used instead.
    static let allowlist: Set<String> = [
        codingPlanLow, codingPlanHigh, codingPlanPremium,
        codeLow, codeHigh, codePremium,
        autoFlash, autoPro, autoPremium
    ]

    /// Resolve the actual main-call model from a task domain and the
    /// effective capability tier (already merged with the session floor).
    static func resolve(
        domain: SomeIMManagedDomain,
        tier: AgentManagedCapabilityTier,
        hasCodingPlan: Bool
    ) -> String {
        if hasCodingPlan, domain == .coding {
            switch tier {
            case .low: return codingPlanLow
            case .high: return codingPlanHigh
            case .premium: return codingPlanPremium
            }
        }
        switch (domain, tier) {
        case (.coding, .low): return codeLow
        case (.coding, .high): return codeHigh
        case (.coding, .premium): return codePremium
        case (.general, .low): return autoFlash
        case (.general, .high): return autoPro
        case (.general, .premium): return autoPremium
        }
    }

    /// Inverse of `resolve` for the only-goes-up floor bookkeeping: which
    /// tier does a resolved model correspond to. Unknown → nil.
    static func tier(of model: String) -> AgentManagedCapabilityTier? {
        switch model {
        case codingPlanLow, codeLow, autoFlash: return .low
        case codingPlanHigh, codeHigh, autoPro: return .high
        case codingPlanPremium, codePremium, autoPremium: return .premium
        default: return nil
        }
    }

    /// Next model up its own ladder for a single output-quality escalation
    /// retry. Returns nil at the top of a ladder so the retry never loops.
    /// See design doc "升档模型".
    static func escalated(from model: String) -> String? {
        switch model {
        case codingPlanLow: return codingPlanHigh
        case codingPlanHigh: return codingPlanPremium
        case codeLow: return codeHigh
        case codeHigh: return codePremium
        case autoFlash: return autoPro
        case autoPro: return autoPremium
        // premium models: top of ladder → no auto-escalation.
        default: return nil
        }
    }
}

nonisolated struct AgentSidePanelState: Codable, Equatable {
    var kind: AgentSidePanelKind?
    var selectedFilePath: String?
    var mediaTaskScope: AgentMediaTaskScope?
    var imageEditorImagePath: String?
    var imageEditorMaskPath: String?
    var imageEditorPreferredOperation: AgentImageEditorOperationPreference?
    var imageEditorContext: AgentImageEditorContext?
    var lastViewedAt: Date?

    static let empty = AgentSidePanelState()

    init(
        kind: AgentSidePanelKind? = nil,
        selectedFilePath: String? = nil,
        mediaTaskScope: AgentMediaTaskScope? = nil,
        imageEditorImagePath: String? = nil,
        imageEditorMaskPath: String? = nil,
        imageEditorPreferredOperation: AgentImageEditorOperationPreference? = nil,
        imageEditorContext: AgentImageEditorContext? = nil,
        lastViewedAt: Date? = nil
    ) {
        self.kind = kind
        self.selectedFilePath = selectedFilePath
        self.mediaTaskScope = mediaTaskScope
        self.imageEditorImagePath = imageEditorImagePath
        self.imageEditorMaskPath = imageEditorMaskPath
        self.imageEditorPreferredOperation = imageEditorPreferredOperation
        self.imageEditorContext = imageEditorContext
        self.lastViewedAt = lastViewedAt
    }
}
