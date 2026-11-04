//
//  AgentProviderLibraryModels.swift
//  WillDeep
//
//  Saved provider-library models for the built-in project agent.
//

import Foundation

/// One entry in the user's saved provider library. Each entry carries
/// its own provider preset, base URL, API key, and primary/alternate
/// model lists for both flash and pro tiers. The "active" entry drives
/// `AgentConfiguration` for the current chat; alternates show up in
/// the chat-mode picker as one-click switches.
struct AgentProviderEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var providerID: String
    var displayName: String
    var baseURL: String
    /// Whether this entry should be used in routing right now. Exactly
    /// one entry in `agentProviderLibrary` is the active one; toggling
    /// activation is the library's job, not this struct's.
    var apiKey: String
    /// Runtime-only marker: `false` means the key is still in Keychain and
    /// has not been materialized into memory. This is intentionally not
    /// persisted, otherwise a startup metadata load would erase secrets on
    /// the next save.
    var apiKeyLoaded: Bool
    /// Primary model for Auto/Flash routing. Required when this entry
    /// is active.
    var flashPrimary: String
    /// Alternate flash models surfaced in the chat picker so the user
    /// can one-click try a different cheap model without leaving the
    /// conversation.
    var flashAlternates: [String]
    /// Primary model for Pro routing.
    var proPrimary: String
    /// Alternate pro models surfaced in the chat picker.
    var proAlternates: [String]
    /// Per-entry routing mode override. When the user switches active
    /// to this entry the live configuration adopts this. Defaults to
    /// `.auto` for new entries; existing entries that pre-date this
    /// field decode to `.auto` via decodeIfPresent below.
    var routingMode: AgentModelRoutingMode
    /// Transport-protocol override for the Custom preset. `nil` (the
    /// default) means "use the preset's kind", which is what every
    /// non-Custom entry does. Custom users who run a self-hosted
    /// Anthropic / Gemini / Responses proxy set this to the matching
    /// kind so the facade dispatches the right adapter. Ignored when
    /// `providerID` is anything other than `custom`.
    var customKindOverride: AgentProviderKind?
    /// Runtime-only provenance; never encoded into the user's library.
    var magpieConnection: AgentMagpieIntegration.Connection? = nil

    init(
        id: UUID = UUID(),
        providerID: String,
        displayName: String? = nil,
        baseURL: String,
        apiKey: String = "",
        flashPrimary: String,
        flashAlternates: [String] = [],
        proPrimary: String,
        proAlternates: [String] = [],
        routingMode: AgentModelRoutingMode = .auto,
        customKindOverride: AgentProviderKind? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = AgentProviderPreset.normalizedDisplayName(
            providerID: providerID,
            storedDisplayName: displayName
        ) ?? providerID
        // Defensive trim: pasted API keys / base URLs frequently bring
        // surrounding whitespace or a trailing newline along, and a
        // `Bearer sk-…\n` Authorization header is rejected as HTTP 401
        // by every OpenAI-compatible upstream. The Settings commit path
        // also trims, but normalising here means any future construction
        // site is covered too.
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKeyLoaded = true
        self.flashPrimary = flashPrimary
        self.flashAlternates = AgentProviderEntry.cleanList(flashAlternates, excluding: flashPrimary)
        self.proPrimary = proPrimary
        self.proAlternates = AgentProviderEntry.cleanList(proAlternates, excluding: proPrimary)
        self.routingMode = routingMode
        // Override is only meaningful for the Custom preset; ignore
        // it on a named preset so switching providerID later doesn't
        // leave a stale override behind that would override the new
        // preset's kind too.
        self.customKindOverride = (providerID == AgentProviderPreset.customID) ? customKindOverride : nil
    }

    enum CodingKeys: String, CodingKey {
        case id, providerID, displayName, baseURL, apiKey
        case flashPrimary, flashAlternates, proPrimary, proAlternates
        case routingMode
        case customKindOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        let decodedDisplayName = try c.decode(String.self, forKey: .displayName)
        self.displayName = AgentProviderPreset.normalizedDisplayName(
            providerID: self.providerID,
            storedDisplayName: decodedDisplayName
        ) ?? self.providerID
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        let decodedAPIKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.apiKey = decodedAPIKey
        self.apiKeyLoaded = !decodedAPIKey.isEmpty
        self.flashPrimary = try c.decode(String.self, forKey: .flashPrimary)
        self.flashAlternates = try c.decodeIfPresent([String].self, forKey: .flashAlternates) ?? []
        self.proPrimary = try c.decode(String.self, forKey: .proPrimary)
        self.proAlternates = try c.decodeIfPresent([String].self, forKey: .proAlternates) ?? []
        // New field — older library JSON has no routingMode, default to
        // .auto so existing entries keep their previous behaviour.
        self.routingMode = try c.decodeIfPresent(AgentModelRoutingMode.self, forKey: .routingMode) ?? .auto
        // New field (1.56.1) — only meaningful when providerID == custom.
        // Older library JSON has no key, defaults to nil (use preset's kind).
        let override = try c.decodeIfPresent(AgentProviderKind.self, forKey: .customKindOverride)
        self.customKindOverride = (self.providerID == AgentProviderPreset.customID) ? override : nil
    }

    /// All flash candidates with the primary first — convenient for
    /// picker menus.
    var allFlashModels: [String] {
        var out = [flashPrimary]
        out.append(contentsOf: flashAlternates)
        return out.filter { !$0.isEmpty && !SomeIMManagedModel.isRetired($0) }
    }

    /// All pro candidates with the primary first.
    var allProModels: [String] {
        var out = [proPrimary]
        out.append(contentsOf: proAlternates)
        return out.filter { !$0.isEmpty && !SomeIMManagedModel.isRetired($0) }
    }

    /// Whether this entry can actually back a chat turn right now. Model
    /// names alone are not enough: some.im and DeepSeek both expose
    /// `deepseek-v4-*`, but their credentials live in different places.
    func isUsableForChatSelection(isSomeIMAuthenticated: Bool) -> Bool {
        if providerID == AgentProviderPreset.someIMID {
            return isSomeIMAuthenticated || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !makeConfiguration().normalized.requiresAPIKey {
            return true
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Build an `AgentConfiguration` snapshot from this entry, choosing
    /// a specific tier model (or falling back to the primaries).
    func makeConfiguration(
        flashOverride: String? = nil,
        proOverride: String? = nil,
        routingMode routingModeOverride: AgentModelRoutingMode? = nil,
        imageDescription: AgentImageDescriptionConfiguration = .default
    ) -> AgentConfiguration {
        let flash = flashOverride.nonEmpty ?? flashPrimary
        let pro = proOverride.nonEmpty ?? proPrimary
        // Use the entry's own routing mode by default — only callers
        // that need to force a specific mode (e.g. compression always
        // wants flash) pass an override.
        let mode = routingModeOverride ?? routingMode
        var configuration = AgentConfiguration(
            providerID: providerID,
            baseURL: baseURL,
            model: mode == .pro ? pro : flash,
            flashModel: flash,
            proModel: pro,
            routingMode: mode,
            imageDescription: imageDescription,
            apiKey: apiKey,
            customKindOverride: customKindOverride
        )
        configuration.magpieConnection = magpieConnection
        return configuration
    }

    private static func cleanList(_ list: [String], excluding primary: String) -> [String] {
        var seen = Set<String>()
        seen.insert(primary)
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let v = self?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

/// Top-level container for the multi-provider library. Knows which
/// entry is currently active. Persisted as a single JSON blob.
struct AgentProviderLibrary: Codable, Equatable {
    var entries: [AgentProviderEntry]
    var activeID: UUID?

    init(entries: [AgentProviderEntry] = [], activeID: UUID? = nil) {
        self.entries = entries
        self.activeID = activeID ?? entries.first?.id
    }

    var active: AgentProviderEntry? {
        guard let id = activeID else { return entries.first }
        return entries.first(where: { $0.id == id }) ?? entries.first
    }

    func usableEntriesForChatSelection(isSomeIMAuthenticated: Bool) -> [AgentProviderEntry] {
        entries.filter {
            $0.isUsableForChatSelection(isSomeIMAuthenticated: isSomeIMAuthenticated)
        }
    }

    @discardableResult
    mutating func ensureActiveEntryIsUsableForChatSelection(isSomeIMAuthenticated: Bool) -> Bool {
        if active?.isUsableForChatSelection(isSomeIMAuthenticated: isSomeIMAuthenticated) == true {
            return false
        }
        guard let fallback = usableEntriesForChatSelection(
            isSomeIMAuthenticated: isSomeIMAuthenticated
        ).first else {
            return false
        }
        activeID = fallback.id
        return true
    }

    mutating func upsert(_ entry: AgentProviderEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        if activeID == nil { activeID = entry.id }
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        if activeID == id { activeID = entries.first?.id }
    }

    mutating func setActive(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Promote a legacy single-provider AgentConfiguration to the new
    /// library shape. The single entry becomes the active one; its
    /// existing flash/pro models start with no alternates. Caller
    /// should only invoke this when no library yet exists in storage.
    static func migrate(from configuration: AgentConfiguration) -> AgentProviderLibrary {
        let entry = AgentProviderEntry(
            providerID: configuration.providerID,
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            flashPrimary: configuration.flashModel.isEmpty ? configuration.model : configuration.flashModel,
            flashAlternates: [],
            proPrimary: configuration.proModel.isEmpty ? configuration.model : configuration.proModel,
            proAlternates: []
        )
        return AgentProviderLibrary(entries: [entry], activeID: entry.id)
    }
}
