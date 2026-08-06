//
//  AgentDelegationPolicy.swift
//  WillDeep
//
//  Per-turn subagent delegation policy, driven by the `/subagent` and
//  `/no-subagent` composer commands.
//
//  Design note — the two directions are NOT symmetric:
//
//   - `.forbidden` is a hard guarantee. `spawn_agent` is filtered out of
//     the turn's tool table, so the model cannot delegate even if it
//     decides it wants to. Nothing depends on the model complying.
//
//   - `.required` is deliberately a soft constraint. No provider lets us
//     pin a specific tool call across a multi-round agent loop without
//     hijacking the model's first-round planning (`tool_choice` by name
//     applies to a single request and would force delegation before the
//     model has read anything). So we inject a strong instruction and
//     then record whether delegation actually happened — an honest
//     "requested, not honored" marker beats pretending it was enforced.
//

import Foundation

nonisolated enum AgentDelegationPolicy: String, Codable, Equatable, Sendable {
    /// Default. The model decides whether to spawn subagents.
    case automatic
    /// `/subagent` — the user asked for delegation. Soft: instruction + audit.
    case required
    /// `/no-subagent` — the user forbade delegation. Hard: tool removed.
    case forbidden

    /// The one tool this policy governs. Delegated coding CLIs
    /// (`claude_code`, `codex_cli`, …) are a separate mechanism with their
    /// own approval gate and are intentionally out of scope here.
    static let governedToolName = "spawn_agent"

    /// True when the user explicitly chose this policy, i.e. it came from a
    /// slash command rather than the default. Drives the transcript marker.
    var isExplicit: Bool {
        self != .automatic
    }

    /// Whether `name` may appear in this turn's tool table. Only
    /// `.forbidden` removes anything — this is the hard half of the feature.
    func allowsTool(named name: String) -> Bool {
        guard self == .forbidden else { return true }
        return name != Self.governedToolName
    }

    /// Extra system-prompt paragraph for this turn, or nil for the default.
    ///
    /// `.forbidden` still gets a line even though the tool is already gone:
    /// without it a model that "remembers" `spawn_agent` from earlier turns
    /// wastes a round emitting a call that the transport rejects.
    var systemPromptInstruction: String? {
        switch self {
        case .automatic:
            return nil
        case .required:
            return """
            Delegation directive (user-selected `/subagent`): the user explicitly asked you to \
            delegate this turn's investigation to subagents. Break the task into independent \
            read-only units and call `spawn_agent` for them — prefer several parallel children \
            over doing the reading yourself. Your own job is to plan the split, then verify and \
            synthesize what the children report. If the task genuinely cannot be split (it is a \
            single trivial lookup, or it requires write access, which subagents do not have), \
            say so explicitly in your reply and explain why you handled it directly.
            """
        case .forbidden:
            return """
            Delegation directive (user-selected `/no-subagent`): the user forbade delegation for \
            this turn. `spawn_agent` has been removed from your tool set — do not attempt to call \
            it. Do all of the work yourself with the remaining tools.
            """
        }
    }

    /// Did a turn under this policy do what the user asked?
    ///
    /// Only `.required` can be violated by the model: `.forbidden` is
    /// enforced by the tool table, and `.automatic` has nothing to honor.
    func isHonored(spawnCallCount: Int) -> Bool {
        switch self {
        case .automatic, .forbidden:
            return true
        case .required:
            return spawnCallCount > 0
        }
    }

    /// Short transcript marker shown next to the user's message.
    var markerTitle: String? {
        switch self {
        case .automatic: return nil
        case .required: return L10n.AgentDelegation.markerRequired
        case .forbidden: return L10n.AgentDelegation.markerForbidden
        }
    }

    var markerSymbol: String? {
        switch self {
        case .automatic: return nil
        case .required: return "person.2.badge.gearshape"
        case .forbidden: return "person.2.slash"
        }
    }
}

extension AgentMessage {
    /// Marker text for the explicit delegation directive this user message
    /// carried, or nil when the turn ran on the default policy.
    ///
    /// A `.required` turn that ended without delegating reports that plainly
    /// rather than claiming the directive was enforced.
    nonisolated var delegationMarkerTitle: String? {
        guard let policy = delegationPolicy else { return nil }
        if policy == .required, delegationPolicyUnhonored == true {
            return L10n.AgentDelegation.markerRequiredNotHonored
        }
        return policy.markerTitle
    }

    nonisolated var delegationMarkerSymbol: String? {
        delegationPolicy?.markerSymbol
    }
}
