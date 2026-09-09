import Foundation

/// Whether the user has said the code in a folder can be trusted.
///
/// The question this answers is narrow: a project's own scripts run outside
/// the workspace sandbox, and running somebody else's repository that way is
/// not a decision the host may make on the user's behalf. A cloned repo, a
/// downloaded sample, a folder someone shared — opening one must not be the
/// same act as authorizing its `scripts/` directory to run unconfined.
///
/// So the answer is recorded per folder, before the fact, by the person who
/// opened it. Both answers are recorded: "no" is a decision too, and asking
/// again every time the folder is opened would train the user to click
/// through it. `unknown` means nobody has been asked yet, and it behaves
/// exactly like "no" everywhere except in the prompt.
///
/// The record covers the whole tree under the folder, which is what the
/// question says out loud. A nested folder with its own record wins over an
/// ancestor's, so a user who trusts `~/Sites` can still mark one repository
/// inside it untrusted.
nonisolated enum AgentWorkspaceTrustStore {
    enum Trust: String, Codable, Equatable {
        case trusted
        case untrusted
        /// Nobody has been asked about this folder yet.
        case unknown
    }

    struct Record: Codable, Equatable {
        var path: String
        var trusted: Bool
        var decidedAt: Date
    }

    private static let storeKey = "com.willdeep.workspaceTrust.v1"
    nonisolated(unsafe) private static var testDefaultsOverride: UserDefaults?

    /// Test seam, mirroring `AgentMCPSettingsStore._setTestDefaultsOverride`.
    static func _setTestDefaultsOverride(_ defaults: UserDefaults?) {
        testDefaultsOverride = defaults
    }

    private static var defaults: UserDefaults { testDefaultsOverride ?? .standard }

    static func records() -> [Record] {
        guard let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return decoded
    }

    /// Symlinks resolved and the trailing slash dropped, so the same folder
    /// reached two ways produces one record and matches the path the script
    /// policy resolves.
    static func normalizedPath(for url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.count > 1, resolved.hasSuffix("/") else { return resolved }
        return String(resolved.dropLast())
    }

    /// The recorded answer covering `url`, or `.unknown` when there is none.
    /// The most specific record wins.
    static func trust(for url: URL) -> Trust {
        let target = normalizedPath(for: url)
        var best: Record?
        for record in records() {
            let root = record.path
            guard target == root || target.hasPrefix(root + "/") else { continue }
            if best == nil || root.count > best!.path.count { best = record }
        }
        guard let best else { return .unknown }
        return best.trusted ? .trusted : .untrusted
    }

    static func isTrusted(_ url: URL) -> Bool { trust(for: url) == .trusted }

    /// Write the user's answer. Re-answering the same folder replaces the
    /// previous record rather than stacking a second one.
    static func record(_ trusted: Bool, for url: URL, at date: Date = Date()) {
        let path = normalizedPath(for: url)
        guard !path.isEmpty else { return }
        var current = records().filter { $0.path != path }
        current.append(Record(path: path, trusted: trusted, decidedAt: date))
        guard let data = try? JSONEncoder().encode(current) else { return }
        defaults.set(data, forKey: storeKey)
    }

    /// Drop a folder's answer so it is asked about again. Used by the
    /// settings surface, and by tests.
    static func forget(_ url: URL) {
        let path = normalizedPath(for: url)
        let remaining = records().filter { $0.path != path }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
