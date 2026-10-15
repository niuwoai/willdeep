import Foundation

nonisolated struct AgentRSIOfflineResult: Sendable {
    let candidate: AgentCanonicalJSON
    let experiment: AgentCanonicalJSON
    let admissions: [AgentCanonicalJSON]
    let evidence: [AgentCanonicalJSON]
    let haltReason: String?
    init(candidate: AgentCanonicalJSON, experiment: AgentCanonicalJSON, admissions: [AgentCanonicalJSON],
         evidence: [AgentCanonicalJSON], haltReason: String? = nil) {
        self.candidate = candidate; self.experiment = experiment; self.admissions = admissions
        self.evidence = evidence; self.haltReason = haltReason
    }
    var complete: Bool { haltReason == nil && evidence.count == experiment["dataset"]["tasks"].elements.count * 2 * (experiment["repetitions"].integer ?? 0)
        && evidence.allSatisfy { $0["status"].text == "passed" } }
    var document: AgentCanonicalJSON { .object(["schema": .string("willdeep.agent-rsi.offline-report.v1"),
        "scope": .string("mock_contract_fidelity_only"), "complete": .bool(complete), "candidate": candidate,
        "experiment": experiment, "admissions": .array(admissions), "evidence": .array(evidence),
        "halt_reason": haltReason.map(AgentCanonicalJSON.string) ?? .null]) }
    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try document.bytes.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let rows = evidence.map { "| \($0["task_id"].text ?? "") | \($0["arm"].text ?? "") | \($0["status"].text ?? "") | \($0["definition_revision"].text ?? "") |" }
        let markdown = "# Mac 原生 RSI 离线验收\n\n仅验证 mock 执行链与契约，不代表真实模型质量提升。\n\n完成：\(complete)\n\n停止原因：\(haltReason ?? "无")\n\n| 任务 | 对照臂 | 终态 | 实际版本哈希 |\n|---|---|---|---|\n" + rows.joined(separator: "\n") + "\n"
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("report.md"), options: .atomic)
    }
}

@MainActor enum AgentRSIOfflineRunner {
    static let verifier = "/usr/bin/grep -q '^RSI_FIXTURE_EVIDENCE_V1$' fixture.txt"
    static func golden() throws -> AgentCanonicalJSON { try AgentRSIContract.raw(AgentRSIContract.resource("AgentRSIGolden"))["values"] }
    static func candidate(baseline: AgentPackageV1, instructions: String, version: String) throws -> AgentCanonicalJSON {
        guard baseline.definition.definition_id.hasPrefix("user/"), baseline.signature == nil else { throw AgentRSIError.invalidContract }
        var definition = baseline.definition
        definition.instructions = instructions; definition.version = version; definition.forked_from = baseline.sha256
        let candidate = try AgentPackageV1.unsigned(definition)
        let value = AgentCanonicalJSON.object(["schema": .string("willdeep.agent-rsi.candidate.v1"),
            "candidate_id": .string("candidate-" + UUID().uuidString.lowercased()), "grant_id": .string("grant-" + UUID().uuidString.lowercased()),
            "baseline_package": try AgentRSIContract.raw(baseline.encoded()), "candidate_package": try AgentRSIContract.raw(candidate.encoded())])
        return try AgentRSIContract.parse(value.bytes, entity: "candidate")
    }
    static func spec(candidate: AgentCanonicalJSON) throws -> AgentCanonicalJSON {
        let sample = try golden()
        var spec = sample["experiment"].fields
        spec["experiment_id"] = .string("exp-" + UUID().uuidString.lowercased())
        spec["candidate_id"] = candidate["candidate_id"]; spec["grant_id"] = candidate["grant_id"]
        spec["definition_id"] = candidate["baseline_package"]["definition"]["definition_id"]
        spec["baseline_revision"] = candidate["baseline_package"]["sha256"]; spec["candidate_revision"] = candidate["candidate_package"]["sha256"]
        let executable = Bundle.main.executableURL
        let binary = try executable.map { try AgentPackageV1.hash(Data(contentsOf: $0)) } ?? AgentPackageV1.hash(Data())
        spec["runtime"] = .object(["adapter": .string("macos-native-worker.v1"),
            "product_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.420.0-rc1"),
            "commit": .string(ProcessInfo.processInfo.environment["WILLDEEP_RSI_SOURCE_COMMIT"] ?? "unavailable-local-build"), "binary_sha256": .string(binary), "platform": .string("macos"),
            "architecture": .string(ProcessInfo.processInfo.machineArchitecture)])
        let fixture = Data((AgentRSIOfflineProvider.token + "\n").utf8)
        let hash: (Data) -> AgentCanonicalJSON = { .string(AgentPackageV1.hash($0)) }
        var dataset = sample["experiment"]["dataset"].fields
        let tasks = ["validation", "regression", "holdout"].map { split in AgentCanonicalJSON.object([
            "task_id": .string(split + "-1"), "split": .string(split), "task_sha256": hash(Data(("Read fixture.txt for " + split).utf8))]) }
        dataset["tasks"] = .array(tasks); dataset["suite_sha256"] = hash(AgentCanonicalJSON.array(tasks).bytes)
        dataset["fixture_sha256"] = hash(fixture); dataset["verifier_sha256"] = hash(Data(verifier.utf8))
        dataset["split_sha256"] = hash(AgentCanonicalJSON.array(tasks.map { $0["split"] }).bytes)
        spec["dataset"] = .object(dataset)
        let definition = try AgentPackageV1.decode(candidate["baseline_package"].bytes).definition
        let baselinePackage = try AgentPackageV1.decode(candidate["baseline_package"].bytes)
        guard let effective = try AgentDefinitionLibrary.project(baselinePackage, binding: .inheritsParent).asSubagentProfile() else { throw AgentRSIError.invalidContract }
        let skills = AgentCanonicalJSON.array(try definition.skills.map { skill in try AgentRSIContract.raw(JSONEncoder().encode(skill)) })
        let parameters = try AgentRSIContract.raw(JSONEncoder().encode(AgentRuntimeParameters(maxTurns: 4, tokenBudget: 100000)))
        spec["budget"] = sample["experiment"]["budget"].replacing("max_tokens", .integer(100000))
        spec["conditions"] = .object(["runtime_parameters_sha256": hash(parameters.bytes),
            "tools_sha256": hash(AgentCanonicalJSON.array(effective.effectiveToolNames(writeAccessGranted: false).sorted().map(AgentCanonicalJSON.string)).bytes),
            "skills_sha256": hash(skills.bytes), "workspace_sha256": hash(fixture),
            "rules_sha256": hash(Data()), "memory_sha256": hash(Data())])
        spec["gate"] = .object(["gate_id": .string("mac-native-offline-v1"), "gate_sha256": hash(Data("actual-read+grep+report+unchanged-fixture".utf8))])
        spec["model"] = sample["experiment"]["model"]
            .replacing("parameters_sha256", hash(AgentCanonicalJSON.object(["context_window": .integer(32768), "max_turns": .integer(4), "routing": .string("flash"), "transport": .string("openai-chat-mock")]).bytes))
            .replacing("routing_policy_sha256", hash(Data("mock-only/no-escalation/no-network".utf8)))
        let value = try AgentRSIContract.parse(AgentCanonicalJSON.object(spec).bytes, entity: "experiment")
        try AgentRSIContract.bind(candidate: candidate, experiment: value)
        return value
    }
    static func run(candidate: AgentCanonicalJSON, directory: URL) async throws -> AgentRSIOfflineResult {
        _ = try AgentRSIContract.parse(candidate.bytes, entity: "candidate")
        let experiment = try spec(candidate: candidate)
        return try await run(candidate: candidate, experiment: experiment, directory: directory)
    }
    static func run(candidate: AgentCanonicalJSON, experiment: AgentCanonicalJSON, directory: URL) async throws -> AgentRSIOfflineResult {
        _ = try AgentRSIContract.parse(experiment.bytes, entity: "experiment")
        try AgentRSIContract.offline(experiment) // before any transport or workspace operation
        try AgentRSIContract.bind(candidate: candidate, experiment: experiment)
        guard experiment["execution_mode"].text == "direct", let repetitions = experiment["repetitions"].integer else { throw AgentRSIError.invalidContract }
        // Freeze registration before the first admission/request. A crash
        // therefore leaves a joinable manifest instead of detached events.
        try AgentRSIPrivateFiles.writeImmutable(candidate.bytes, to: directory.appendingPathComponent("candidate.json"))
        try AgentRSIPrivateFiles.writeImmutable(experiment.bytes, to: directory.appendingPathComponent("experiment.json"))
        var ledger = AgentRSIAdmissionLedger(experiment: experiment), evidence: [AgentCanonicalJSON] = []
        let order = ["validation": 0, "regression": 1, "holdout": 2]
        let tasks = experiment["dataset"]["tasks"].elements.sorted {
            let left = order[$0["split"].text ?? ""] ?? 3, right = order[$1["split"].text ?? ""] ?? 3
            return left == right ? ($0["task_id"].text ?? "") < ($1["task_id"].text ?? "") : left < right
        }
        var haltReason: String?
        do {
          for task in tasks {
            for arm in ["baseline", "candidate"] {
              for repetition in 1...repetitions {
                try Task.checkCancellation()
                let admission = try admission(task: task, arm: arm, repetition: repetition)
                var proposed = ledger
                try proposed.admit(admission)
                try AgentRSIHoldoutQuota(directory: directory.deletingLastPathComponent().appendingPathComponent("holdout-quota"))
                    .reserve(experiment: experiment, admission: admission)
                let trialDirectory = directory.appendingPathComponent(admission["trial_id"].text!)
                // A durable admission precedes the first Worker request.
                try FileManager.default.createDirectory(at: trialDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try AgentRSIPrivateFiles.writeImmutable(admission.bytes, to: trialDirectory.appendingPathComponent("admission.json"))
                ledger = proposed
                let item = try await trial(candidate: candidate, experiment: experiment, task: task, admission: admission, directory: trialDirectory)
                try AgentRSIContract.bind(candidate: candidate, experiment: experiment, evidence: item)
                try AgentRSIPrivateFiles.writeImmutable(item.bytes, to: trialDirectory.appendingPathComponent("evidence.json"))
                try ledger.finish(item); evidence.append(item)
              }
            }
          }
        } catch {
            if error is CancellationError { haltReason = "interrupted" }
            else if error as? AgentRSIError == .quota { haltReason = "budget_exhausted" }
            else if error as? AgentRSIError == .missingEvidence { haltReason = "stage_gate_rejected" }
            else { haltReason = "evidence_incomplete" }
        }
        let result = AgentRSIOfflineResult(candidate: candidate, experiment: experiment, admissions: ledger.admissions,
            evidence: evidence, haltReason: haltReason)
        try result.write(to: directory); return result
    }
    private static func admission(task: AgentCanonicalJSON, arm: String, repetition: Int) throws -> AgentCanonicalJSON {
        try AgentRSIContract.parse(AgentCanonicalJSON.object(["schema": .string("willdeep.agent-rsi.admission.v1"),
            "trial_id": .string("trial-" + UUID().uuidString.lowercased()), "task_id": task["task_id"], "arm": .string(arm),
            "repetition": .integer(repetition), "attempt": .integer(1), "resume_of": .null, "estimated_cost_microusd": .integer(0)]).bytes, entity: "admission")
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
