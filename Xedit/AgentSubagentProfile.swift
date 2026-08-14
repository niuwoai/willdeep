//
//  AgentSubagentProfile.swift
//  WillDeep
//
//  Subagent "trades": a bundle of model + provider + tool whitelist +
//  capability prompt + budgets that `spawn_agent` selects by name.
//
//  Why trades instead of a free-form `model` parameter (see
//  docs/SUBAGENT_PROFILES_DESIGN.md):
//
//   - The per-round fixed cost is the tool schema, not the prompt. A child
//     loop resends its whole tool table every round, so narrowing 9 tools
//     to 4 saves more over a 12-round run than any prompt trimming could.
//   - Small models call tools more accurately when given fewer of them, so
//     narrowing buys accuracy as well as cost.
//   - Cost policy belongs to the user's configuration, not to whether the
//     model remembers to pick a cheap model this time.
//
//  A profile may only NARROW the global read-only whitelist. The one
//  exception is the editor trade, whose write access is gated by its own
//  approval + file lock (see AgentSubagentEditorLock).
//

import Foundation

nonisolated struct AgentSubagentProfile: Codable, Equatable, Identifiable, Sendable {
    /// How a finished trade recovers when its cheap model could not do the job.
    enum EscalationPolicy: String, Codable, Equatable, Sendable {
        /// Report the failure to the parent as-is.
        case none
        /// Re-run the original prompt once on the parent session's model with
        /// the `deep` tool set. Deliberately a fresh run rather than a
        /// continuation: a small model's stuck transcript is noise to a
        /// bigger one.
        case retryWithParentModel
    }

    /// Which model/provider a trade runs on. All-nil remains the explicit
    /// "inherit the parent session" representation for migrated/custom
    /// bindings, while built-in trades prefer the automatic provider route.
    struct ModelBinding: Codable, Equatable, Sendable {
        /// Exact saved provider entry. Provider preset IDs are not unique —
        /// users can keep several OpenAI-compatible endpoints — so new
        /// settings bind to the library entry UUID. Optional to keep stored
        /// v1 bindings source-compatible.
        var preferredProviderEntryID: UUID? = nil
        /// Preferred provider preset (e.g. `some-im`). Resolution picks a
        /// usable library entry for it at spawn time. This remains as a
        /// migration fallback for bindings saved before entry UUIDs existed.
        var preferredProviderID: String?
        var model: String?
        /// Context window of `model`, used for payload budgeting and for
        /// recognizing a context-overflow failure. nil → parent's window.
        var contextWindowTokens: Int?

        static let inheritsParent = ModelBinding()

        var inheritsEverything: Bool {
            preferredProviderID == nil && model == nil
        }
    }

    let id: String
    /// One-line trade description embedded in the `spawn_agent` schema. The
    /// model reads this to choose, so it stays English and concrete.
    var purpose: String
    var modelBinding: ModelBinding
    /// Requested tools. Always intersected with the global whitelist before
    /// use — see `effectiveToolNames(writeAccessGranted:)`.
    var toolNames: Set<String>
    /// The trade-specific half of the system prompt. The invariant half
    /// (read-only boundary, "your final message is the deliverable", "you
    /// cannot ask the user") is owned by the runner and cannot be overridden
    /// here: those lines exist because models violated them.
    var capabilityPromptSection: String
    var maxRounds: Int
    /// Per-tool-result cap fed to the child loop. Narrow-context trades keep
    /// this well under the parent's so a single large read cannot blow the
    /// window.
    var toolPayloadCharacterLimit: Int
    var escalation: EscalationPolicy
    /// True only for the editor trade. Gates the write tool through the
    /// approval + single-file lock path instead of the read-only whitelist.
    var requiresWriteAccess: Bool
    /// Skills preloaded into this trade's system prompt at spawn time. Empty
    /// for every built-in trade; filled in from the profile's soul.
    var skillIdentifiers: [String]

    init(
        id: String,
        purpose: String,
        modelBinding: ModelBinding = .inheritsParent,
        toolNames: Set<String>,
        capabilityPromptSection: String,
        maxRounds: Int,
        toolPayloadCharacterLimit: Int,
        escalation: EscalationPolicy = .none,
        requiresWriteAccess: Bool = false,
        skillIdentifiers: [String] = []
    ) {
        self.id = id
        self.purpose = purpose
        self.modelBinding = modelBinding
        self.toolNames = toolNames
        self.capabilityPromptSection = capabilityPromptSection
        self.maxRounds = maxRounds
        self.toolPayloadCharacterLimit = toolPayloadCharacterLimit
        self.escalation = escalation
        self.requiresWriteAccess = requiresWriteAccess
        self.skillIdentifiers = skillIdentifiers
    }

    /// The tools this trade may actually call.
    ///
    /// Intersection, never union: a profile can only take tools away from
    /// the global read-only set. `writeAccessGranted` is the editor trade's
    /// narrow door, opened only once its approval and file lock are held.
    func effectiveToolNames(writeAccessGranted: Bool = false) -> Set<String> {
        var allowed = AgentSubagentRunner.allowedToolNames
        if requiresWriteAccess, writeAccessGranted {
            allowed.formUnion(AgentSubagentProfileCatalog.editorWriteToolNames)
        }
        return toolNames.intersection(allowed)
    }

    var localizedDisplayName: String {
        switch id {
        case AgentSubagentProfileCatalog.scoutID: return L10n.AgentDelegation.profileScoutName
        case AgentSubagentProfileCatalog.readerID: return L10n.AgentDelegation.profileReaderName
        case AgentSubagentProfileCatalog.editorID: return L10n.AgentDelegation.profileEditorName
        default: return L10n.AgentDelegation.profileDeepName
        }
    }

    /// User-facing description for the settings pane. `purpose` itself is
    /// model-facing (it ships verbatim in the `spawn_agent` tool
    /// description) and must stay English; this is its translation.
    var localizedPurpose: String {
        switch id {
        case AgentSubagentProfileCatalog.scoutID: return L10n.AgentDelegation.profileScoutPurpose
        case AgentSubagentProfileCatalog.readerID: return L10n.AgentDelegation.profileReaderPurpose
        case AgentSubagentProfileCatalog.editorID: return L10n.AgentDelegation.profileEditorPurpose
        default: return L10n.AgentDelegation.profileDeepPurpose
        }
    }
}

// MARK: - Catalog

nonisolated enum AgentSubagentProfileCatalog {
    static let scoutID = "scout"
    static let readerID = "reader"
    static let deepID = "deep"
    static let editorID = "editor"

    /// Tools the editor trade adds on top of the read-only set, and only
    /// while its per-file approval is held.
    static let editorWriteToolNames: Set<String> = ["apply_patch"]

    /// Default binding for the cheap trades: some.im's GLM tier when the
    /// user is signed in, otherwise inherit the parent (resolved at spawn
    /// time, so signing in or out never requires a settings migration).
    private static let cheapBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: "glm-5",
        contextWindowTokens: 128_000
    )

    /// Deep used to inherit the parent session. Subagents now default to a
    /// provider of their own as requested by Settings: some.im when present,
    /// otherwise the active provider. A nil model adopts that provider's
    /// configured primary model.
    private static let automaticProviderBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: nil,
        contextWindowTokens: nil
    )

    static let scout = AgentSubagentProfile(
        id: scoutID,
        purpose: "Locate things: find files, symbols, call sites, or answer \"where is X / does X exist\". Fastest and cheapest; no shell.",
        modelBinding: cheapBinding,
        toolNames: ["grep_files", "search_files", "list_directory", "read_file"],
        capabilityPromptSection: """
        Your trade is LOCATION. Find where things live and report exact paths with line numbers. \
        Read only as much of a file as you need to confirm a match. Do not review, critique, or \
        redesign what you find — report where it is and move on.
        """,
        maxRounds: 8,
        toolPayloadCharacterLimit: 8_000,
        escalation: .retryWithParentModel
    )

    static let reader = AgentSubagentProfile(
        id: readerID,
        purpose: "Read and summarize: digest long files, docs, or public web pages and answer questions about their content. No shell.",
        modelBinding: cheapBinding,
        toolNames: ["read_file", "list_directory", "web_search"],
        capabilityPromptSection: """
        Your trade is READING. Digest the sources you are pointed at and answer with specifics \
        (quotes, paths, line numbers) rather than impressions. When a source is too large to read \
        whole, say which parts you read.
        """,
        maxRounds: 8,
        toolPayloadCharacterLimit: 8_000,
        escalation: .retryWithParentModel
    )

    /// The full read-only investigation trade. Any spawn that does not name a
    /// profile lands here, so old prompts and replayed sessions keep the same
    /// tool and round budgets while adopting the configurable provider/model
    /// routing shared by every subagent trade.
    static let deep = AgentSubagentProfile(
        id: deepID,
        purpose: "Complex investigation: reasoning across many files, read-only shell commands, and git status.",
        modelBinding: automaticProviderBinding,
        toolNames: AgentSubagentRunner.allowedToolNames,
        capabilityPromptSection: """
        Your trade is INVESTIGATION. Follow the evidence across files, verify claims before \
        reporting them, and state explicitly what you could not confirm.
        """,
        maxRounds: AgentSubagentRunner.maxRounds,
        toolPayloadCharacterLimit: 24_000,
        escalation: .none
    )

    static let editor = AgentSubagentProfile(
        id: editorID,
        purpose: "Edit ONE approved file. Requires a `target_file` argument and the user's approval; cannot touch any other path.",
        modelBinding: cheapBinding,
        toolNames: ["read_file", "apply_patch"],
        capabilityPromptSection: """
        Your trade is EDITING EXACTLY ONE FILE. You may only patch the target file named in your \
        task; any other path is denied. Read the file before patching it, keep the change minimal \
        and consistent with the surrounding code, and report what you changed and why. If the \
        change cannot be made safely within this one file, make no edit and say so.
        """,
        maxRounds: 6,
        toolPayloadCharacterLimit: 8_000,
        escalation: .retryWithParentModel,
        requiresWriteAccess: true
    )

    static let builtIn: [AgentSubagentProfile] = [scout, reader, deep, editor]

    /// Resolve a spawn's `profile` argument. Unknown or missing → `deep`,
    /// which is the behaviour every pre-profile caller already expects.
    static func profile(id rawID: String?) -> AgentSubagentProfile {
        let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let trimmed, !trimmed.isEmpty else { return deep }
        return builtIn.first { $0.id == trimmed } ?? deep
    }

    static func isKnown(id rawID: String) -> Bool {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return builtIn.contains { $0.id == trimmed }
    }

    /// Default provider for all subagent trades: some.im wins whenever a
    /// corresponding library entry exists; otherwise use the provider marked
    /// active in Settings (and finally the first entry for damaged legacy
    /// libraries with no active id).
    static func defaultProviderEntry(in library: AgentProviderLibrary) -> AgentProviderEntry? {
        library.entries.first { $0.providerID == AgentProviderPreset.someIMID }
            ?? library.active
            ?? library.entries.first
    }

    /// Resolve a persisted binding to one concrete provider library entry.
    /// UUID is authoritative. Provider ID keeps v1 settings working. The
    /// built-in some.im preference is an automatic default, so when some.im
    /// is absent it intentionally falls through to the active provider.
    static func providerEntry(
        for binding: AgentSubagentProfile.ModelBinding,
        in library: AgentProviderLibrary
    ) -> AgentProviderEntry? {
        if let entryID = binding.preferredProviderEntryID,
           let exact = library.entries.first(where: { $0.id == entryID }) {
            return exact
        }
        if let providerID = binding.preferredProviderID,
           let matching = library.entries.first(where: { $0.providerID == providerID }) {
            return matching
        }
        if binding.preferredProviderID == AgentProviderPreset.someIMID {
            return defaultProviderEntry(in: library)
        }
        return nil
    }

    /// The built-in `glm-5` choice is specific to some.im. If automatic
    /// routing had to fall back to another provider, use that entry's primary
    /// model instead of sending an invalid cross-provider model id.
    static func bindingModelApplies(
        _ binding: AgentSubagentProfile.ModelBinding,
        to entry: AgentProviderEntry
    ) -> Bool {
        if let entryID = binding.preferredProviderEntryID {
            return entryID == entry.id
        }
        guard let providerID = binding.preferredProviderID else { return true }
        return providerID == entry.providerID
    }

    /// Schema-facing catalog line for the `spawn_agent` tool description.
    /// Built-ins only; `AgentSubagentProfileStore.toolDescriptionCatalog`
    /// is the one the live schema uses, since it also lists user-created
    /// trades.
    static var toolDescriptionCatalog: String {
        catalogLine(for: builtIn)
    }

    static func catalogLine(for profiles: [AgentSubagentProfile]) -> String {
        profiles
            .map { "`\($0.id)` — \($0.purpose)" }
            .joined(separator: " ")
    }

    /// Apply the user's per-trade model overrides from settings. Tool sets,
    /// prompts and budgets are never user-editable — narrowing rules and
    /// safety lines are not configuration.
    static func applyingOverrides(
        _ overrides: [String: AgentSubagentProfile.ModelBinding]
    ) -> [AgentSubagentProfile] {
        builtIn.map { profile in
            guard let override = overrides[profile.id] else { return profile }
            var copy = profile
            copy.modelBinding = override
            return copy
        }
    }
}

// MARK: - Settings persistence

/// Trade → runtime resolution. Storage now lives in `AgentProfileStore`
/// (agent-profile.v2), which also owns dispatch profiles; this enum stays as
/// the trade-facing façade so the runner and the `spawn_agent` schema keep
/// one call site.
nonisolated enum AgentSubagentProfileStore {
    private static var store: AgentProfileStore { AgentProfileStore() }

    /// Model bindings only, kept for callers that still think in v1 terms
    /// (the settings section binds directly to these).
    static func loadOverrides() -> [String: AgentSubagentProfile.ModelBinding] {
        var bindings: [String: AgentSubagentProfile.ModelBinding] = [:]
        for profile in store.profiles(usage: .subagent) where profile.origin == .builtIn {
            bindings[profile.id] = profile.runtime.modelBinding
        }
        return bindings.filter { AgentSubagentProfileCatalog.isKnown(id: $0.key) }
    }

    static func saveOverrides(_ overrides: [String: AgentSubagentProfile.ModelBinding]) {
        let store = store
        var profiles = store.profiles()
        for index in profiles.indices {
            guard let binding = overrides[profiles[index].id] else { continue }
            profiles[index].runtime.modelBinding = binding
        }
        store.save(profiles: profiles)
    }

    /// Every trade `spawn_agent` may select: the four built-ins with the
    /// user's soul/model edits applied, plus any user-created in-process
    /// profile marked for subagent use.
    static func resolvedProfiles() -> [AgentSubagentProfile] {
        let resolved = store.profiles(usage: .subagent).compactMap { $0.asSubagentProfile() }
        // A damaged or emptied store must never leave `spawn_agent` with no
        // trades at all; fall back to code.
        return resolved.isEmpty ? AgentSubagentProfileCatalog.builtIn : resolved
    }

    /// Schema catalog including user-created trades, so the model can pick
    /// one the user configured rather than only the four built-ins.
    static var toolDescriptionCatalog: String {
        AgentSubagentProfileCatalog.catalogLine(for: resolvedProfiles())
    }

    static func resolvedProfile(id rawID: String?) -> AgentSubagentProfile {
        let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profiles = resolvedProfiles()
        if let trimmed, !trimmed.isEmpty,
           let match = profiles.first(where: { $0.id.lowercased() == trimmed }) {
            return match
        }
        // Unknown or missing → deep, which is what every pre-profile caller
        // already expects.
        return profiles.first { $0.id == AgentSubagentProfileCatalog.deepID }
            ?? AgentSubagentProfileCatalog.deep
    }
}
