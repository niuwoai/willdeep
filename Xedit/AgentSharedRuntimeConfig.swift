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
    /// `agent.small_model_routing` — whether the runtime classifies requests
    /// and steers bounded work toward a trade. Absent means "not configured".
    var smallModelRouting: Bool?
    /// `agent.auto_dispatch_read_only` — whether a high-confidence read-only
    /// request may be run as a worker before the root model answers. WillDeep
    /// keeps an absent value off for first-token latency; an explicit true
    /// enables the serial preflight for large-repository workflows.
    var autoDispatchReadOnly: Bool?
    /// `agent.max_deep_calls_per_harness` — the 1M-tier admission budget. The
    /// rs name says "harness"; WillDeep applies it per session, which is the
    /// closest equivalent unit it has.
    var maxDeepCallsPerHarness: Int?

    static let sectionName = "agent"

    static func load(
        from url: URL = AgentAttentionPreferencesStore.defaultConfigURL()
    ) -> AgentSharedRuntimeConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return AgentSharedRuntimeConfig()
        }
        return parse(text)
    }

    /// Line-oriented, matching how `[notifications]` is already read. A real
    /// TOML parser would be more correct and is not worth a dependency for
    /// three scalars: unknown keys, other sections and every comment are
    /// simply skipped rather than misread.
    static func parse(_ text: String) -> AgentSharedRuntimeConfig {
        var inside = false
        var values: [String: String] = [:]
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
            values[key] = value
        }

        var config = AgentSharedRuntimeConfig()
        config.smallModelRouting = values["small_model_routing"].flatMap(parseBool)
        config.autoDispatchReadOnly = values["auto_dispatch_read_only"].flatMap(parseBool)
        config.maxDeepCallsPerHarness = values["max_deep_calls_per_harness"].flatMap { Int($0) }
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
