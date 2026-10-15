import Foundation

@MainActor enum AgentRSIApprovedTrial {
    static let suiteSHA256 = "281f7dadf99f4cf86c4de5a922cdac7531c933654f878bb6b8f532d502a96575"
    struct Input {
        let control: AgentCanonicalJSON
        let package: AgentPackageV1
        let task: AgentCanonicalJSON
        let directory: URL
        init(data: Data) throws {
            let control = try AgentRSIContract.raw(data)
            let keys = Set(["schema", "proposal_sha256", "experiment_id", "trial_id", "arm", "repetition", "attempt", "resume_of", "agent_package", "agent_revision", "suite", "suite_sha256", "task_id", "broker_origin", "capability", "output_directory"])
            guard Set(control.fields.keys) == keys, control["schema"].text == "willdeep.agent-rsi.native-trial-control.v1",
                  control["proposal_sha256"].text == AgentRSIApprovedBroker.proposalSHA256,
                  control["suite_sha256"].text == suiteSHA256,
                  ["baseline", "candidate"].contains(control["arm"].text ?? ""),
                  (1...3).contains(control["repetition"].integer ?? 0), (1...2).contains(control["attempt"].integer ?? 0),
                  (control["attempt"].integer == 1 ? control["resume_of"] == .null : control["resume_of"].text != nil),
                  let packagePath = control["agent_package"].text, let suitePath = control["suite"].text,
                  let output = control["output_directory"].text,
                  AgentRSIApprovedTrial.permittedOutput(output) else { throw AgentRSIError.paidNotApproved }
            let package = try AgentPackageV1.decode(Data(contentsOf: URL(fileURLWithPath: packagePath)))
            let golden = try AgentRSIOfflineRunner.golden()["candidate"]
            guard package.sha256 == control["agent_revision"].text,
                  package.sha256 == golden[(control["arm"].text ?? "") + "_package"]["sha256"].text else { throw AgentRSIError.paidNotApproved }
            let suite = try AgentRSIContract.raw(Data(contentsOf: URL(fileURLWithPath: suitePath)))
            guard AgentPackageV1.hash(suite.bytes) == suiteSHA256, suite["suite_id"].text == "reviewer-original-24-v1",
                  suite["tasks"].elements.count == 24,
                  let task = suite["tasks"].elements.first(where: { $0["task_id"] == control["task_id"] }),
                  task["fixture"].text != nil, task["prompt"].text != nil else { throw AgentRSIError.invalidContract }
            self.control = control; self.package = package; self.task = task; self.directory = URL(fileURLWithPath: output)
        }
        func broker(session: URLSession? = nil, previewOnly: Bool = false) throws -> AgentRSIApprovedBroker {
            try .init(origin: try requireText("broker_origin"), capability: try requireText("capability"),
                      trialID: try requireText("trial_id"), session: session, previewOnly: previewOnly)
        }
        private func requireText(_ key: String) throws -> String {
            guard let value = control[key].text, !value.isEmpty else { throw AgentRSIError.invalidContract }; return value
        }
    }
    private static func profile(_ input: Input) throws -> AgentSubagentProfile {
        guard var profile = try AgentDefinitionLibrary.project(input.package, binding: .inheritsParent).asSubagentProfile() else { throw AgentRSIError.invalidContract }
        profile.maxRounds = 4; profile.escalation = .none; profile.modelBinding.contextWindowTokens = 32768
        return profile
    }
    private static func permittedOutput(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        // Foundation does not resolve /tmp when a suffix does not yet exist.
        // Resolve the nearest existing ancestor, then enforce the temp root.
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/", (try? FileManager.default.attributesOfItem(atPath: ancestor.path)) == nil else { return false }
            ancestor.deleteLastPathComponent()
        }
        let resolved = ancestor.resolvingSymlinksInPath().path
        // Foundation also presents an existing /private/tmp as /tmp on macOS.
        return ["/tmp", "/private/tmp"].contains(resolved)
            || resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/")
    }
    static func preview(_ input: Input) async throws -> Data {
        _ = try await run(input, previewOnly: true)
        return try Data(contentsOf: input.directory.appendingPathComponent("first_request.json"))
    }
    static func run(_ input: Input, session: URLSession? = nil, previewOnly: Bool = false) async throws -> AgentCanonicalJSON {
        guard !FileManager.default.fileExists(atPath: input.directory.path) else { throw AgentAssetError.immutableVersion }
        let profile = try profile(input), broker = try input.broker(session: session, previewOnly: previewOnly)
        defer { broker.close() }
        let rootID = UUID(), workerID = UUID(), started = Date()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("willdeep-rsi-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: workspace) }
        let home = input.directory.appendingPathComponent("home")
        for directory in [workspace, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fixture = Data(input.task["fixture"].text!.utf8)
        try AgentRSIPrivateFiles.writeImmutable(fixture, to: workspace.appendingPathComponent("fixture.txt"))
        let store = AgentExecutionEvidenceStore(root: input.directory.appendingPathComponent("events"))
        var seed = AgentExecutionEvidenceEvent(runID: rootID, rootRunID: rootID, mode: "approved_review_experiment", kind: "started")
        seed.experimentID = input.control["experiment_id"].text; seed.trialID = input.control["trial_id"].text
        seed.arm = input.control["arm"].text; seed.tasksetSHA256 = suiteSHA256
        let trace = AgentExecutionTrace(store: store, seed: seed)
        let ledger = AgentModelRequestLedger(directory: home.appendingPathComponent("requests"), ownerID: rootID)
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 120, maximumContinuations: 0, segmentStartedAt: started), requestLedger: ledger)
        var outcome: AgentSubagentRunner.Outcome?, failure: Error?
        trace.record("started")
        do {
            outcome = try await AgentExecutionTrace.$current.withValue(trace) {
                try await AgentRSIApprovedBroker.$current.withValue(broker) {
                    try await AgentSubagentRunner.run(prompt: input.task["prompt"].text!, configuration: broker.configuration(), workspaceURL: workspace,
                        profile: profile, executionBudget: budget, evidenceRunID: workerID, evidenceMode: "approved_review_worker", firstContactTimeout: 120)
                }
            }
        } catch { failure = error }
        let status = failure == nil ? outcome?.evidenceStatus ?? "infra_error" : errorStatus(failure)
        trace.record("finished") {
            $0.status = status; $0.terminationReason = outcome?.terminationReason.rawValue; $0.roundCount = outcome?.roundCount
        }
        let events = try store.events(), worker = events.filter { $0.runID == workerID }
        let fixtureReads = Set((outcome?.rounds.flatMap(\.toolCalls) ?? []).compactMap { call -> String? in
            guard call.name == "read_file", let args = try? AgentRSIContract.raw(Data(call.argumentsJSON.utf8)),
                  let path = args["path"].text,
                  ["fixture.txt", workspace.appendingPathComponent("fixture.txt").path].contains(path) else { return nil }
            return AgentPackageV1.hash(Data(call.result.utf8))
        })
        let read = worker.contains { $0.kind == "tool_receipt" && $0.toolName == "read_file" && $0.toolSucceeded == true
            && broker.observedToolPayloads.contains($0.promptSHA256 ?? "") && fixtureReads.contains($0.promptSHA256 ?? "") }
        let unchanged = (try? Data(contentsOf: workspace.appendingPathComponent("fixture.txt"))) == fixture
        let raw = outcome?.rounds.last(where: { $0.toolCalls.isEmpty })?.content
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let eventBytes = try AgentRSIContract.raw(encoder.encode(events)).bytes
        let actualRevision = worker.first(where: { $0.kind == "started" })?.definition?.revision
        var result: [String: AgentCanonicalJSON] = ["schema": .string("willdeep.agent-rsi.native-trial-observation.v1"),
            "platform": .string("macos-native-worker"), "proposal_sha256": input.control["proposal_sha256"],
            "raw_model_content": raw.map(AgentCanonicalJSON.string) ?? .null,
            "worker_report": outcome.map { .string($0.report) } ?? .null, "read_observed": .bool(read),
            "fixture_unchanged": .bool(unchanged), "did_truncate": .bool(outcome?.didTruncate ?? false),
            "root_run_id": .string(rootID.uuidString.lowercased()), "worker_run_id": .string(workerID.uuidString.lowercased()),
            "definition_revision": .string(input.package.sha256), "task_sha256": .string(AgentPackageV1.hash(input.task.bytes)),
            "loaded_revision": actualRevision.map(AgentCanonicalJSON.string) ?? .null,
            "fixture_sha256": .string(AgentPackageV1.hash(fixture)), "events_sha256": .string(AgentPackageV1.hash(eventBytes)),
            "effective_prompt_sha256": worker.first(where: { $0.kind == "prompt_prepared" })?.promptSHA256.map(AgentCanonicalJSON.string) ?? .null,
            "input_tokens": AgentRSIUsage.sum(worker, keyPath: \.inputTokens), "output_tokens": AgentRSIUsage.sum(worker, keyPath: \.outputTokens),
            "status": .string(status), "model": .string(AgentRSIApprovedBroker.model),
            "termination_reason": outcome.map { .string($0.terminationReason.rawValue) } ?? .null,
            "round_count": outcome.map { .integer($0.roundCount) } ?? .null,
            "elapsed_ms": .integer(max(0, Int(Date().timeIntervalSince(started) * 1000))),
            "events": try AgentRSIContract.raw(eventBytes), "grading": .string("host_only_pending")]
        result["request_receipts"] = .array(broker.receipts)
        if let body = broker.firstRequest {
            try AgentRSIPrivateFiles.writeImmutable(body, to: input.directory.appendingPathComponent("first_request.json"))
            result["first_request_sha256"] = .string(AgentPackageV1.hash(body))
        }
        result["verifier"] = .object(["verifier_id": .string("mac-native-read-integrity-v1"),
            "input_sha256": .string(AgentPackageV1.hash(Data((raw ?? "").utf8) + fixture)),
            "read_observed": .bool(read), "fixture_unchanged": .bool(unchanged),
            "result": .string(read && unchanged && actualRevision == input.package.sha256 ? "passed" : "unverified")])
        result["runtime"] = .object(["adapter": .string("macos-native-worker.v1"),
            "product_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            "commit": .string(ProcessInfo.processInfo.environment["WILLDEEP_RSI_SOURCE_COMMIT"] ?? "unavailable-local-build"),
            "binary_sha256": .string(try Bundle.main.executableURL.map { AgentPackageV1.hash(try Data(contentsOf: $0)) } ?? "unavailable")])
        for key in ["experiment_id", "trial_id", "arm", "repetition", "attempt", "resume_of", "suite_sha256", "task_id"] { result[key] = input.control[key] }
        let observation = AgentCanonicalJSON.object(result)
        try AgentRSIPrivateFiles.writeImmutable(observation.bytes, to: input.directory.appendingPathComponent("observation.json"))
        return observation
    }
    private static func errorStatus(_ error: Error?) -> String {
        if error is AgentRSIApprovedPreviewComplete { return "preview" }
        return error is CancellationError ? "interrupted" : "infra_error"
    }
}
