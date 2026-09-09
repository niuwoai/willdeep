import AppKit
import Foundation

extension AppState {
    /// Ask once, before the fact, whether this folder's own code can be
    /// trusted — and remember either answer.
    ///
    /// Opening a folder and authorizing its scripts to run unconfined are two
    /// different acts, and the host may not perform the second on the user's
    /// behalf. Everything that skips the sandbox reads
    /// `AgentWorkspaceTrustStore`, and an unanswered folder reads there
    /// exactly like a declined one, so a prompt that never appears is a safe
    /// failure rather than a silent grant.
    ///
    /// Returns the trust now on record. Folders that already have an answer
    /// are returned without asking again.
    @discardableResult
    func confirmWorkspaceTrustIfNeeded(for url: URL) -> AgentWorkspaceTrustStore.Trust {
        confirmWorkspaceTrustIfNeeded(forRoots: [url])
    }

    /// One prompt for a whole project. A project's extra folders are part of
    /// the same answer the user is already giving, and asking three times in
    /// a row is how a prompt becomes something people dismiss without
    /// reading.
    @discardableResult
    func confirmWorkspaceTrustIfNeeded(forRoots roots: [URL]) -> AgentWorkspaceTrustStore.Trust {
        let directories = roots
            .map { $0.standardizedFileURL }
            .filter { Self.isExistingDirectory($0) }
        guard !directories.isEmpty else { return .unknown }

        var seen = Set<String>()
        let undecided = directories.filter { url in
            guard AgentWorkspaceTrustStore.trust(for: url) == .unknown else { return false }
            return seen.insert(AgentWorkspaceTrustStore.normalizedPath(for: url)).inserted
        }
        guard !undecided.isEmpty else {
            return AgentWorkspaceTrustStore.trust(for: directories[0])
        }
        // A modal in a test run is a hang, not a prompt. Leaving the folders
        // undecided is the safe outcome: undecided behaves as untrusted.
        guard !Self.isRunningUnderTests else { return .unknown }

        let trusted = presentWorkspaceTrustPrompt(for: undecided)
        for url in undecided {
            AgentWorkspaceTrustStore.record(trusted, for: url)
        }
        return trusted ? .trusted : .untrusted
    }

    nonisolated static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private func presentWorkspaceTrustPrompt(for folders: [URL]) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.WorkspaceTrust.title(folders[0].lastPathComponent)
        var lines = [L10n.WorkspaceTrust.message, L10n.WorkspaceTrust.untrustedMessage]
        if folders.count > 1 {
            lines.append(L10n.WorkspaceTrust.folderList(folders.map(\.path).joined(separator: "\n")))
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.alertStyle = .warning
        // "Don't Trust" is second so Escape and Return land on the safe answer
        // and the destructive-looking one, respectively — the reverse would
        // make a reflex Return grant the escape.
        alert.addButton(withTitle: L10n.WorkspaceTrust.doNotTrust)
        alert.addButton(withTitle: L10n.WorkspaceTrust.trust)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
