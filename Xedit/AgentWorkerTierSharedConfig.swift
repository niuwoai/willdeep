//
//  AgentWorkerTierSharedConfig.swift
//  WillDeep
//
//  The `[worker_tiers.*]` section of ~/.willdeep/config.toml, added by
//  willdeep-rs 0.52.0-rc1 and read here so the two clients resolve a tier to
//  the same model.
//
//  Why this file has to exist at all: the app has kept its three tier
//  bindings in UserDefaults (`com.willdeep.workerModelTiers.v1`) with a
//  settings pane of its own, and the CLI now keeps them in config.toml. Same
//  person, same gateway, same account — and `worker_tier: expert` would mean
//  two different models depending on which client they happened to open. The
//  shared default table exists precisely to stop that, so leaving the two
//  override paths unaware of each other would defeat it.
//
//  Read-only, for the same reason `[agent]` is: the CLI owns this section and
//  its comments, and round-tripping a table we do not fully model risks
//  dropping keys it understands and we do not. The app's own settings remain
//  writable and are what most people will use; the file is the escape hatch
//  for anyone who wants both clients pinned to one answer.
//
//  Precedence: a tier named in the file wins over the app's stored binding.
//  It is the more deliberate configuration — a file someone opened and edited
//  by hand — and it is the only one of the two the CLI can also see. Same
//  rule `AgentSharedRuntimeConfig` already states for `[agent]`.
//

import Foundation

nonisolated struct AgentWorkerTierSharedConfig: Equatable, Sendable {
    /// One `[worker_tiers.<tier>]` table.
    struct Entry: Equatable, Sendable {
        /// `provider_profile` — names a `[providers.<name>]` table in the same
        /// file, **not** one of this app's provider library entries. The two
        /// namespaces are unrelated, which is why resolving it needs
        /// `providerPresets` below.
        var providerProfile: String?
        var model: String?
        var contextWindowTokens: Int?

        var hasModel: Bool {
            model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Keyed by `AgentWorkerTier.rawValue`.
    var tiers: [String: Entry] = [:]

    /// `[providers.<name>].provider` for every provider table in the file.
    /// A `provider_profile` names the *table*; the preset id is the value
    /// inside it, and only the preset id means anything to this app.
    var providerPresets: [String: String] = [:]

    subscript(tier: AgentWorkerTier) -> Entry? {
        tiers[tier.rawValue]
    }

    /// Which provider preset `provider_profile` points at, if the file
    /// defines that table. `nil` when the entry names no profile at all —
    /// callers must distinguish that from "named one we cannot resolve".
    func providerPreset(for entry: Entry) -> String? {
        entry.providerProfile.flatMap { providerPresets[$0] }
    }

    static func load(
        from url: URL = AgentAttentionPreferencesStore.defaultConfigURL()
    ) -> AgentWorkerTierSharedConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return AgentWorkerTierSharedConfig()
        }
        return parse(text)
    }

    /// Parsed once per file revision.
    ///
    /// Worth the cache because the callers are not all on the dispatch path:
    /// the settings panes ask "is this tier usable?" from inside a SwiftUI
    /// body, which re-evaluates on every redraw. A bare `load()` there would
    /// re-read and re-parse config.toml for each frame.
    ///
    /// Invalidated on (modification date, size) rather than a timer, so an
    /// edit made in the CLI's editor is picked up on the next lookup.
    static func cached(
        from url: URL = AgentAttentionPreferencesStore.defaultConfigURL()
    ) -> AgentWorkerTierSharedConfig {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = Stamp(
            path: url.path,
            modified: attributes?[.modificationDate] as? Date,
            size: attributes?[.size] as? Int
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache, cache.stamp == stamp { return cache.config }
        let config = load(from: url)
        cache = (stamp, config)
        return config
    }

    /// Drops the memoized parse. Only the settings panes need this — they
    /// write nothing to config.toml themselves, but a person editing the file
    /// in another window while the pane is open should not have to relaunch.
    static func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    private struct Stamp: Equatable {
        var path: String
        var modified: Date?
        var size: Int?
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: Stamp, config: AgentWorkerTierSharedConfig)?

    /// Line-oriented, matching how `[agent]` and `[notifications]` are already
    /// read. Unknown keys, other sections and every comment are skipped rather
    /// than misread — a real TOML parser would be more correct and is not
    /// worth a dependency for two string keys and an integer.
    static func parse(_ text: String) -> AgentWorkerTierSharedConfig {
        var config = AgentWorkerTierSharedConfig()
        var section: Section?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = Section(header: trimmed)
                continue
            }
            guard let section, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let pieces = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces)
            let raw = stripInlineComment(pieces[1])

            switch section {
            case .workerTier(let tier):
                var entry = config.tiers[tier] ?? Entry()
                switch key {
                case "model": entry.model = unquoted(raw)
                case "provider_profile": entry.providerProfile = unquoted(raw)
                case "context_window": entry.contextWindowTokens = Int(raw)
                default: break
                }
                config.tiers[tier] = entry
            case .provider(let name):
                if key == "provider", let preset = unquoted(raw) {
                    config.providerPresets[name] = preset
                }
            }
        }
        return config
    }

    private enum Section {
        case workerTier(String)
        case provider(String)

        init?(header: String) {
            let body = header.dropFirst().dropLast()
            let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let name = Self.unquotedKey(parts[1])
            switch parts[0] {
            // Only the three canonical names. `[worker_tiers.deep]` is
            // rejected by the CLI too: `deep` still works as a tier *value*,
            // but as a table name it would collide with `expert` and there is
            // no defensible rule for which one wins.
            case "worker_tiers" where AgentWorkerTier(rawValue: name) != nil:
                self = .workerTier(name)
            case "providers":
                self = .provider(name)
            default:
                return nil
            }
        }

        /// `[providers."my endpoint"]` is legal TOML. The bare form is what
        /// the shipped examples use, but a quoted key must resolve to the
        /// same name or `provider_profile` silently stops matching.
        private static func unquotedKey(_ value: String) -> String {
            guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
            return String(value.dropFirst().dropLast())
        }
    }

    /// Values here are quoted strings and integers, so anything after a `#`
    /// outside quotes is commentary. Scanning for the quote state matters:
    /// `model = "gpt#5"` is a model name, not a comment.
    private static func stripInlineComment(_ value: String) -> String {
        var inQuotes = false
        var escaped = false
        for (offset, character) in value.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes: escaped = true
            case "\"": inQuotes.toggle()
            case "#" where !inQuotes:
                let cut = value.index(value.startIndex, offsetBy: offset)
                return String(value[value.startIndex..<cut])
                    .trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        let body = String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return body.isEmpty ? nil : body
    }
}

extension AgentWorkerTierModels {
    /// A usable provider library entry for a `[providers.<name>].provider`
    /// preset id. Resolution needs the app's provider library, so callers that
    /// have one supply this; callers that only need context budgets do not.
    typealias ProviderResolver = (String) -> (id: UUID, providerID: String)?

    /// Stored bindings with the shared config.toml layered on top.
    ///
    /// Defined once, off the main actor, because two very different callers
    /// need it — the dispatch path (which resolves providers) and the context
    /// budget (which only wants the window) — and a tier that means two models
    /// depending on who asked is the bug this whole table exists to prevent.
    static func merging(
        stored: AgentWorkerTierModels,
        shared: AgentWorkerTierSharedConfig,
        resolveProviderPreset: ProviderResolver? = nil
    ) -> AgentWorkerTierModels {
        var models = stored
        for tier in AgentWorkerTier.allCases {
            guard let entry = shared[tier], entry.hasModel else { continue }
            models[tier] = binding(for: entry, in: shared, resolveProviderPreset: resolveProviderPreset)
        }
        return models
    }

    /// One `[worker_tiers.<tier>]` table as a dispatchable binding.
    ///
    /// A table naming a provider profile this machine cannot resolve yields a
    /// binding with **no model**, making the tier unusable on purpose. The
    /// alternative — quietly using the parent endpoint — would send the named
    /// model to whatever gateway the session happens to be on: a request that
    /// fails, and one nobody asked for. The context window is kept either way,
    /// so payload budgeting stays right even when the tier cannot run.
    static func binding(
        for entry: AgentWorkerTierSharedConfig.Entry,
        in shared: AgentWorkerTierSharedConfig,
        resolveProviderPreset: ProviderResolver?
    ) -> AgentSubagentProfile.ModelBinding {
        var binding = AgentSubagentProfile.ModelBinding()
        binding.contextWindowTokens = entry.contextWindowTokens
        guard entry.providerProfile != nil else {
            // No provider named: stay on the parent's endpoint and
            // credentials, which is what willdeep-rs does for the same table.
            // Nothing leaves the account the session is already using.
            binding.model = entry.model
            return binding
        }
        guard let preset = shared.providerPreset(for: entry),
              let resolved = resolveProviderPreset?(preset)
        else { return binding }
        binding.preferredProviderEntryID = resolved.id
        binding.preferredProviderID = resolved.providerID
        binding.model = entry.model
        return binding
    }
}
