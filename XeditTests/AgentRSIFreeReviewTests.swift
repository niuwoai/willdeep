import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentRSIFreeReviewTests {
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    @Test func resourcesAndStrictGoldenAreSharedByteForByte() throws {
        let base = repository.appendingPathComponent("docs/examples/review-output-v2")
        for (name, file) in [("AgentRSIFreeReviewContract", "contract.json"), ("AgentRSIFreeReviewGolden", "golden.json")] {
            #expect(try AgentRSIContract.resource(name) == Data(contentsOf: base.appendingPathComponent(file)))
        }
        let golden = try AgentRSIContract.raw(AgentRSIContract.resource("AgentRSIFreeReviewGolden"))
        for value in golden["valid"].elements { #expect(try AgentRSIFreeReviewContract.validate(value.bytes) == value) }
        for value in golden["invalid"].elements { #expect(throws: (any Error).self) { try AgentRSIFreeReviewContract.validate(value.bytes) } }
        for item in golden["raw_cases"].elements {
            let raw = Data(item["raw"].text!.utf8)
            #expect(((try? AgentRSIFreeReviewContract.validate(raw)) != nil) == (item["valid"] == .bool(true)), "Shared raw case: \(item["id"].text ?? "")")
        }
        #expect(try AgentRSIFreeReview.contract()["maximum_string_utf8_bytes"].integer == AgentRSIFreeReviewContract.maximumStringBytes)
    }
    @Test func exactJSONRejectsAmbiguityLexicalNumbersAndResourceAbuse() throws {
        let clean = "{\"has_defect\":false,\"line\":null,\"reason\":\"Clean.\",\"reproduction\":null}"
        let bug = "{\"has_defect\":true,\"line\":3,\"reason\":\"Boundary.\",\"reproduction\":{\"input\":{},\"expected\":0,\"actual\":7}}"
        let invalid = ["```json\n" + clean + "\n```", "prefix " + clean, clean + clean,
            clean.replacingOccurrences(of: "\"has_defect\":false", with: "\"has_defect\":false,\"has_defect\":true"),
            clean.replacingOccurrences(of: "\"reason\":\"Clean.\"", with: "\"reason\":\" \""),
            clean.replacingOccurrences(of: "\"line\":null", with: "\"schema\":\"extra\",\"line\":null"),
            bug.replacingOccurrences(of: "\"line\":3", with: "\"line\":true"),
            bug.replacingOccurrences(of: "\"line\":3", with: "\"line\":0"),
            bug.replacingOccurrences(of: "\"expected\":0", with: "\"expected\":-0"),
            bug.replacingOccurrences(of: "\"expected\":0", with: "\"expected\":0.0"),
            bug.replacingOccurrences(of: "\"expected\":0", with: "\"expected\":0e0"),
            bug.replacingOccurrences(of: "\"expected\":0", with: "\"expected\":9007199254740992"),
            bug.replacingOccurrences(of: "\"input\":{}", with: "\"input\":" + String(repeating: "[", count: 10) + "0" + String(repeating: "]", count: 10)),
            bug.replacingOccurrences(of: "\"input\":{}", with: "\"input\":[" + Array(repeating: "0", count: 129).joined(separator: ",") + "]"),
            bug.replacingOccurrences(of: "\"input\":{}", with: "\"input\":{\"__proto__\":0}"),
            bug.replacingOccurrences(of: "\"input\":{}", with: "\"input\":{\"prototype\":0}"),
            bug.replacingOccurrences(of: "\"input\":{}", with: "\"input\":{\"constructor\":0}"),
            clean.replacingOccurrences(of: "Clean.", with: String(repeating: "中", count: 1366)),
            clean.replacingOccurrences(of: "Clean.", with: String(repeating: "x", count: 16_384))]
        for raw in invalid { #expect(throws: (any Error).self) { try AgentRSIFreeReviewContract.validate(Data(raw.utf8)) } }
        #expect(throws: (any Error).self) { try AgentRSIFreeReviewContract.validate(Data([0xff])) }
    }
    @Test func publicFixturesExecuteNormalWorkerAndKeepFrozenDefinitionAndInstructions() async throws {
        let root = repository.appendingPathComponent("build/rsi-free-review-v2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try AgentRSIFreeReview.manifest(), contract = try AgentRSIFreeReview.contract()
        let golden = try AgentRSIOfflineRunner.golden()["candidate"]["baseline_package"]
        var observations: [AgentCanonicalJSON] = []
        for task in manifest["tasks"].elements {
            let name = try #require(task["case_id"].text), directory = root.appendingPathComponent(name)
            let result = try await AgentRSIFreeReview.run(caseID: name, directory: directory)
            #expect(result["status"].text == "unverified" && result["host_reproduction_verdict"].text == "pending_shared_host_grader")
            #expect(result["definition_revision"] == golden["sha256"] && result["loaded_revision"] == golden["sha256"])
            #expect(result["instructions_observed"] == .bool(true) && result["definition_instructions_observed"] == .bool(true))
            #expect(result["instructions_sha256"].text == AgentPackageV1.hash(Data(contract["instructions"].text!.utf8)))
            #expect(result["report_schema_valid"] == .bool(true) && result["mock_requests"].integer == 2)
            #expect(result["host_evidence"]["read_observed"] == .bool(true) && result["host_evidence"]["delivered_to_model"] == .bool(true))
            #expect(result["host_evidence"]["fixture_unchanged"] == .bool(true) && result["host_evidence"]["fixture_sha256"] == task["fixture_sha256"])
            var parser = AgentCanonicalJSON.Parser(data: try Data(contentsOf: directory.appendingPathComponent("first_request.json")), allowNumbers: true)
            let first = try parser.parse()
            #expect(first["messages"].elements.contains { $0["content"].text?.contains(contract["instructions"].text!) == true })
            #expect(!first.canonical.contains(name) && !first.canonical.contains("public_witness") && !first.canonical.contains("reference_sha256"))
            let events = try AgentRSIContract.raw(Data(contentsOf: directory.appendingPathComponent("events.json"))).elements
            #expect(events.filter { $0["kind"].text == "request_started" }.allSatisfy { $0["provider"].text == "mock" })
            #expect(events.first { $0["kind"].text == "started" && $0["mode"].text == "free_review_v2_worker" }?["effectiveTools"].elements.allSatisfy { !["edit_file", "run_command"].contains($0.text ?? "") } == true)
            observations.append(result)
        }
        try AgentCanonicalJSON.object(["scope": .string("offline_mock_contract_only"), "real_provider_requests": .integer(0), "observations": .array(observations)]).bytes
            .write(to: root.appendingPathComponent("report.json"), options: .atomic)
        try Data("# Mac v2 免费原生验证\n\n6 个公共 fixture 均由真实 Worker 读取并经 mock 传输输出；不代表模型质量或独立复现通过。客观语义结果由共享宿主评分器另存。\n".utf8)
            .write(to: root.appendingPathComponent("report.md"), options: .atomic)
    }
    @Test func modePermissionsAndEscapingOutputAreRejectedBeforeExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("trial")
        for mode in ["paid", "direct", "native-trial-control.v1"] {
            await #expect(throws: AgentRSIError.paidNotApproved) { try await AgentRSIFreeReview.run(caseID: "count-zero-bug", directory: output, executionMode: mode) }
        }
        var definition = try AgentPackageV1.decode(AgentRSIOfflineRunner.golden()["candidate"]["baseline_package"].bytes).definition
        definition.tools.append("workspace.edit")
        let writable = try AgentPackageV1.unsigned(definition)
        await #expect(throws: AgentRSIError.paidNotApproved) { try await AgentRSIFreeReview.run(caseID: "count-zero-bug", directory: output, package: writable) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/")
        await #expect(throws: AgentRSIError.paidNotApproved) { try await AgentRSIFreeReview.run(caseID: "count-zero-bug", directory: root.appendingPathComponent("escape/new-output")) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
