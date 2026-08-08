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

    /// Which model/provider a trade runs on. All-nil means "inherit the
    /// parent session", which is what keeps `deep` byte-identical to the
    /// pre-profile behaviour.
    struct ModelBinding: Codable, Equatable, Sendable {
        /// Preferred provider preset (e.g. `some-im`). Resolution picks a
        /// usable library entry for it at spawn time; if none is usable the
        /// whole binding falls back to the parent session.
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

    init(
        id: String,
        purpose: String,
        modelBinding: ModelBinding = .inheritsParent,
        toolNames: Set<String>,
        capabilityPromptSection: String,
        maxRounds: Int,
        toolPayloadCharacterLimit: Int,
        escalation: EscalationPolicy = .none,
        requiresWriteAccess: Bool = false
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

    /// The pre-profile behaviour, preserved verbatim: parent model, full
    /// read-only tool set, 12 rounds. Any spawn that does not name a
    /// profile lands here, so old prompts and replayed sessions are
    /// unaffected by this feature.
    static let deep = AgentSubagentProfile(
        id: deepID,
        purpose: "Complex investigation: reasoning across many files, read-only shell commands, git status. Uses the parent's model — most capable and most expensive.",
        modelBinding: .inheritsParent,
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

    /// Schema-facing catalog line for the `spawn_agent` tool description.
    static var toolDescriptionCatalog: String {
        builtIn
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

/// User overrides for trade → model/provider bindings. Only the binding is
/// stored; everything else about a trade is code.
nonisolated enum AgentSubagentProfileStore {
    private static let key = "com.willdeep.agent.subagent-profile-bindings.v1"

    static func loadOverrides() -> [String: AgentSubagentProfile.ModelBinding] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                  [String: AgentSubagentProfile.ModelBinding].self,
                  from: data
              ) else {
            return [:]
        }
        // Drop overrides for trades that no longer exist so a renamed or
        // removed profile cannot resurrect a stale binding.
        return decoded.filter { AgentSubagentProfileCatalog.isKnown(id: $0.key) }
    }

    static func saveOverrides(_ overrides: [String: AgentSubagentProfile.ModelBinding]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func resolvedProfiles() -> [AgentSubagentProfile] {
        AgentSubagentProfileCatalog.applyingOverrides(loadOverrides())
    }

    static func resolvedProfile(id rawID: String?) -> AgentSubagentProfile {
        let base = AgentSubagentProfileCatalog.profile(id: rawID)
        guard let override = loadOverrides()[base.id] else { return base }
        var copy = base
        copy.modelBinding = override
        return copy
    }
}
