import Foundation
import CryptoKit
import Darwin

/// Durable, host-authored completion state. Provider output supplies verdict
/// proposals only; the host validates IDs, evidence kinds and input stability.
nonisolated struct AgentGoalVerification: Codable, Equatable {
    enum Phase: String, Codable { case pending, verifying, rejected, verified }
    let id: UUID
    let messageID: UUID
    let contractDigest: String
    let criterionIDs: [UUID]
    var workspacePath: String? = nil
    var attributedPaths: [String]? = nil
    var phase: Phase = .pending
    var findings: [String] = []
    var receipts: [Receipt] = []
    var evidence: [Evidence] = []

    struct Receipt: Codable, Equatable {
        let criterionID: UUID
        let evidenceIDs: [UUID]
        let inputDigests: [String: String]
        let workspacePath: String
        let verifiedAt: Date
    }

    struct Evidence: Codable, Equatable {
        enum Kind: String, Codable { case source, artifact, command, image, interaction }
        let id: UUID
        let kind: Kind
        let label: String
        let content: String
        let exitCode: Int32?
    }

    struct Review: Codable {
        let verdicts: [Verdict]
        struct Verdict: Codable {
            enum Kind: String, Codable { case code, analysis, artifact, interface }
            let criterionID: UUID
            let kind: Kind
            let passed: Bool
            let evidenceIDs: [UUID]
            let detail: String
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func contractDigest(_ goal: AgentGoal) -> String {
        // Byte-length-prefixed fields, rather than delimiter concatenation, bind
        // the objective, order and IDs without ambiguous criterion strings.
        let fields = [goal.statement] + goal.checklist.flatMap { [$0.id.uuidString, $0.text] }
        return digest(Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }

    func validate(review: Review, evidence: [Evidence], requiresCodeVerification: Bool) -> [String] {
        let requested = Set(criterionIDs)
        let returned = review.verdicts.map(\.criterionID)
        guard returned.count == requested.count, Set(returned) == requested else {
            return ["The reviewer did not return exactly one verdict for each requested criterion."]
        }
        guard Set(evidence.map(\.id)).count == evidence.count else { return ["Duplicate host evidence identifiers."] }
        let available = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        var failures: [String] = []
        for verdict in review.verdicts {
            let cited = verdict.evidenceIDs.compactMap { available[$0] }
            guard verdict.passed, !verdict.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cited.isEmpty, cited.count == verdict.evidenceIDs.count,
                  Set(verdict.evidenceIDs).count == verdict.evidenceIDs.count else {
                failures.append("\(verdict.criterionID): \(verdict.detail.isEmpty ? "Missing or invalid evidence." : verdict.detail)")
                continue
            }
            let kinds = Set(cited.map(\.kind))
            if (verdict.kind == .code || requiresCodeVerification),
               !cited.contains(where: { $0.kind == .command && $0.exitCode == 0 }) {
                failures.append("\(verdict.criterionID): No completed host verification command supports this code change.")
            }
            switch verdict.kind {
            case .analysis:
                if !kinds.contains(.source) { failures.append("\(verdict.criterionID): Analysis needs inspected source evidence.") }
            case .artifact, .code:
                if !kinds.contains(.artifact) && !kinds.contains(.source) {
                    failures.append("\(verdict.criterionID): Missing inspected file or artifact evidence.")
                }
            case .interface:
                if !kinds.contains(.image) || !kinds.contains(.interaction) {
                    failures.append("\(verdict.criterionID): UI acceptance needs actual pixels and interaction receipts.")
                }
            }
        }
        return failures
    }
}

/// Bounded host reads are also the before/after stability boundary. No whole
/// workspace scan and no adoption of unrelated user edits. Deletions receive
/// an explicit tombstone; symlinks cannot escape the authorized root.
nonisolated enum AgentGoalEvidenceFiles {
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumTotalBytes = 32 * 1_024 * 1_024

    struct Snapshot: Sendable, Equatable {
        let digests: [String: String]
        let text: [String: String]
    }

    static func capture(root: URL, paths: [String]) async throws -> Snapshot {
        try await Task.detached(priority: .utility) {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard rootFD >= 0 else { throw Failure("Cannot open the authorized evidence root.") }
            defer { close(rootFD) }
            guard Set(paths).count <= 256 else { throw Failure("Too many evidence files; verify bounded acceptance groups.") }
            var digests: [String: String] = [:], text: [String: String] = [:]
            var total = 0
            for path in Set(paths).sorted() {
                try Task.checkCancellation()
                guard !path.isEmpty, !path.contains("\0") else { throw Failure("Invalid evidence path.") }
                let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
                let resolved = url.resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/"), resolved.path.hasPrefix(root.path + "/") else {
                    throw Failure("Evidence path is outside the authorized workspace.")
                }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                let components = relative.lowercased().split(separator: "/")
                guard !components.contains(where: { $0 == ".git" || $0 == ".ssh" || $0 == ".env" || $0.hasPrefix(".env.") }),
                      !["pem", "key", "p12", "pfx"].contains(url.pathExtension.lowercased()) else {
                    throw Failure("Sensitive files cannot be copied into completion evidence.")
                }
                guard let data = try readBeneath(rootFD: rootFD, components: relative.split(separator: "/").map(String.init)) else {
                    digests[relative] = "deleted"
                    text[relative] = "File absent (deletion evidence)."
                    continue
                }
                guard data.count <= maximumFileBytes else { throw Failure("Evidence file grew beyond the size limit.") }
                total += data.count
                guard total <= maximumTotalBytes else { throw Failure("Evidence exceeded the total size limit.") }
                digests[relative] = AgentGoalVerification.digest(data)
                let content = String(data: data, encoding: .utf8) ?? "Binary artifact; digest proves identity, not semantic correctness."
                text[relative] = content.count > 12_000
                    ? "[Partial evidence: first 12000 of \(content.count) characters; not the full file.]\n" + String(content.prefix(12_000))
                    : content
            }
            return Snapshot(digests: digests, text: text)
        }.value
    }

    /// Walk from an already-open root descriptor. A nonexistent final path
    /// must not hide an escaping symlink, and replacing a checked directory
    /// with a symlink cannot redirect a subsequent open outside this root.
    private static func readBeneath(rootFD: Int32, components: [String]) throws -> Data? {
        guard let filename = components.last else { throw Failure("Empty evidence path.") }
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else { throw Failure("Cannot retain the evidence root.") }
        defer { close(directoryFD) }
        for component in components.dropLast() {
            let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return nil }
                throw Failure("Evidence directory is inaccessible or contains a symbolic link.")
            }
            close(directoryFD)
            directoryFD = next
        }
        let descriptor = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Failure("Evidence file is inaccessible or is a symbolic link.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= maximumFileBytes else { throw Failure("Evidence must be a bounded regular file.") }
            let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            guard data.count == info.st_size else { throw Failure("Evidence file changed size or was only partially read.") }
            try handle.close()
            return data
        } catch {
            do { try handle.close() }
            catch { NSLog("WillDeep evidence handle cleanup failed: %@", error.localizedDescription) }
            throw error
        }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
