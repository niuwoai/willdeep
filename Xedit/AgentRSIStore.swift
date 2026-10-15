import Foundation

/// Separate from installations and their selected/pinned heads. Each account
/// receives a different directory; switching accounts never merges drafts.
nonisolated struct AgentRSIStore: Sendable {
    let root: URL
    let owner: String
    var directory: URL { root.appendingPathComponent(AgentPackageV1.hash(Data(owner.utf8))) }
    static func local(owner: String) -> Self {
        Self(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WillDeep/AgentRSI/v1"), owner: owner)
    }
    func save(_ value: AgentCanonicalJSON, entity: String) throws {
        _ = try AgentRSIContract.parse(value.bytes, entity: entity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(entity + "-" + AgentPackageV1.hash(value.bytes) + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            guard try Data(contentsOf: path) == value.bytes else { throw AgentAssetError.immutableVersion }; return
        }
        try AgentRSIPrivateFiles.writeImmutable(value.bytes, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func values(entity: String) throws -> [AgentCanonicalJSON] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix(entity + "-") && $0.pathExtension == "json" }
            .map { url in
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AgentRSIError.invalidContract }
                return try AgentRSIContract.parse(Data(contentsOf: url), entity: entity)
            }
    }
    func saveReceipt(_ receipt: AgentRSIReceipt) throws {
        let path = directory.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let value = AgentCanonicalJSON.object(["id": .string(receipt.id), "sha256": .string(receipt.sha256),
            "document": receipt.document, "revoked": .bool(receipt.revoked)])
        try value.bytes.write(to: path.appendingPathComponent(AgentPackageV1.hash(value.bytes) + ".json"), options: .atomic)
    }
}

nonisolated struct AgentRSIReceipt: Sendable {
    let id: String
    let sha256: String
    let document: AgentCanonicalJSON
    let revoked: Bool
    init(_ value: AgentCanonicalJSON, entity: String) throws {
        guard let id = value["id"].text, let hash = value["sha256"].text, AgentPackageV1.isHash(hash) else { throw AgentAssetError.server }
        document = try AgentRSIContract.parse(value["document"].bytes, entity: entity)
        guard AgentPackageV1.hash(document.bytes) == hash else { throw AgentAssetError.invalidHash }
        self.id = id; sha256 = hash; revoked = value["revoked"] == .bool(true)
    }
}

nonisolated struct AgentRSIService: Sendable {
    let registry: AgentRegistryService
    static func pathSegment(_ id: String) throws -> String {
        guard id.range(of: "^[a-zA-Z0-9._:/-]{1,128}$", options: .regularExpression) != nil,
              let segment = id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { throw AgentRSIError.invalidContract }
        return segment
    }
    func revokeGrant(_ id: String) async throws -> AgentRSIReceipt {
        let response = try await registry.request("customer/agent-rsi/grants/" + Self.pathSegment(id), method: "DELETE", encodedPath: true)
        let receipt = try AgentRSIReceipt(registry.businessValue(response), entity: "grant")
        guard receipt.document["grant_id"].text == id, receipt.revoked else { throw AgentAssetError.server }
        return receipt
    }
    func create(_ document: AgentCanonicalJSON, entity: String, experimentID: String? = nil) async throws -> AgentRSIReceipt {
        _ = try AgentRSIContract.parse(document.bytes, entity: entity)
        let route: String
        switch entity {
        case "grant": route = "grants"
        case "candidate": route = "candidates"
        case "experiment": route = "experiments"
        case "admission", "evidence":
            guard let experimentID else { throw AgentRSIError.invalidContract }
            route = "experiments/" + (try Self.pathSegment(experimentID)) + (entity == "admission" ? "/admissions" : "/evidence")
        default: throw AgentRSIError.invalidContract
        }
        let data = try await registry.request("customer/agent-rsi/" + route, method: "POST", body: document.bytes, encodedPath: true)
        let receipt = try AgentRSIReceipt(registry.businessValue(data), entity: entity)
        let expected = entity == "evidence" ? document.replacing("trust", .string("client_reported")) : document
        guard receipt.document == expected, !receipt.revoked else { throw AgentAssetError.server }
        return receipt
    }
    func list(_ entity: String, experimentID: String? = nil) async throws -> [AgentRSIReceipt] {
        let route: String
        if entity == "evidence", let experimentID {
            route = "experiments/" + (try Self.pathSegment(experimentID)) + "/evidence"
        } else {
            guard ["grant", "candidate", "experiment"].contains(entity) else { throw AgentRSIError.invalidContract }
            route = entity + "s"
        }
        return try registry.businessValue(await registry.request("customer/agent-rsi/" + route, encodedPath: true))["items"].elements
            .map { try AgentRSIReceipt($0, entity: entity) }
    }
}

/// Admissions are durable before execution and never refunded after a crash.
/// A retry is another segment of the same sample, not an independent score.
nonisolated struct AgentRSIAdmissionLedger {
    let experiment: AgentCanonicalJSON
    private(set) var admissions: [AgentCanonicalJSON] = []
    private(set) var terminal: Set<String> = []
    private(set) var successful: Set<String> = []
    private(set) var terminalStatuses: [String: String] = [:]
    private var terminalDigests: [String: String] = [:]
    mutating func admit(_ admission: AgentCanonicalJSON) throws {
        _ = try AgentRSIContract.parse(admission.bytes, entity: "admission")
        try AgentRSIContract.offline(experiment)
        if let old = admissions.first(where: { $0["trial_id"] == admission["trial_id"] }) {
            guard old == admission else { throw AgentAssetError.conflict }; return
        }
        guard experiment["dataset"]["tasks"].elements.contains(where: { $0["task_id"] == admission["task_id"] }),
              (admission["repetition"].integer ?? Int.max) <= (experiment["repetitions"].integer ?? 0),
              (admission["attempt"].integer ?? Int.max) <= (experiment["budget"]["max_attempts"].integer ?? 0),
              admissions.filter({ !terminal.contains($0["trial_id"].text ?? "") }).count < (experiment["budget"]["max_parallel_trials"].integer ?? 0) else { throw AgentRSIError.quota }
        let lineage = admissions.filter { $0["arm"] == admission["arm"] && $0["task_id"] == admission["task_id"] && $0["repetition"] == admission["repetition"] }
        guard admission["attempt"].integer == lineage.count + 1,
              admission["resume_of"] == (lineage.last?["trial_id"] ?? .null),
              lineage.last.map({ terminal.contains($0["trial_id"].text ?? "") }) ?? true else { throw AgentRSIError.invalidContract }
        if let previous = lineage.last?["trial_id"].text {
            guard ["interrupted", "infra_error"].contains(terminalStatuses[previous] ?? "") else { throw AgentRSIError.invalidContract }
        }
        let holdoutIDs = Set(experiment["dataset"]["tasks"].elements.filter { $0["split"].text == "holdout" }.map { $0["task_id"].canonical })
        if holdoutIDs.contains(admission["task_id"].canonical) {
            for task in experiment["dataset"]["tasks"].elements where task["split"].text != "holdout" {
                for arm in ["baseline", "candidate"] {
                    for repetition in 1...(experiment["repetitions"].integer ?? 1) {
                        let latest = admissions.last { $0["task_id"] == task["task_id"] && $0["arm"].text == arm && $0["repetition"].integer == repetition }
                        guard let id = latest?["trial_id"].text, successful.contains(id) else { throw AgentRSIError.missingEvidence }
                    }
                }
            }
        }
        if holdoutIDs.contains(admission["task_id"].canonical), admissions.filter({ holdoutIDs.contains($0["task_id"].canonical) }).count >= (experiment["budget"]["max_holdout_accesses"].integer ?? 0) { throw AgentRSIError.quota }
        admissions.append(admission)
    }
    mutating func finish(_ evidence: AgentCanonicalJSON) throws {
        _ = try AgentRSIContract.parse(evidence.bytes, entity: "evidence")
        guard let trial = evidence["trial_id"].text, let admission = admissions.first(where: { $0["trial_id"] == evidence["trial_id"] }),
              ["task_id", "arm", "repetition", "attempt", "resume_of"].allSatisfy({ admission[$0] == evidence[$0] }),
              evidence["finished_at"] != .null else { throw AgentRSIError.invalidContract }
        let digest = AgentPackageV1.hash(evidence.bytes)
        if let previous = terminalDigests[trial] {
            guard previous == digest else { throw AgentAssetError.conflict }; return
        }
        terminalDigests[trial] = digest
        terminal.insert(trial)
        terminalStatuses[trial] = evidence["status"].text
        if evidence["status"].text == "passed" { successful.insert(trial) }
    }
}
