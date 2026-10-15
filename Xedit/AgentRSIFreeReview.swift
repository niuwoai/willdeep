import Foundation

/// New public engineering fixture path. This does not accept customer
/// configuration, an endpoint, a capability, or the legacy live control v1.
@MainActor enum AgentRSIFreeReview {
    static let manifestSHA256 = "4cb96af334f1d8a7113240e8cbe7c4e275009d68233ce6cab52b67926ce05af3"
    static let contractSHA256 = "91b66fce5a84e96340573e43a0743c5d8205b02d228e9240a4947cc86dad163a"
    static func manifest() throws -> AgentCanonicalJSON {
        let data = try AgentRSIContract.resource("AgentRSIFreeReviewManifest")
        guard AgentPackageV1.hash(data) == manifestSHA256 else { throw AgentRSIError.invalidContract }
        return try AgentRSIContract.raw(data)
    }
    static func contract() throws -> AgentCanonicalJSON {
        let data = try AgentRSIContract.resource("AgentRSIFreeReviewContract")
        guard AgentPackageV1.hash(data) == contractSHA256 else { throw AgentRSIError.invalidContract }
        return try AgentRSIContract.raw(data)
    }
    static func run(caseID: String, directory: URL, executionMode: String = "offline_mock_only",
                    package requestedPackage: AgentPackageV1? = nil) async throws -> AgentCanonicalJSON {
        guard executionMode == "offline_mock_only", !FileManager.default.fileExists(atPath: directory.path), permittedOutput(directory) else {
            throw AgentRSIError.paidNotApproved
        }
        let golden = try AgentRSIOfflineRunner.golden()["candidate"]["baseline_package"]
        let package = try requestedPackage ?? AgentPackageV1.decode(golden.bytes)
        guard package.sha256 == golden["sha256"].text, Set(package.definition.tools).isSubset(of: ["workspace.read", "repository.inspect"]),
              package.definition.base_role == "reviewer" else { throw AgentRSIError.paidNotApproved }
        let manifest = try manifest(), contract = try contract()
        guard manifest["execution_mode"].text == "offline_mock_only", manifest["model_calls_authorized"].integer == 0,
              let task = manifest["tasks"].elements.first(where: { $0["case_id"].text == caseID }),
              let prompt = task["task_prompt"].text, let instructions = contract["instructions"].text,
              let fixtureURL = Bundle.main.url(forResource: caseID, withExtension: "js") else { throw AgentRSIError.invalidContract }
        let fixture = try Data(contentsOf: fixtureURL)
        guard fixture.count <= AgentRSIFreeReviewContract.maximumBytes,
              AgentPackageV1.hash(fixture) == task["fixture_sha256"].text,
              let fixtureText = String(data: fixture, encoding: .utf8),
              var profile = try AgentDefinitionLibrary.project(package, binding: .inheritsParent).asSubagentProfile() else { throw AgentRSIError.invalidContract }
        profile.maxRounds = 4; profile.escalation = .none; profile.modelBinding.contextWindowTokens = 32768
        // Mock answer is host public fixture data, never evidence of quality.
        let mockReport = AgentCanonicalJSON.object(["has_defect": task["has_defect"], "line": task["defect_line"],
            "reason": .string("Public deterministic mock fixture."), "reproduction": task["public_witness"]])
        _ = try AgentRSIFreeReviewContract.validate(mockReport.bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("willdeep-free-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentRSIPrivateFiles.writeImmutable(fixture, to: workspace.appendingPathComponent("fixture.txt"))
        let rootID = UUID(), workerID = UUID(), host = UUID().uuidString.lowercased() + ".free-review.agent-rsi.invalid"
        let store = AgentExecutionEvidenceStore(root: directory.appendingPathComponent("events"))
        let trace = AgentExecutionTrace(store: store, seed: .init(runID: rootID, rootRunID: rootID, mode: "free_review_v2", kind: "started"))
        AgentRSIOfflineProvider.register(host: host, trace: trace)
        AgentRSIFreeReviewProvider.register(host: host, context: .init(fixture: fixtureText, report: mockReport.canonical, instructions: instructions, trace: trace))
        defer { AgentRSIFreeReviewProvider.unregister(host: host); AgentRSIOfflineProvider.unregister(host: host) }
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [AgentRSIFreeReviewProvider.self]
        let session = URLSession(configuration: transport); defer { session.invalidateAndCancel() }
        let configuration = AgentConfiguration(providerID: "mock", baseURL: "https://" + host + "/v1", model: "free-review-v2", routingMode: .flash, apiKey: "offline-placeholder")
        let ledger = AgentModelRequestLedger(directory: directory.appendingPathComponent("requests"), ownerID: rootID)
        _ = try ledger.setAdmissionLimit(16000, expectedRevision: 0)
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 30, maximumContinuations: 0, segmentStartedAt: Date()), requestLedger: ledger)
        trace.record("started")
        let outcome = try await AgentExecutionTrace.$current.withValue(trace) {
            try await AgentRSIOfflineProvider.withTransport(session: session, host: host) {
                try await AgentSubagentRunner.run(prompt: prompt + "\n\n" + instructions, configuration: configuration, workspaceURL: workspace,
                    profile: profile, executionBudget: budget, evidenceRunID: workerID, evidenceMode: "free_review_v2_worker", session: session, firstContactTimeout: 10)
            }
        }
        trace.record("finished") { $0.status = outcome.evidenceStatus; $0.terminationReason = outcome.terminationReason.rawValue; $0.roundCount = outcome.roundCount }
        let events = try store.events(), worker = events.filter { $0.runID == workerID }, observed = AgentRSIFreeReviewProvider.snapshot(host: host)
        let actualReads = Set(outcome.rounds.flatMap(\.toolCalls).compactMap { call -> String? in
            guard call.name == "read_file", let args = try? AgentRSIContract.raw(Data(call.argumentsJSON.utf8)),
                  let path = args["path"].text, ["fixture.txt", workspace.appendingPathComponent("fixture.txt").path].contains(path) else { return nil }
            return AgentPackageV1.hash(Data(call.result.utf8))
        })
        let read = worker.contains { $0.kind == "tool_receipt" && $0.toolName == "read_file" && $0.toolSucceeded == true
            && actualReads.contains($0.promptSHA256 ?? "") && observed.observed.contains($0.promptSHA256 ?? "") }
        var firstParser = AgentCanonicalJSON.Parser(data: try observed.bodies.first.unwrap(), allowNumbers: true)
        let first = try firstParser.parse(), messages = first["messages"].elements
        let injected = messages.contains { $0["content"].text?.contains(instructions) == true }
        let definitionObserved = messages.contains { $0["content"].text?.contains(package.definition.instructions) == true }
        let raw = outcome.rounds.last(where: { $0.toolCalls.isEmpty })?.content ?? ""
        let schemaValid = (try? AgentRSIFreeReviewContract.validate(Data(raw.utf8))) != nil
        let unchanged = (try? Data(contentsOf: workspace.appendingPathComponent("fixture.txt"))) == fixture
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let eventBytes = try AgentRSIContract.raw(encoder.encode(events)).bytes
        let loadedRevision = worker.first(where: { $0.kind == "started" })?.definition?.revision
        let report = AgentCanonicalJSON.object([
            "schema": .string("willdeep.agent-rsi.free-review-observation.v2"), "execution_mode": .string("offline_mock_only"),
            "case_id": .string(caseID), "model_calls_authorized": .integer(0), "status": .string(outcome.evidenceStatus),
            "definition_revision": .string(package.sha256), "loaded_revision": loadedRevision.map(AgentCanonicalJSON.string) ?? .null,
            "contract_sha256": .string(contractSHA256), "instructions_sha256": .string(AgentPackageV1.hash(Data(instructions.utf8))),
            "definition_instructions_sha256": .string(AgentPackageV1.hash(Data(package.definition.instructions.utf8))),
            "instructions_observed": .bool(injected), "definition_instructions_observed": .bool(definitionObserved),
            "first_request_sha256": .string(AgentPackageV1.hash(try observed.bodies.first.unwrap())),
            "effective_prompt_sha256": worker.first(where: { $0.kind == "prompt_prepared" })?.promptSHA256.map(AgentCanonicalJSON.string) ?? .null,
            "host_evidence": .object(["fixture_sha256": .string(AgentPackageV1.hash(fixture)), "read_observed": .bool(read),
                "delivered_to_model": .bool(read), "fixture_unchanged": .bool(unchanged)]),
            "raw_model_content": .string(raw), "report_schema_valid": .bool(schemaValid), "host_reproduction_verdict": .string("pending_shared_host_grader"),
            "mock_requests": .integer(observed.bodies.count), "termination_reason": .string(outcome.terminationReason.rawValue),
            "events_sha256": .string(AgentPackageV1.hash(eventBytes))])
        for (name, bytes) in ["observation.json": report.bytes, "first_request.json": try observed.bodies.first.unwrap(), "events.json": eventBytes,
                              "raw_model_content.json": Data(raw.utf8), "host_evidence.json": report["host_evidence"].bytes] {
            try AgentRSIPrivateFiles.writeImmutable(bytes, to: directory.appendingPathComponent(name))
        }
        return report
    }
    private static func permittedOutput(_ directory: URL) -> Bool {
        var ancestor = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/", (try? FileManager.default.attributesOfItem(atPath: ancestor.path)) == nil else { return false }
            ancestor.deleteLastPathComponent()
        }
        let path = ancestor.resolvingSymlinksInPath().path
        return path == "/private/tmp" || path == "/tmp" || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/")
    }
}

private extension Optional where Wrapped == Data {
    func unwrap() throws -> Data { guard let self else { throw AgentRSIError.missingEvidence }; return self }
}
