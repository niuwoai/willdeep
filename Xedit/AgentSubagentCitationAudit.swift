//
//  AgentSubagentCitationAudit.swift
//  WillDeep
//
//  Deterministic spot-check of what a report-only trade claims.
//
//  Ported from willdeep-rs (`crates/willdeep-core/src/subagent.rs`), where the
//  live-fire range made the gap obvious: `test_fixer` has an exit code, `scout`
//  has none, so every read-only run has recorded `verifierPassed == nil`
//  forever — permanently "not verified", permanently invisible in the numbers.
//  And invisible reads as fine.
//
//  Their answers are not unfalsifiable, though. A location either exists or it
//  does not. This checks the half a program can check: the paths, line numbers
//  and commit hashes the report names. No model, no network, no round budget —
//  a `stat` per path and one `git cat-file` per hash.
//
//  What it deliberately does NOT claim: that the answer is *right*. A worker
//  can cite ten real files and still miss the question entirely. What it can no
//  longer do is invent a path and have that pass unnoticed.
//

import Foundation

nonisolated enum AgentSubagentCitationAudit {
    struct Result: Equatable, Sendable {
        /// Citations the check understood. Zero means the report named nothing
        /// checkable — which is not the same as a report whose every citation
        /// held up, and the two must never be averaged together.
        var checked: Int = 0
        /// Cited locations that point at nothing.
        var unverifiable: [String] = []

        var isEmpty: Bool { checked == 0 }

        /// Appended to the report so the parent sees the same thing the
        /// telemetry counted. Nothing checked, nothing to say.
        var note: String? {
            guard checked > 0 else { return nil }
            guard !unverifiable.isEmpty else {
                return "<citation-check checked=\"\(checked)\" unverifiable=\"0\" />"
            }
            let list = unverifiable.map { "- \($0)" }.joined(separator: "\n")
            return """
            <citation-check checked="\(checked)" unverifiable="\(unverifiable.count)">
            These cited locations do not exist in the workspace, so anything resting on them is unsupported:
            \(list)
            </citation-check>
            """
        }
    }

    /// Separators that end a citation token. Backticks and brackets matter:
    /// models quote paths as `` `src/foo.swift:42` `` far more often than bare.
    private static let separators = CharacterSet(charactersIn: " \t\n\r`\"'()[]<>,;")

    static func audit(report: String, workspaceURL: URL?) -> Result {
        guard let workspaceURL, !report.isEmpty else { return Result() }
        var result = Result()
        var seen = Set<String>()
        for raw in report.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".:*#"))
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            if let citation = pathCitation(in: token) {
                result.checked += 1
                let target = workspaceURL.appendingPathComponent(citation.path)
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: target.path,
                    isDirectory: &isDirectory
                )
                guard exists, !isDirectory.boolValue else {
                    result.unverifiable.append(token)
                    continue
                }
                guard let line = citation.line else { continue }
                // A line past the end of the file is the same class of error as
                // a path that does not exist: it points at nothing.
                let lineCount = (try? String(contentsOf: target, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .count ?? 0
                if line == 0 || line > lineCount {
                    result.unverifiable.append(token)
                }
            } else if isCommitHash(token) {
                result.checked += 1
                if !commitExists(token, workspaceURL: workspaceURL) {
                    result.unverifiable.append(token)
                }
            }
        }
        return result
    }

    /// `Sources/Foo.swift:42` → (`Sources/Foo.swift`, 42). Only tokens that
    /// look like a workspace-relative file path qualify: a directory
    /// separator and an extension, no absolute paths, no URLs. Anything the
    /// parser cannot classify is left alone — counting unrecognized tokens as
    /// bad citations would measure the parser instead of the worker.
    static func pathCitation(in token: String) -> (path: String, line: Int?)? {
        var path = token
        var line: Int?
        if let colon = token.lastIndex(of: ":") {
            let tail = String(token[token.index(after: colon)...])
            if !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) {
                path = String(token[token.startIndex..<colon])
                line = Int(tail)
            }
        }
        guard !path.hasPrefix("/"), !path.hasPrefix("-"), !path.contains("://") else {
            return nil
        }
        guard path.contains("/"), let fileName = path.split(separator: "/").last else {
            return nil
        }
        guard fileName.contains("."), !fileName.hasPrefix(".") else { return nil }
        return (path, line)
    }

    /// Hex of commit-ish length, with at least one digit and one letter. The
    /// mixed requirement keeps ordinary words (`deadbeef` is hex, `feedface`
    /// is hex) and round numbers out of the count.
    static func isCommitHash(_ token: String) -> Bool {
        guard (7...40).contains(token.count) else { return false }
        guard token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return false }
        return token.contains(where: { $0.isNumber }) && token.contains(where: { $0.isLetter })
    }

    private static func commitExists(_ hash: String, workspaceURL: URL) -> Bool {
        // Exit 0 and nothing else. `allowedExitStatuses` widens what counts as
        // success, so listing git's "no such object" codes there would make
        // every invented hash resolve — the test caught exactly that.
        AppState.runGitCommand(
            arguments: ["cat-file", "-e", "\(hash)^{commit}"],
            in: workspaceURL
        ).succeeded
    }
}
