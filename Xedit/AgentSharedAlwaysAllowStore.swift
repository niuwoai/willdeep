//
//  AgentSharedAlwaysAllowStore.swift
//  WillDeep
//
//  The always-allow rules this app shares with the willdeep-rs CLI through
//  `~/.willdeep/always-allow.json` (`$WILLDEEP_HOME` honored, same as
//  `AgentAttentionPreferencesStore`).
//
//  ## Why this is not just "read the other app's file"
//
//  The two clients do not model a rule the same way. Xedit pins a **command
//  family** (`git push`, `npm run build`) — one click covers every future
//  command in that family. The Rust CLI pins one **exact command**
//  (`command-exact:cargo test --all`) and matches by string equality.
//
//  Sharing the broad form would be a silent policy change: a CLI user who has
//  only ever been offered "remember this exact command" would start
//  auto-running a whole family they never consented to. Sharing the narrow
//  form is safe in both directions, because an exact command is a subset of
//  any family that contains it.
//
//  So the shared currency is deliberately the narrow one: **the exact command
//  the human actually looked at and approved.** Clicking Always Allow on
//  `git push origin main` keeps the local family rule *and* publishes
//  `command-exact:git push origin main`; the CLI then stops asking for that
//  one command, and nothing wider. Rules this app cannot represent are left
//  untouched in the file rather than dropped — the CLI owns them.
//
//  ## Invariants owed to the other side
//
//  - **0600 or the CLI refuses the whole store.** `ToolRegistry::
//    with_always_allow_store` errors out when the mode has group/other bits,
//    which would break every CLI run, not just this feature. Writes go
//    through a 0600 temp file plus atomic replace.
//  - **Never publish a command carrying a credential.** The CLI stopped
//    minting such rules in 0.39.0-rc2 and prunes old ones on load; if this
//    side published them the leak would simply reappear from a different
//    process. The check lives here rather than in either app's approval UI
//    because it is a property of the shared file.
//  - **Mint a signature only where the CLI would.** Same rejection of shell
//    composition, same whitespace normalization. A rule the CLI can never
//    match is dead weight in a file two programs have to read.
//  - **Read before write.** Two processes share this file; a blind overwrite
//    would drop rules the CLI added since we last looked.
//

import Foundation

nonisolated enum AgentSharedAlwaysAllowStore {
    /// Mirrors `willdeep-core`'s `COMMAND_SIGNATURE_PREFIX`.
    static let exactCommandPrefix = "command-exact:"

    static func defaultStoreURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["WILLDEEP_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("always-allow.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep", isDirectory: true)
            .appendingPathComponent("always-allow.json")
    }

    // MARK: - Signature minting

    /// Swift copy of `willdeep-core::tools::command_signature`. Returns nil for
    /// anything the CLI would also refuse to remember: shell composition
    /// (the pinned text would no longer be one command), an empty command, or
    /// a command carrying a credential.
    static func exactCommandSignature(for command: String) -> String? {
        if command.contains(where: { "|&;><`\n\r".contains($0) }) {
            return nil
        }
        let normalized = command.split(separator: " ", omittingEmptySubsequences: true)
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .joined(separator: " ")
        guard !normalized.isEmpty, !carriesCredentials(normalized) else { return nil }
        return exactCommandPrefix + normalized
    }

    /// Variable-name fragments that mark a value as a credential. Same list the
    /// CLI's redactor uses (`willdeep-core::judge::SENSITIVE_KEY_MARKERS`).
    private static let sensitiveKeyMarkers = [
        "key", "token", "secret", "password", "passwd", "pwd",
        "credential", "auth", "session", "cookie", "signature",
    ]

    /// True when the command carries an inline credential in any of the shapes
    /// the CLI's `redact_credentials` recognizes: `KEY=value` assignments,
    /// `--password value` flags, `Authorization: Bearer …`, and bare `sk-` /
    /// `ghp_` / `xoxb-` tokens.
    ///
    /// Deliberately conservative in the same direction as the CLI: when in
    /// doubt, do not publish. A command that stays unshared costs the operator
    /// one approval click in the other app; a published secret costs them a
    /// key rotation.
    static func carriesCredentials(_ command: String) -> Bool {
        var expectingValue = false
        for token in command.split(whereSeparator: \.isWhitespace).map(String.init) {
            if expectingValue && !token.hasPrefix("-") {
                return true
            }
            expectingValue = false

            let lowered = token.lowercased()
            if let separator = lowered.firstIndex(of: "="),
               separator != lowered.startIndex,
               lowered.index(after: separator) != lowered.endIndex,
               keyLooksSensitive(String(lowered[lowered.startIndex..<separator])) {
                return true
            }
            if token.hasPrefix("-"),
               keyLooksSensitive(String(lowered.drop(while: { $0 == "-" }))) {
                expectingValue = true
                continue
            }
            if looksLikeBareSecret(token) {
                return true
            }
            if lowered == "bearer" || lowered == "basic" {
                expectingValue = true
            }
        }
        return false
    }

    private static func keyLooksSensitive(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeyMarkers.contains { lowered.contains($0) }
    }

    private static func looksLikeBareSecret(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"',;"))
        for prefix in ["sk-", "ghp_", "xoxb-"] where trimmed.hasPrefix(prefix) {
            return trimmed.count - prefix.count >= 16
        }
        return false
    }

    // MARK: - Reading

    /// The whole point of this file is that another process writes to it, so
    /// the cache is keyed on modification date plus size rather than on time.
    /// A `stat` per lookup is cheap; a stale hit would reproduce exactly the
    /// bug this feature exists to remove — the CLI pinned it, the app still
    /// asks.
    private final class RuleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var rules: [String] = []

        func rules(at url: URL) -> [String] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let stamp = attributes.map { values in
                let date = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (values[.size] as? Int) ?? 0
                return "\(date)/\(size)"
            }

            lock.lock()
            defer { lock.unlock() }
            if let stamp, stamp == key {
                return rules
            }
            guard let stamp,
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                // A missing or unreadable store is an empty rule set, not an
                // error: the CLI may simply never have run here.
                key = nil
                rules = []
                return []
            }
            key = stamp
            rules = decoded
            return decoded
        }

        func invalidate() {
            lock.lock()
            key = nil
            lock.unlock()
        }
    }

    private static let cache = RuleCache()

    /// Every rule string in the file, including ones this app does not
    /// understand. Callers that only want matchable rules should use
    /// `exactCommands`.
    static func loadRules(from url: URL = defaultStoreURL()) -> [String] {
        cache.rules(at: url)
    }

    /// Normalized commands published by either side, ready for equality
    /// matching against a freshly minted signature.
    static func exactCommands(from url: URL = defaultStoreURL()) -> Set<String> {
        Set(
            loadRules(from: url)
                .filter { $0.hasPrefix(exactCommandPrefix) }
                .map { String($0.dropFirst(exactCommandPrefix.count)) }
        )
    }

    static func allows(command: String, in url: URL = defaultStoreURL()) -> Bool {
        guard let signature = exactCommandSignature(for: command) else { return false }
        return loadRules(from: url).contains(signature)
    }

    // MARK: - Writing

    @discardableResult
    static func publish(command: String, to url: URL = defaultStoreURL()) -> Bool {
        guard let signature = exactCommandSignature(for: command) else { return false }
        var rules = loadRules(from: url)
        guard !rules.contains(signature) else { return true }
        rules.append(signature)
        return write(rules: rules, to: url)
    }

    /// Sorted, deduplicated, 0600, atomically replaced — the CLI writes the
    /// same shape, so neither side sees a half-written file or a mode it
    /// refuses.
    private static func write(rules: [String], to url: URL) -> Bool {
        let payload = Array(Set(rules)).sorted()
        guard let data = try? JSONEncoder.sharedAlwaysAllowEncoder.encode(payload) else {
            return false
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(
            ".always-allow.\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        // Same-second writes can land on an identical (mtime, size) stamp, so
        // drop the cache explicitly rather than trusting the file to look new.
        cache.invalidate()
        // `replaceItemAt` can carry the destination's old attributes forward;
        // re-assert the mode so a file that was somehow 0644 does not stay
        // 0644 and lock the CLI out of its own store.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        return true
    }
}

private extension JSONEncoder {
    static var sharedAlwaysAllowEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
