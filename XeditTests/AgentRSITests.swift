import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentRSITests {
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture(_ name: String) throws -> AgentCanonicalJSON {
        try AgentRSIContract.raw(Data(contentsOf: repository.appendingPathComponent("docs/examples/agent-rsi-" + name + ".json")))
    }
    @Test func sharedGoldenCanonicalHashesAndExactResourceCopies() throws {
        let golden = try fixture("golden")
        for (name, value) in golden["values"].fields {
            #expect(value.canonical == golden["canonical"][name].text)
            #expect(AgentPackageV1.hash(value.bytes) == golden["sha256"][name].text)
            if name != "canonical_edge" { _ = try AgentRSIContract.parse(value.bytes, entity: name) }
        }
        #expect(try AgentRSIContract.resource("AgentRSIGolden") == Data(contentsOf: repository.appendingPathComponent("docs/examples/agent-rsi-golden.json")))
        #expect(try AgentRSIContract.resource("AgentRSISchema") == Data(contentsOf: repository.appendingPathComponent("docs/examples/agent-rsi-schema.json")))
    }
    @Test func opaqueIdentifiersRemainOneEncodedPathSegment() throws {
        let opaque = "user/experiment:review-1"
        #expect(try AgentRSIService.pathSegment(opaque) == "user%2Fexperiment%3Areview-1")
        var components = URLComponents(string: "http://127.0.0.1:1")!
        components.percentEncodedPath = "/api/v1/customer/agent-rsi/experiments/" + (try AgentRSIService.pathSegment(opaque)) + "/evidence"
        #expect(components.url!.absoluteString.contains("user%2Fexperiment%3Areview-1"))
        #expect(!components.url!.absoluteString.contains("%252F"))
        #expect(throws: (any Error).self) { try AgentRSIService.pathSegment("bad?query") }
    }
    @Test func partiallyUnknownUsageIsNeverReplacedWithZero() {
        let run = UUID(), a = UUID(), b = UUID()
        var start = AgentExecutionEvidenceEvent(runID: run, rootRunID: run, mode: "direct_experiment_worker", kind: "request_started")
        start.requestID = a
        var second = start; second.requestID = b
        var usage = start; usage.kind = "request_usage"; usage.inputTokens = 10; usage.outputTokens = 1
        var partial = second; partial.kind = "request_usage"; partial.outputTokens = 2
        #expect(AgentRSIUsage.sum([start, second, usage], keyPath: \.inputTokens) == .null)
        #expect(AgentRSIUsage.sum([start, second, usage, partial], keyPath: \.inputTokens) == .null)
        #expect(AgentRSIUsage.sum([start, second, usage, partial], keyPath: \.outputTokens) == .integer(3))
    }
    @Test func matchingHostWithoutInjectedMockSessionRetainsRealProviderIdentity() async throws {
        let id = UUID(), host = "same-host.agent-rsi.invalid"
        let trace = AgentExecutionTrace(store: .init(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            seed: .init(runID: id, rootRunID: id, mode: "root", kind: "started"))
        AgentRSIOfflineProvider.register(host: host, trace: trace)
        defer { AgentRSIOfflineProvider.unregister(host: host) }
        let config = AgentConfiguration(providerID: "custom", baseURL: "https://" + host + "/v1", model: "fixture", apiKey: "offline-placeholder")
        #expect(AgentRSIOfflineProvider.transportProvider(configuration: config) == "custom")
        let ordinary = URLSession(configuration: .ephemeral); defer { ordinary.invalidateAndCancel() }
        await #expect(throws: AgentRSIError.paidNotApproved) {
            try await AgentRSIOfflineProvider.withTransport(session: ordinary, host: host) { () }
        }
    }
    @Test func actualRoutedModelReceiptIsJoinedToThePhysicalRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), request = UUID(), store = AgentExecutionEvidenceStore(root: directory)
        let trace = AgentExecutionTrace(store: store, seed: .init(runID: id, rootRunID: id, mode: "root", kind: "started"))
        let response = HTTPURLResponse(url: URL(string: "https://some.im/fixture")!, statusCode: 200,
            httpVersion: nil, headerFields: ["X-Routed-Model": "fixture-physical-model"])!
        AgentExecutionTrace.$current.withValue(trace) {
            AgentExecutionTrace.$physicalRequestID.withValue(request) {
                AgentRoutedModelResponseObserver.capture(response, providerID: AgentProviderPreset.someIMID)
            }
        }
        let receipt = try #require(store.events().first)
        #expect(receipt.kind == "model_routed" && receipt.model == "fixture-physical-model" && receipt.requestID == request)
    }
    @Test func sharedNegativeCorpusIsRejectedAtItsDeclaredBoundary() throws {
        let golden = try fixture("golden")["values"], negative = try fixture("negative")
        #expect(negative["cases"].elements.count == 33)
        for item in negative["cases"].elements {
            var rejected = false
            do {
                let value = try AgentRSIContract.parse(Data(item["raw"].text!.utf8), entity: item["entity"].text!)
                if item["kind"].text == "binding" { try AgentRSIContract.bind(candidate: golden["candidate"], experiment: golden["experiment"], evidence: value) }
            } catch { rejected = true }
            #expect(rejected, "Rejected case: \(item["id"].text ?? "")")
        }
    }
    @Test func nonemptyLockedSkillsMatchSharedCanonicalFingerprint() throws {
        let fixture = try fixture("skills-golden")
        let skills = try JSONDecoder().decode([AgentDefinitionV1.Skill].self, from: fixture["skills"].bytes)
        let loaded = try AgentRSIContract.raw(JSONEncoder().encode(skills))
        #expect(loaded.canonical == fixture["canonical"].text)
        #expect(AgentPackageV1.hash(loaded.bytes) == fixture["sha256"].text)
        #expect(skills.count == 2 && skills.first?.required == true && skills.last?.content == "")
    }
    @Test func admissionsKeepResumeLineageConcurrencyAndHoldoutMonotonic() throws {
        let values = try fixture("golden")["values"]
        var ledger = AgentRSIAdmissionLedger(experiment: values["experiment"])
        let first = values["admission"]
        #expect(throws: AgentRSIError.missingEvidence) { try ledger.admit(first.replacing("task_id", .string("holdout-1"))) }
        try ledger.admit(first); try ledger.admit(first)
        #expect(ledger.admissions.count == 1)
        let concurrent = first.replacing("trial_id", .string("concurrent")).replacing("arm", .string("candidate"))
        #expect(throws: (any Error).self) { try ledger.admit(concurrent) }
        let terminal = values["evidence"].replacing("status", .string("infra_error"))
        try ledger.finish(terminal)
        let resumed = first.replacing("trial_id", .string("resumed")).replacing("attempt", .integer(2)).replacing("resume_of", first["trial_id"])
        try ledger.admit(resumed)
        #expect(ledger.admissions.count == 2)
        #expect(throws: (any Error).self) { try ledger.admit(resumed.replacing("trial_id", .string("third")).replacing("attempt", .integer(3))) }
        var passed = AgentRSIAdmissionLedger(experiment: values["experiment"])
        try passed.admit(first); try passed.finish(values["evidence"])
        try passed.finish(values["evidence"])
        #expect(throws: (any Error).self) { try passed.finish(values["evidence"].replacing("status", .string("failed"))) }
        #expect(throws: (any Error).self) { try passed.admit(resumed) }
    }
    @Test func orphanStartsStayInterruptedAndPreserveRootAcrossRestores() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentExecutionEvidenceStore(root: directory), session = UUID(), root = UUID(), run = UUID()
        var event = AgentExecutionEvidenceEvent(runID: run, rootRunID: root, sessionID: session, mode: "background_worker", kind: "started")
        event.processID = UUID(); try store.append(event)
        let previous = try store.recoverInterrupted(sessionID: session)
        #expect(previous?.runID == run && previous?.rootRunID == root)
        #expect(try store.events().contains { $0.runID == run && $0.kind == "interrupted" && $0.status == "interrupted" })
        #expect(try store.recoverInterrupted(sessionID: session) == nil)
        #expect(try !store.events().contains { $0.status == "passed" })
        // Once recovered, subsequent turns do not read old event files at all.
        try Data("invalid old event".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
        #expect(try store.recoverInterrupted(sessionID: session) == nil)
        let a = AgentExecutionTrace.root(sessionID: UUID(), turnID: UUID(), configuration: .default)
        let b = AgentExecutionTrace.root(sessionID: UUID(), turnID: UUID(), configuration: .default)
        #expect(a.store.root != b.store.root)
    }
    @Test func interruptedUnexecutedTrialMayHaveNoRouteButExecutedTrialCannot() throws {
        let sample = try fixture("golden")["values"]["evidence"]
        let orphan = sample.replacing("status", .string("interrupted")).replacing("target_executed", .bool(false))
            .replacing("model_route", .array([])).replacing("worker_run_id", .null).replacing("finished_at", .null)
            .replacing("events_sha256", .null).replacing("verifier", sample["verifier"].replacing("result", .string("unverified")).replacing("exit_code", .null))
        _ = try AgentRSIContract.parse(orphan.bytes, entity: "evidence")
        #expect(throws: (any Error).self) { try AgentRSIContract.parse(orphan.replacing("target_executed", .bool(true)).bytes, entity: "evidence") }
    }
    @Test func candidateSavingDoesNotActivateOrUnpinAndAccountsStaySeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "rsi-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let goldenCandidate = try fixture("golden")["values"]["candidate"]
        let candidate = try AgentRSIOfflineRunner.candidate(baseline: AgentPackageV1.decode(goldenCandidate["baseline_package"].bytes),
            instructions: goldenCandidate["candidate_package"]["definition"]["instructions"].text!, version: "1.0.0-rc2")
        let baseline = try AgentPackageV1.decode(candidate["baseline_package"].bytes)
        let library = AgentDefinitionLibrary(root: directory.appendingPathComponent("registry"), defaults: defaults)
        let installed = try library.install(baseline, source: .local)
        let before = try library.state()
        let a = AgentRSIStore(root: directory.appendingPathComponent("rsi"), owner: "account-a")
        try a.save(candidate, entity: "candidate")
        #expect(try library.state().installations == before.installations)
        #expect(try library.state().installations.first?.selected == installed.selected)
        #expect(try AgentRSIStore(root: a.root, owner: "account-b").values(entity: "candidate").isEmpty)
        #expect(try a.values(entity: "candidate").count == 1)
    }
    @Test func changingExperimentIDDoesNotResetHoldoutAccess() throws {
        let values = try fixture("golden")["values"], root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let quota = AgentRSIHoldoutQuota(directory: root)
        let experiment = values["experiment"].replacing("budget", values["experiment"]["budget"].replacing("max_holdout_accesses", .integer(1)))
        let admission = values["admission"].replacing("task_id", .string("holdout-1"))
        try quota.reserve(experiment: experiment, admission: admission)
        try quota.reserve(experiment: experiment, admission: admission)
        #expect(throws: AgentRSIError.quota) {
            try quota.reserve(experiment: experiment.replacing("experiment_id", .string("another-experiment")),
                              admission: admission.replacing("trial_id", .string("another-trial")))
        }
    }
    @Test func repeatedSamplesHaveIndependentAdmissionsWithoutRaisingHoldoutLimit() throws {
        let values = try fixture("golden")["values"]
        let experiment = values["experiment"].replacing("repetitions", .integer(2))
        var ledger = AgentRSIAdmissionLedger(experiment: experiment)
        for repetition in 1...2 {
            let admission = values["admission"].replacing("trial_id", .string("repeat-\(repetition)"))
                .replacing("repetition", .integer(repetition))
            try ledger.admit(admission)
            let evidence = values["evidence"].replacing("trial_id", admission["trial_id"]).replacing("repetition", .integer(repetition))
            try ledger.finish(evidence)
        }
        #expect(ledger.admissions.count == 2 && ledger.admissions.allSatisfy { $0["attempt"].integer == 1 })
        #expect(experiment["budget"]["max_holdout_accesses"] == values["experiment"]["budget"]["max_holdout_accesses"])
    }
    @Test func nativePairedRunnerUsesWorkerToolsVerifierAndProducesCompleteReport() async throws {
        let goldenCandidate = try fixture("golden")["values"]["candidate"]
        let candidate = try AgentRSIOfflineRunner.candidate(baseline: AgentPackageV1.decode(goldenCandidate["baseline_package"].bytes),
            instructions: goldenCandidate["candidate_package"]["definition"]["instructions"].text!, version: "1.0.0-rc2")
        let directory = repository.appendingPathComponent("build/rsi-offline-acceptance/" + UUID().uuidString.lowercased())
        let result = try await AgentRSIOfflineRunner.run(candidate: candidate, directory: directory)
        #expect(result.complete)
        #expect(result.evidence.count == 6)
        for item in result.evidence {
            #expect(item["target_executed"] == .bool(true))
            #expect(item["verifier"]["exit_code"].integer == 0)
            #expect(item["worker_run_id"] != .null && item["events_sha256"] != .null)
            #expect(item["usage"]["input_tokens"].integer ?? 0 > 0)
            try AgentRSIContract.bind(candidate: candidate, experiment: result.experiment, evidence: item)
        }
        // Negative gate must run before transport construction, even with a
        // caller-supplied spec and a valid direct revision.
        let paid = result.experiment.replacing("model", result.experiment["model"].replacing("provider", .string("openai")))
        await #expect(throws: AgentRSIError.paidNotApproved) {
            _ = try await AgentRSIOfflineRunner.run(candidate: candidate, experiment: paid, directory: directory.appendingPathComponent("paid-denied"))
        }
        try await optionalServiceRoundTrip(result, directory: directory)
    }
    @Test func quotaRejectionRetainsPartialReportWithoutInventingTheMissingTrial() async throws {
        let sample = try fixture("golden")["values"]["candidate"]
        let candidate = try AgentRSIOfflineRunner.candidate(baseline: AgentPackageV1.decode(sample["baseline_package"].bytes),
            instructions: sample["candidate_package"]["definition"]["instructions"].text!, version: "1.0.0-rc2")
        let spec = try AgentRSIOfflineRunner.spec(candidate: candidate)
        let bounded = spec.replacing("budget", spec["budget"].replacing("max_holdout_accesses", .integer(1)))
        let directory = repository.appendingPathComponent("build/rsi-partial-acceptance/" + UUID().uuidString.lowercased())
        let result = try await AgentRSIOfflineRunner.run(candidate: candidate, experiment: bounded, directory: directory)
        #expect(!result.complete && result.haltReason == "budget_exhausted")
        #expect(result.evidence.count == 5 && result.admissions.count == 5)
        #expect(result.evidence.allSatisfy { $0["status"].text == "passed" })
        let report = try AgentRSIContract.raw(Data(contentsOf: directory.appendingPathComponent("report.json")))
        #expect(report["complete"] == .bool(false) && report["halt_reason"].text == "budget_exhausted")
        #expect(report["evidence"].elements.count == 5)
        #expect(try String(contentsOf: directory.appendingPathComponent("report.md"), encoding: .utf8).contains("budget_exhausted"))
    }
    private func optionalServiceRoundTrip(_ result: AgentRSIOfflineResult, directory: URL) async throws {
        let configuration = repository.appendingPathComponent("build/rsi-service-acceptance.json")
        guard FileManager.default.fileExists(atPath: configuration.path) else { return }
        let config = try AgentRSIContract.raw(Data(contentsOf: configuration))
        guard let receiptPath = config["receipt_path"].text else { throw AgentRSIError.invalidContract }
        let receipt = try AgentRSIContract.raw(Data(contentsOf: URL(fileURLWithPath: receiptPath)))
        guard receipt["mock_only"] == .bool(true), let origin = receipt["origin"].text, let url = URL(string: origin), ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              let token = receipt["tokens"]["a"].text else { throw AgentRSIError.invalidContract }
        let service = AgentRSIService(registry: try AgentRegistryService(baseURL: origin, token: token))
        let values = try fixture("golden")["values"]
        let grant = values["grant"].replacing("grant_id", result.candidate["grant_id"])
        _ = try await service.create(grant, entity: "grant")
        _ = try await service.create(result.candidate, entity: "candidate")
        _ = try await service.create(result.experiment, entity: "experiment")
        for admission in result.admissions {
            let id = result.experiment["experiment_id"].text!
            _ = try await service.create(admission, entity: "admission", experimentID: id)
            for item in result.evidence where item["trial_id"] == admission["trial_id"] {
                let stored = try await service.create(item, entity: "evidence", experimentID: id)
                #expect(stored.document["trust"].text == "client_reported")
                #expect(stored.sha256 != AgentPackageV1.hash(item.bytes))
            }
        }
        #expect(try await service.list("evidence", experimentID: result.experiment["experiment_id"].text).count == 6)
        var peerCount = 0
        if let peer = config["peer_experiment"].text {
            let remote = try await service.list("experiment").first { $0.document["experiment_id"].text == peer }
            let spec = try #require(remote?.document)
            let remoteCandidate = try await service.list("candidate").first { $0.document["candidate_id"] == spec["candidate_id"] }
            let peerCandidate = try #require(remoteCandidate?.document)
            let records = try await service.list("evidence", experimentID: peer)
            #expect(!records.isEmpty)
            for record in records {
                try AgentRSIContract.bind(candidate: peerCandidate, experiment: spec, evidence: record.document)
                #expect(record.document["trust"].text == "client_reported")
            }
            peerCount = records.count
        }
        let safe = AgentCanonicalJSON.object(["scope": .string("isolated_localhost_service"), "evidence_count": .integer(6),
            "peer_evidence_count": .integer(peerCount), "experiment_id": result.experiment["experiment_id"], "client_reported": .bool(true)])
        try safe.bytes.write(to: directory.appendingPathComponent("service-receipt.json"), options: .atomic)
    }
}
