//
//  AgentProfile.swift
//  WillDeep
//
//  One profile model for both places a reusable executor is configured:
//  subagent trades (`spawn_agent`) and dispatch-board execution profiles.
//
//  Why merge (see docs/AGENT_PROFILE_UNIFICATION_DESIGN.md): the two used to
//  be separate stores with the same fields (name / provider / model), so the
//  user configured the same executor twice and the two copies drifted. What
//  is NOT merged away is the execution form — an in-process child loop can be
//  given a tool whitelist, a prompt and a round budget; an external CLI
//  (codex / claude / hermes) brings its own harness and cannot. `capability`
//  is therefore only meaningful when `runtime.executor == .willDeep`, and the
//  UI greys it out otherwise rather than pretending it applies.
//
//  Storage keeps *overrides* for built-ins rather than whole copies: tool
//  sets, budgets and the invariant prompt half are code. Persisting a full
//  copy would freeze today's version of `deep` into a user's defaults and
//  quietly withhold every later change to it.
//

import Foundation

nonisolated struct AgentProfileSoul: Codable, Equatable, Sendable {
    /// Model-facing, English, ships verbatim in the `spawn_agent` schema.
    var purpose: String
    /// The trade's code-owned prompt half. Not user-editable.
    var basePromptSection: String
    /// The user's own addition. Appended after `basePromptSection`; it can
    /// never override the runner's invariant rules (read-only boundary,
    /// "your final message is the deliverable", "you cannot ask the user"),
    /// which are not part of any profile.
    var promptSection: String
    /// Skills preloaded into the child's system prompt at spawn time.
    var skillIdentifiers: [String]

    static let empty = AgentProfileSoul(
        purpose: "",
        basePromptSection: "",
        promptSection: "",
        skillIdentifiers: []
    )

    var hasUserContent: Bool {
        !promptSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !skillIdentifiers.isEmpty
    }
}

nonisolated struct AgentProfileRuntime: Codable, Equatable, Sendable {
    var executor: AgentExecutionAgent
    /// Only meaningful for external CLIs (a codex/claude/hermes profile name).
    var nativeProfileName: String?
    var modelBinding: AgentSubagentProfile.ModelBinding

    var isInProcess: Bool { executor == .willDeep }
}

/// Tool/budget policy for the in-process child loop. Absent for external CLI
/// profiles, which run under their own harness.
nonisolated struct AgentProfileCapability: Codable, Equatable, Sendable {
    var toolNames: Set<String>
    var requiresWriteAccess: Bool
    var maxRounds: Int
    var toolPayloadCharacterLimit: Int
    var escalation: AgentSubagentProfile.EscalationPolicy

    static let managedDefault = AgentProfileCapability(
        toolNames: AgentSubagentRunner.allowedToolNames,
        requiresWriteAccess: false,
        maxRounds: AgentSubagentRunner.maxRounds,
        toolPayloadCharacterLimit: 16_000,
        escalation: .retryWithParentModel
    )
}

nonisolated struct AgentProfile: Codable, Equatable, Identifiable, Sendable {
    enum Usage: String, Codable, Equatable, Sendable, CaseIterable {
        /// Selectable by `spawn_agent`.
        case subagent
        /// Selectable as a dispatch-board node executor.
        case dispatch
    }

    typealias Origin = AgentExecutionProfileOrigin

    var id: String
    var name: String
    var origin: Origin
    var usages: Set<Usage>
    var soul: AgentProfileSoul
    var runtime: AgentProfileRuntime
    var capability: AgentProfileCapability?

    /// Built-in subagent trades render under their localized names; everything
    /// else uses the stored name.
    @MainActor var localizedName: String {
        L10n.AgentDelegation.profileName(for: id, fallback: name)
    }

    /// Soul edits only reach an in-process child loop. An external CLI takes
    /// neither our prompt sections nor our skill preloads.
    var soulApplies: Bool { runtime.isInProcess }

    // MARK: - Projections onto the runtime-facing types

    /// The subagent trade this profile runs as. Returns nil for profiles that
    /// are not offered to `spawn_agent`, or that run on an external CLI.
    func asSubagentProfile() -> AgentSubagentProfile? {
        guard usages.contains(.subagent), runtime.isInProcess else { return nil }
        let capability = capability ?? .managedDefault
        return AgentSubagentProfile(
            id: id,
            purpose: soul.purpose,
            modelBinding: runtime.modelBinding,
            toolNames: capability.toolNames,
            capabilityPromptSection: combinedPromptSection,
            maxRounds: capability.maxRounds,
            toolPayloadCharacterLimit: capability.toolPayloadCharacterLimit,
            escalation: capability.escalation,
            // Write access is not something a profile can grant itself: it
            // belongs to the built-in editor trade, whose patches go through
            // per-file approval and a lock. A user-created profile that set
            // this flag in storage would otherwise hand any model a write
            // tool by editing a JSON blob.
            requiresWriteAccess: origin == .builtIn && capability.requiresWriteAccess,
            skillIdentifiers: soul.skillIdentifiers
        )
    }

    /// The code-owned half followed by the user's own half.
    var combinedPromptSection: String {
        let user = soul.promptSection.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = soul.basePromptSection.trimmingCharacters(in: .whitespacesAndNewlines)
        return [base, user].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func asExecutionProfile() -> AgentExecutionProfile? {
        guard usages.contains(.dispatch) else { return nil }
        return AgentExecutionProfile(
            id: id,
            name: name,
            executor: runtime.executor,
            modelID: runtime.modelBinding.model,
            providerID: runtime.modelBinding.preferredProviderID,
            nativeProfileName: runtime.nativeProfileName,
            origin: origin
        )
    }

    // MARK: - Built-ins

    static func from(trade: AgentSubagentProfile) -> AgentProfile {
        AgentProfile(
            id: trade.id,
            name: trade.id,
            origin: .builtIn,
            usages: [.subagent],
            soul: AgentProfileSoul(
                purpose: trade.purpose,
                basePromptSection: trade.capabilityPromptSection,
                promptSection: "",
                skillIdentifiers: []
            ),
            runtime: AgentProfileRuntime(
                executor: .willDeep,
                nativeProfileName: nil,
                modelBinding: trade.modelBinding
            ),
            capability: AgentProfileCapability(
                toolNames: trade.toolNames,
                requiresWriteAccess: trade.requiresWriteAccess,
                maxRounds: trade.maxRounds,
                toolPayloadCharacterLimit: trade.toolPayloadCharacterLimit,
                escalation: trade.escalation
            )
        )
    }

    static func from(execution: AgentExecutionProfile) -> AgentProfile {
        AgentProfile(
            id: execution.id,
            name: execution.name,
            origin: execution.origin,
            usages: [.dispatch],
            soul: .empty,
            runtime: AgentProfileRuntime(
                executor: execution.executor,
                nativeProfileName: execution.nativeProfileName,
                modelBinding: AgentSubagentProfile.ModelBinding(
                    preferredProviderID: execution.providerID,
                    model: execution.modelID,
                    contextWindowTokens: nil
                )
            ),
            // Dispatch built-ins run whole sessions, not narrowed child loops.
            capability: nil
        )
    }

    /// Everything that exists without user configuration. Legacy specialist
    /// trades remain here for stored-profile compatibility; presentation
    /// surfaces filter them through `publicBuiltIn`.
    static var builtIns: [AgentProfile] {
        AgentSubagentProfileCatalog.builtIn.map(AgentProfile.from(trade:))
            + AgentExecutionProfile.builtIns.map(AgentProfile.from(execution:))
    }
}

// MARK: - Persisted overrides

/// The user-editable slice of a built-in profile. Anything absent falls back
/// to code, so a later change to a built-in reaches users who customized only
/// their model.
nonisolated struct AgentProfileOverride: Codable, Equatable, Sendable {
    var name: String?
    var promptSection: String?
    var skillIdentifiers: [String]?
    var modelBinding: AgentSubagentProfile.ModelBinding?
    var nativeProfileName: String?
    var usages: [AgentProfile.Usage]?

    var isEmpty: Bool { self == AgentProfileOverride() }

    init(
        name: String? = nil,
        promptSection: String? = nil,
        skillIdentifiers: [String]? = nil,
        modelBinding: AgentSubagentProfile.ModelBinding? = nil,
        nativeProfileName: String? = nil,
        usages: [AgentProfile.Usage]? = nil
    ) {
        self.name = name
        self.promptSection = promptSection
        self.skillIdentifiers = skillIdentifiers
        self.modelBinding = modelBinding
        self.nativeProfileName = nativeProfileName
        self.usages = usages
    }

    func applied(to profile: AgentProfile) -> AgentProfile {
        var copy = profile
        if let name, !name.isEmpty { copy.name = name }
        if let promptSection { copy.soul.promptSection = promptSection }
        if let skillIdentifiers { copy.soul.skillIdentifiers = skillIdentifiers }
        if let modelBinding { copy.runtime.modelBinding = modelBinding }
        if let nativeProfileName { copy.runtime.nativeProfileName = nativeProfileName }
        if let usages, !usages.isEmpty { copy.usages = Set(usages) }
        return copy
    }
}

nonisolated struct AgentProfileRecords: Codable, Equatable, Sendable {
    var overrides: [String: AgentProfileOverride] = [:]
    var managed: [AgentProfile] = []
}
