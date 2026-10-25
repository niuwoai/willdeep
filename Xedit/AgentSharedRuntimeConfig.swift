//
//  AgentSharedRuntimeConfig.swift
//  WillDeep
//
//  The `[agent]` section of ~/.willdeep/config.toml, which WillDeep.app and
//  willdeep-rs already share.
//
//  `[notifications]` has been shared since 0.29.0-rc1 — same file, same
//  schema, either side may write it. The routing knobs willdeep-rs added in
//  0.37.0-rc1 (`small_model_routing`, `auto_dispatch_read_only`,
//  `max_deep_calls_per_harness`) belong in exactly the same place: someone who
//  turns the deep budget down to 1 means it for their machine, not for
//  whichever of the two clients they happened to be looking at.
//
//  Read-only on purpose. The CLI owns this file's `[agent]` section and its
//  comments; the app reading it costs nothing and cannot corrupt anything,
//  whereas round-tripping a section we do not fully model risks dropping keys
//  the CLI understands and we do not. `[notifications]` is written back
//  because the app owns that UI; this one has no UI to own.
//
//  Precedence: an explicit value here wins over the app's own defaults. It is
//  the more deliberate configuration — a file the user opened and edited by
//  hand — and it is the only one of the two that the CLI can also see.
//
//  See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §6.
//

import Foundation

nonisolated struct AgentSharedRuntimeConfig: Equatable, Sendable {
    private final class LoadCache: @unchecked Sendable {
        struct Signature: Equatable {
            let modifiedAt: Date?
            let fileSize: Int?
        }

        struct Entry {
            let signature: Signature
            let config: AgentSharedRuntimeConfig
        }

        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]

        func value(
            for url: URL,
            reader: (URL) throws -> String
        ) -> AgentSharedRuntimeConfig {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let signature = Signature(modifiedAt: values?.contentModificationDate, fileSize: values?.fileSize)
            lock.lock()
            defer { lock.unlock() }
            if let entry = entries[url], entry.signature == signature {
                return entry.config
            }
            guard let text = try? reader(url) else {
                let empty = AgentSharedRuntimeConfig()
                entries[url] = Entry(signature: signature, config: empty)
                return empty
            }
            let config = AgentSharedRuntimeConfig.parse(text)
            entries[url] = Entry(signature: signature, config: config)
            return config
        }
    }

    private static let loadCache = LoadCache()
    /// `agent.small_model_routing` — whether the runtime classifies requests
    /// and steers bounded work toward a trade. Absent means "not configured".
    var smallModelRouting: Bool?
    /// `agent.auto_dispatch_read_only` — whether a high-confidence read-only
    /// request may be run as a worker before the root model answers. WillDeep
    /// keeps an absent value off for first-token latency; an explicit true
    /// enables the serial preflight for large-repository workflows.
    var autoDispatchReadOnly: Bool?
    /// `agent.speculative_scout` — whether a high-confidence read-only request
    /// starts its routed read-only worker *in parallel* with the root model
    /// instead of before it. The report lands at the next tool boundary and
    /// the worker is cancelled when the turn ends first. Absent means on;
    /// `false` turns the parallel scout off. WillDeep-only for now; documented
    /// in docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §6 so willdeep-rs can adopt
    /// the same key.
    var speculativeScout: Bool?
    /// `agent.max_deep_calls_per_harness` — the 1M-tier admission budget. The
    /// rs name says "harness"; WillDeep applies it per session, which is the
    /// closest equivalent unit it has.
    var maxDeepCallsPerHarness: Int?
    var maxTurns: Int?
    var humanWaitYieldSeconds: Int?
    var tokenBudget: Int?
    var goalTokenBudget: Int?
    var goalWallClockMinutes: Int?
    var goalMaxContinuations: Int?
    var inputSuggestions: Bool?
    var runtimeParameterErrors: [String] = []

    static let sectionName = "agent"

    static func load(
        from url: URL = AgentAttentionPreferencesStore.defaultConfigURL(),
        reader: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) -> AgentSharedRuntimeConfig {
        loadCache.value(for: url.standardizedFileURL, reader: reader)
    }

    /// Line-oriented, matching how `[notifications]` is already read. A real
    /// TOML parser would be more correct and is not worth a dependency for
    /// three scalars: unknown keys, other sections and every comment are
    /// simply skipped rather than misread.
    static func parse(_ text: String) -> AgentSharedRuntimeConfig {
        var inside = false
        var values: [String: String] = [:]
        var duplicateKeys: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // `[agent]` only. `[agent.something]` is a different table and
                // must not leak its keys into this one.
                inside = trimmed == "[\(sectionName)]"
                continue
            }
            guard inside, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let pieces = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces)
            var value = pieces[1].trimmingCharacters(in: .whitespaces)
            // Strip a trailing inline comment. Values here are bools and
            // integers, so anything after a `#` is commentary.
            if let hash = value.firstIndex(of: "#") {
                value = String(value[value.startIndex..<hash])
                    .trimmingCharacters(in: .whitespaces)
            }
            if values[key] != nil { duplicateKeys.append(key) }
            values[key] = value
        }

        var config = AgentSharedRuntimeConfig()
        config.smallModelRouting = values["small_model_routing"].flatMap(parseBool)
        config.autoDispatchReadOnly = values["auto_dispatch_read_only"].flatMap(parseBool)
        config.speculativeScout = values["speculative_scout"].flatMap(parseBool)
        config.maxDeepCallsPerHarness = values["max_deep_calls_per_harness"].flatMap { Int($0) }
        config.maxTurns = values["max_turns"].flatMap(Int.init)
        config.humanWaitYieldSeconds = values["human_wait_yield_seconds"].flatMap(Int.init)
        config.tokenBudget = values["token_budget"].flatMap(Int.init)
        config.goalTokenBudget = values["goal_token_budget"].flatMap(Int.init)
        config.goalWallClockMinutes = values["goal_wall_clock_minutes"].flatMap(Int.init)
        config.goalMaxContinuations = values["goal_max_continuations"].flatMap(Int.init)
        config.inputSuggestions = values["input_suggestions"].flatMap(parseBool)
        let integerKeys = ["human_wait_yield_seconds", "max_turns", "token_budget", "goal_token_budget", "goal_wall_clock_minutes", "goal_max_continuations", "max_deep_calls_per_harness"]
        let booleanKeys = ["input_suggestions", "small_model_routing", "auto_dispatch_read_only"]
        config.runtimeParameterErrors = integerKeys.filter { values[$0].map { Int($0) == nil } ?? false }
            + booleanKeys.filter { values[$0].map { !["true", "false"].contains($0) } ?? false }
            + duplicateKeys.filter { (integerKeys + booleanKeys).contains($0) }
        if let seconds = config.humanWaitYieldSeconds, seconds < 0 { config.runtimeParameterErrors.append("human_wait_yield_seconds") }
        return config
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
