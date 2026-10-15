import Foundation
import Darwin

/// Holdout access is monotonic across experiments sharing one local owner,
/// grant and frozen suite. New experiment IDs and interrupted runs cannot
/// reset it. The service independently enforces the same authenticated bound.
nonisolated struct AgentRSIHoldoutQuota {
    let directory: URL
    private static let lock = NSRecursiveLock()
    func reserve(experiment: AgentCanonicalJSON, admission: AgentCanonicalJSON) throws {
        guard experiment["dataset"]["tasks"].elements.contains(where: { $0["task_id"] == admission["task_id"] && $0["split"].text == "holdout" }) else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.appendingPathComponent(".quota.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentRSIError.quota }
        defer { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AgentRSIError.quota }
        let key = AgentPackageV1.hash(Data((experiment["grant_id"].canonical + "\n" + experiment["dataset"]["suite_sha256"].canonical).utf8))
        let path = directory.appendingPathComponent(key + ".json")
        var state = AgentCanonicalJSON.object(["limit": experiment["budget"]["max_holdout_accesses"], "trials": .array([])])
        if FileManager.default.fileExists(atPath: path.path) { state = try AgentRSIContract.raw(Data(contentsOf: path)) }
        let trial = admission["trial_id"]
        if state["trials"].elements.contains(trial) { return }
        let limit = min(state["limit"].integer ?? 0, experiment["budget"]["max_holdout_accesses"].integer ?? 0)
        guard state["trials"].elements.count < limit else { throw AgentRSIError.quota }
        state = state.replacing("limit", .integer(limit)).replacing("trials", .array(state["trials"].elements + [trial]))
        try state.bytes.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
