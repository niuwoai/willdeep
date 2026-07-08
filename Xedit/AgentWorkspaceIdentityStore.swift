//
//  AgentWorkspaceIdentityStore.swift
//  WillDeep
//
//  Maps a WillDeep workspace to a stable, local-only random UUID sent as
//  `x-willdeep-workspace-id` on some.im requests. The mapping KEY (a local
//  workspace path or remote runtime+path) never leaves this Mac — only the
//  random UUID is transmitted, so some.im can group one project's sessions
//  without learning any path, basename, or reversible hash.
//
//  See SOME_IM_MANAGED_ROUTING_DESIGN.md ("some.im 上下文 Headers" /
//  "路径隐私说明").
//

import Foundation

enum AgentWorkspaceIdentityStore {
    private static let defaultsKey = "agent.workspace.identity.map.v1"
    private static let lock = NSLock()

    /// Injection seam for tests; production uses `.standard`.
    static var defaults: UserDefaults = .standard

    /// Stable random UUID for a workspace key, minted on first use and
    /// persisted across launches. Returns nil for "no workspace" (empty key
    /// or the no-workspace sentinel) so the header is omitted entirely.
    ///
    /// The key is only ever used as a local dictionary lookup — it is never
    /// transmitted. Callers pass a workspace group key (local path or
    /// `remote:<runtimeID>:<path>`); the returned UUID is the only value
    /// that ever goes on the wire.
    static func workspaceID(forWorkspaceKey key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AgentSession.noWorkspaceSidebarGroupKey else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        var map = loadMap()
        if let existing = map[trimmed], !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        map[trimmed] = fresh
        saveMap(map)
        return fresh
    }

    private static func loadMap() -> [String: String] {
        guard let data = defaults.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveMap(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
