import Foundation
import Testing
@testable import WillDeep

/// Cross-language decoder contract against willdeep-rs Runtime protocol v1.
///
/// The fixture is produced by the Rust crate `willdeep-runtime-protocol` and
/// copied verbatim into this repo. Its job is to fail here the moment the Rust
/// side changes a public field — before a running daemon does it at the user's
/// expense. Nothing in this suite touches the network or a live Runtime; this
/// is step zero of rs `docs/CLI_TUI_RUNTIME_ROADMAP.md` §1.0.
@Suite
nonisolated struct WillDeepRuntimeProtocolTests {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/willdeep-runtime-public-api-v1.json")

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    private static func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError(description: "fixture root is not an object")
        }
        return root
    }

    /// Re-encodes one fixture entry and runs it through the real decoder. Going
    /// back through `JSONSerialization` keeps each case honest about decoding
    /// the fixture's own bytes rather than a hand-written literal.
    private static func decode<Payload: Decodable>(
        _ group: String,
        _ key: String,
        as: Payload.Type
    ) throws -> WillDeepRuntimeEnvelope<Payload> {
        let root = try fixture()
        guard let bucket = root[group] as? [String: Any],
              let entry = bucket[key] else {
            throw FixtureError(description: "missing \(group).\(key)")
        }
        let data = try JSONSerialization.data(withJSONObject: entry)
        return try JSONDecoder().decode(WillDeepRuntimeEnvelope<Payload>.self, from: data)
    }

    @Test("the protocol fixture is v1 and still carries every object class")
    func fixtureIsProtocolV1() throws {
        let root = try Self.fixture()
        // Both version fields are strings on the wire, including this one.
        #expect(root["fixture_version"] as? String == "1")
        #expect(root["protocol_version"] as? String == "1.0")

        // Losing an object class silently would be a protocol break that
        // per-object tests below cannot see — each only proves its own case.
        let responses = root["responses"] as? [String: Any] ?? [:]
        #expect(Set(responses.keys) == [
            "runtime", "workspace", "session", "agent", "turn", "tool",
            "task", "approval", "question", "artifact", "event", "kernel_event",
        ])
    }

    @Test("every public object class decodes from the shared fixture")
    func everyObjectClassDecodes() throws {
        let runtime = try Self.decode("responses", "runtime", as: WillDeepRuntimeCapabilities.self)
        #expect(runtime.isOK)
        #expect(runtime.data?.protocolVersion == "1.0")
        #expect(runtime.data?.objects.count == 11)
        #expect(runtime.data?.operations.contains("agent.spawn") == true)
        #expect(runtime.meta?.protocolVersion == "1.0")

        let workspace = try Self.decode("responses", "workspace", as: WillDeepRuntimeWorkspace.self)
        #expect(workspace.data?.access.isEmpty == false)
        // `root` is null in the fixture on purpose: the public object never
        // hands a client a filesystem path.
        #expect(workspace.data?.root == nil)

        let session = try Self.decode("responses", "session", as: WillDeepRuntimeSession.self)
        #expect(session.data?.status == "running")
        #expect(session.data?.rootAgentID.isEmpty == false)
        #expect(session.data?.approvalMode == "full_access")
        #expect(
            WillDeepRuntimeApprovalMode.agentApprovalMode(from: session.data?.approvalMode)
                == .fullAccess
        )

        let agent = try Self.decode("responses", "agent", as: WillDeepRuntimeAgent.self)
        #expect(agent.data?.profile == "default")
        #expect(agent.data?.parentID == nil)
        #expect(agent.data?.totalTokens == 1200)
        #expect(agent.data?.currentTool == "read_file")

        let turn = try Self.decode("responses", "turn", as: WillDeepRuntimeTurn.self)
        #expect(turn.data?.attempts != nil)
        #expect(turn.data?.completedAt == nil)

        let tool = try Self.decode("responses", "tool", as: WillDeepRuntimeTool.self)
        #expect(tool.data?.name == "read_file")

        let task = try Self.decode("responses", "task", as: WillDeepRuntimeTask.self)
        #expect(task.data?.exitCode == nil)

        let approval = try Self.decode("responses", "approval", as: WillDeepRuntimeApproval.self)
        #expect(approval.data?.alwaysAllowAvailable != nil)

        let question = try Self.decode("responses", "question", as: WillDeepRuntimeQuestion.self)
        #expect(question.data?.multiSelect != nil)

        let artifact = try Self.decode("responses", "artifact", as: WillDeepRuntimeArtifact.self)
        #expect(artifact.data?.itemCount != nil)

        let event = try Self.decode("responses", "event", as: WillDeepRuntimeEvent.self)
        #expect(event.data?.sequence != nil)
        #expect(event.data?.kind.isEmpty == false)
    }

    @Test("control results decode from the shared fixture")
    func controlResultsDecode() throws {
        let command = try Self.decode(
            "control_results", "agent_command", as: WillDeepRuntimeAgentCommand.self
        )
        #expect(command.data?.kind.isEmpty == false)

        let interaction = try Self.decode(
            "control_results", "interaction", as: WillDeepRuntimeInteraction.self
        )
        #expect(interaction.data?.status.isEmpty == false)

        let status = try Self.decode(
            "control_results", "runtime_status", as: WillDeepRuntimeStatus.self
        )
        #expect(status.data?.pid != nil)
        #expect(status.data?.eventSequence != nil)

        let mutation = try Self.decode(
            "control_results", "object_mutation", as: WillDeepRuntimeObjectMutation.self
        )
        #expect(mutation.data?.status.isEmpty == false)
    }

    @Test("rs approval modes map one-to-one onto AgentApprovalMode")
    func approvalModesRoundTrip() {
        for mode in AgentApprovalMode.allCases {
            let raw = WillDeepRuntimeApprovalMode.runtimeValue(for: mode)
            #expect(WillDeepRuntimeApprovalMode.agentApprovalMode(from: raw) == mode)
        }
        // rs 的只读工作区策略在本端没有对应档位，也不能被悄悄当成 smart。
        #expect(WillDeepRuntimeApprovalMode.agentApprovalMode(from: "read_only") == nil)
        #expect(WillDeepRuntimeApprovalMode.agentApprovalMode(from: nil) == nil)
    }

    /// The copy in this repo is the thing under test, but a copy that has
    /// quietly diverged from its source tests nothing. When the sibling Rust
    /// checkout is present, compare bytes; when it is not (CI, a fresh clone),
    /// skip rather than fail — a missing sibling is not a protocol defect.
    @Test("the local fixture copy still matches the Rust source when both are present")
    func fixtureCopyMatchesRustSource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rustFixture = repositoryRoot
            .deletingLastPathComponent()
            .appendingPathComponent(
                "willdeep-rs/crates/willdeep-runtime-protocol/fixtures/public-api-v1.json"
            )
        guard FileManager.default.fileExists(atPath: rustFixture.path) else { return }

        let mine = try Data(contentsOf: Self.fixtureURL)
        let theirs = try Data(contentsOf: rustFixture)
        #expect(
            mine == theirs,
            """
            XeditTests/Fixtures/willdeep-runtime-public-api-v1.json has drifted from \
            willdeep-rs. Refresh the copy from the Rust repo and fix whatever \
            decoding breaks — do not edit the copy to make this pass.
            """
        )
    }
}
