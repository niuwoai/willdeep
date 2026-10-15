import Foundation

extension AgentRSIOfflineRunner {
    static func trial(candidate: AgentCanonicalJSON, experiment: AgentCanonicalJSON, task: AgentCanonicalJSON,
                      admission: AgentCanonicalJSON, directory: URL) async throws -> AgentCanonicalJSON {
        let started = Date(), runID = UUID(), rootID = UUID()
        let home = directory.appendingPathComponent("home"), workspace = directory.appendingPathComponent("workspace")
        for url in [home, workspace] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fixture = Data((AgentRSIOfflineProvider.token + "\n").utf8)
        try AgentRSIPrivateFiles.writeImmutable(fixture, to: workspace.appendingPathComponent("fixture.txt"))
        let package = try AgentPackageV1.decode(candidate[(admission["arm"].text ?? "") + "_package"].bytes)
        let projected = try AgentDefinitionLibrary.project(package, binding: .inheritsParent)
        guard var profile = projected.asSubagentProfile() else { throw AgentRSIError.invalidContract }
        profile.maxRounds = experiment["budget"]["max_turns"].integer ?? 4
        profile.escalation = .none; profile.modelBinding.contextWindowTokens = 32768
        let host = runID.uuidString.lowercased() + "." + AgentRSIOfflineProvider.host
        let configuration = AgentConfiguration(providerID: "mock", baseURL: "https://" + host + "/v1",
            model: experiment["model"]["model"].text!, routingMode: .flash, apiKey: "offline-placeholder")
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [AgentRSIOfflineProvider.self]
        let session = URLSession(configuration: transport); defer { session.invalidateAndCancel() }
        let store = AgentExecutionEvidenceStore(root: directory.appendingPathComponent("events"))
        var root = AgentExecutionEvidenceEvent(runID: rootID, rootRunID: rootID, mode: "direct_experiment", kind: "started",
            provider: "mock", model: configuration.model)
        root.runtimeParameters = AgentRuntimeParameters(maxTurns: profile.maxRounds, tokenBudget: experiment["budget"]["max_tokens"].integer)
        root.arm = admission["arm"].text; root.tasksetSHA256 = experiment["dataset"]["suite_sha256"].text
        root.experimentID = experiment["experiment_id"].text; root.trialID = admission["trial_id"].text
        let trace = AgentExecutionTrace(store: store, seed: root)
        AgentRSIOfflineProvider.register(host: host, trace: trace)
        defer { AgentRSIOfflineProvider.unregister(host: host) }
        trace.record("started")
        let requests = AgentModelRequestLedger(directory: home.appendingPathComponent("requests"), ownerID: rootID)
        _ = try requests.setAdmissionLimit(experiment["budget"]["max_tokens"].integer, expectedRevision: 0)
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: TimeInterval(experiment["budget"]["timeout_seconds"].integer ?? 60),
            maximumContinuations: 0, segmentStartedAt: started), requestLedger: requests)
        // Fixed clean environment for the only spawned subprocess. The native Worker is
        // called directly, so no user session, feedback ledger, timing log,
        // account profile or global usage counter is opened by this runner.
        let command = "env -i PATH=/usr/bin:/bin " + verifier
        var outcome: AgentSubagentRunner.Outcome?, failure: Error?
        do {
            outcome = try await AgentExecutionTrace.$current.withValue(trace) {
                try await AgentRSIOfflineProvider.withTransport(session: session, host: host) {
                    try await AgentSubagentRunner.run(prompt: "Read fixture.txt for " + (task["split"].text ?? "") + ". Report the exact evidence token and reproduction.",
                        configuration: configuration, workspaceURL: workspace, profile: profile, verifierCommand: command, verifierMaxAttempts: 1,
                        executionBudget: budget, evidenceRunID: runID, evidenceMode: "direct_experiment_worker", session: session, firstContactTimeout: 10)
                }
            }
        } catch { failure = error }
        trace.record("finished") { $0.status = failure == nil ? "unverified" : "infra_error" }
        let events = try store.events(), workerEvents = events.filter { $0.runID == runID }
        let workerStart = workerEvents.first { $0.kind == "started" }
        let prompt = workerEvents.first { $0.kind == "prompt_prepared" }?.promptSHA256
        let observed = Set(events.filter { $0.kind == "fixture_tool_result_observed" }.compactMap(\.promptSHA256))
        let actualTarget = workerEvents.contains {
            $0.kind == "tool_receipt" && $0.toolName == "read_file" && $0.toolSucceeded == true && observed.contains($0.promptSHA256 ?? "")
        }
        let unchanged = (try? Data(contentsOf: workspace.appendingPathComponent("fixture.txt"))) == fixture
        let verified = outcome?.verifierPassed == true && outcome?.report.contains(AgentRSIOfflineProvider.token) == true && unchanged
        let finished = workerEvents.last { $0.kind == "finished" }
        let loadedRevision = workerStart?.definition?.revision == package.sha256
        let loadedSkills = workerStart?.skillsSHA256 == experiment["conditions"]["skills_sha256"].text
        let toolsHash = workerStart?.effectiveTools.map { AgentPackageV1.hash(AgentCanonicalJSON.array($0.map(AgentCanonicalJSON.string)).bytes) }
        let loadedTools = toolsHash == experiment["conditions"]["tools_sha256"].text
        let complete = actualTarget && verified && loadedRevision && loadedSkills && loadedTools && prompt != nil && finished != nil && failure == nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let eventBytes = try AgentRSIContract.raw(encoder.encode(events)).bytes
        let modelRoute = workerEvents.filter { $0.kind == "request_started" }.map { AgentCanonicalJSON.object([
            "provider": .string($0.provider ?? "unknown"), "model": .string($0.model ?? "unknown"), "model_revision": .null]) }
        let date = ISO8601DateFormatter()
        var value = admission.fields
        value.removeValue(forKey: "estimated_cost_microusd")
        value["schema"] = .string("willdeep.agent-rsi.evidence.v1"); value["experiment_id"] = experiment["experiment_id"]
        value["task_sha256"] = task["task_sha256"]; value["split"] = task["split"]
        value["root_run_id"] = .string(rootID.uuidString.lowercased())
        value["worker_run_id"] = finished.map { .string($0.runID.uuidString.lowercased()) } ?? .null
        value["definition_id"] = .string(package.definition.definition_id); value["definition_revision"] = .string(package.sha256)
        value["effective_prompt_sha256"] = .string(prompt ?? AgentPackageV1.hash(Data()))
        value["skills_sha256"] = experiment["conditions"]["skills_sha256"]
        for key in ["runtime", "model", "conditions", "budget"] { value[key] = experiment[key] }
        value["model_route"] = .array(modelRoute); value["dataset_sha256"] = experiment["dataset"]["suite_sha256"]
        value["fixture_sha256"] = experiment["dataset"]["fixture_sha256"]
        value["verifier"] = .object(["verifier_id": .string("mac-native-fixture-v1"),
            "verifier_sha256": experiment["dataset"]["verifier_sha256"],
            "input_sha256": .string(AgentPackageV1.hash(Data((outcome?.report ?? "").utf8) + fixture)),
            "result": .string(verified ? "passed" : "unverified"), "exit_code": outcome?.verifierPassed == true ? .integer(0) : .null])
        value["target_executed"] = .bool(actualTarget); value["started_at"] = .string(date.string(from: started))
        value["finished_at"] = finished.map { .string(date.string(from: $0.recordedAt)) } ?? .null
        value["status"] = .string(complete ? "passed" : (failure is CancellationError ? "interrupted" : failure == nil ? "unverified" : "infra_error"))
        value["usage"] = .object(["input_tokens": AgentRSIUsage.sum(workerEvents, keyPath: \.inputTokens),
            "output_tokens": AgentRSIUsage.sum(workerEvents, keyPath: \.outputTokens), "auxiliary_tokens": .null,
            "elapsed_ms": .integer(max(0, Int(Date().timeIntervalSince(started) * 1000))), "cost_microusd": .integer(0)])
        value["events_sha256"] = .string(AgentPackageV1.hash(eventBytes)); value["trust"] = .string("local_mock")
        return try AgentRSIContract.parse(AgentCanonicalJSON.object(value).bytes, entity: "evidence")
    }
}

nonisolated enum AgentRSIUsage {
    static func sum(_ events: [AgentExecutionEvidenceEvent], keyPath: KeyPath<AgentExecutionEvidenceEvent, Int?>) -> AgentCanonicalJSON {
        let requests = Set(events.filter { $0.kind == "request_started" }.compactMap(\.requestID))
        guard !requests.isEmpty else { return .null }
        var sum = 0
        for id in requests {
            guard let receipt = events.last(where: { $0.kind == "request_usage" && $0.requestID == id }),
                  let value = receipt[keyPath: keyPath], value >= 0 else { return .null }
            let addition = sum.addingReportingOverflow(value)
            guard !addition.overflow else { return .null }; sum = addition.partialValue
        }
        return .integer(sum)
    }
}
