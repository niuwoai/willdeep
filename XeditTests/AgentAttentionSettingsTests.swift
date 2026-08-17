import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentAttentionSettingsTests {
    @Test("notification settings round-trip without overwriting other TOML sections")
    func notificationSettingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-attention-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        version = 1

        [providers.local]
        provider = "openai"
        model = "local-model"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let expected = AgentAttentionPreferences(
            sound: .custom,
            customSoundFile: "WillDeep-Custom-Alert.mp3",
            customSoundDisplayName: "您有一条消息.mp3",
            webhookEnabled: true,
            webhookURL: "http://127.0.0.1:8787/willdeep",
            webhookOnTaskCompleted: true,
            webhookOnAttentionRequired: false
        )
        try AgentAttentionPreferencesStore.save(expected, to: configURL)

        let savedText = try String(contentsOf: configURL, encoding: .utf8)
        #expect(savedText.contains("[providers.local]"))
        #expect(savedText.contains("model = \"local-model\""))
        #expect(savedText.components(separatedBy: "[notifications]").count == 2)
        #expect(AgentAttentionPreferencesStore.load(from: configURL) == expected)
    }

    @Test("webhook accepts local HTTP and HTTPS but rejects non-network URLs")
    func webhookURLValidation() throws {
        #expect(try AgentAttentionWebhookClient.validatedURL("http://127.0.0.1:8787/hook").host == "127.0.0.1")
        #expect(try AgentAttentionWebhookClient.validatedURL("https://example.com/hook").scheme == "https")
        #expect(throws: AgentAttentionWebhookClient.DeliveryError.self) {
            try AgentAttentionWebhookClient.validatedURL("file:///tmp/hook")
        }
    }

    @Test("webhook request is self-identifying and carries hook compatibility aliases")
    func webhookCompatibilityEnvelope() throws {
        let runtimeID = UUID()
        let event = AgentAttentionWebhookClient.makeEvent(
            kind: .taskCompleted,
            runtimeID: runtimeID,
            sessionTitle: "Compatibility test",
            executor: "Codex CLI",
            status: "completed",
            taskID: "job-42",
            attentionKind: nil,
            summary: "job-42 · completed"
        )
        let request = try AgentAttentionWebhookClient.request(
            for: event,
            to: "http://127.0.0.1:8787/hook"
        )

        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("WillDeep-") == true)
        #expect(request.value(forHTTPHeaderField: "X-Agent-Source") == "willdeep")
        #expect(request.value(forHTTPHeaderField: "X-Agent-Executor") == "codex")
        #expect(request.value(forHTTPHeaderField: "X-Webhook-Schema") == "willdeep.webhook.v1")

        let body = try #require(request.httpBody)
        let payloadObject = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(payloadObject as? [String: Any])
        #expect(payload["event"] as? String == "task_completed")
        #expect(payload["type"] as? String == "agent-turn-complete")
        #expect(payload["hook_event_name"] as? String == "Stop")
        #expect(payload["session_id"] as? String == runtimeID.uuidString)
        #expect(payload["thread-id"] as? String == runtimeID.uuidString)

        let approval = AgentAttentionWebhookClient.makeEvent(
            kind: .attentionRequired,
            runtimeID: runtimeID,
            sessionTitle: "Approval test",
            executor: "Codex CLI",
            status: "pendingApproval",
            taskID: "job-43",
            attentionKind: "tool_approval",
            summary: "git status"
        )
        #expect(approval.hookEventName == "PermissionRequest")
        #expect(approval.notificationType == "permission_prompt")

        let question = AgentAttentionWebhookClient.makeEvent(
            kind: .attentionRequired,
            runtimeID: runtimeID,
            sessionTitle: "Question test",
            executor: "Claude Code",
            status: "awaitingUserAnswer",
            taskID: "job-44",
            attentionKind: "ask_user",
            summary: "请选择下一步"
        )
        #expect(question.hookEventName == "Notification")
        #expect(question.notificationType == "elicitation_dialog")
    }

    @Test("webhook detector checks explicit headers, user agent, then distinctive body fields")
    func webhookFormatDetection() throws {
        let willDeep = AgentWebhookFormatDetector.detect(
            headers: [
                "User-Agent": "some.im/WillDeep-1.269.0-rc1 (macOS)",
                "X-Agent-Source": "willdeep",
            ],
            body: Data("{\"schema_version\":\"willdeep.webhook.v1\"}".utf8)
        )
        #expect(willDeep == AgentWebhookFormatDetection(
            source: .willDeep,
            confidence: .high,
            hasConflict: false
        ))

        let codex = AgentWebhookFormatDetector.detect(
            headers: [:],
            body: Data("{\"type\":\"agent-turn-complete\",\"thread-id\":\"thr-1\"}".utf8)
        )
        #expect(codex.source == .codex)
        #expect(codex.confidence == .high)

        let claude = AgentWebhookFormatDetector.detect(
            headers: [:],
            body: Data("{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\"}".utf8)
        )
        #expect(claude.source == .claudeCode)

        let conflict = AgentWebhookFormatDetector.detect(
            headers: ["User-Agent": "claude-code/2.1"],
            body: Data("{\"source\":\"willdeep\",\"event\":\"task_completed\"}".utf8)
        )
        #expect(conflict.source == .claudeCode)
        #expect(conflict.confidence == .medium)
        #expect(conflict.hasConflict)
    }
}
