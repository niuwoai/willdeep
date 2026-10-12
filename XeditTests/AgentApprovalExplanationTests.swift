//
//  AgentApprovalExplanationTests.swift
//  WillDeepTests
//
//  Regression coverage for the lightweight model route used by approval cards.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentApprovalExplanationTests {
    @Test("Approval explanations always use Flash")
    func codingPlanRouteUsesKnownModelNames() {
        let models = AgentApprovalExplanationRouting.someIMModels()

        #expect(models == [SomeIMManagedModel.autoFlash])
        #expect(models.allSatisfy { !$0.contains("/flow") })
        #expect(models.allSatisfy {
            SomeIMManagedModel.allowlist.contains($0) || $0 == SomeIMManagedModel.autoFlash
        })
    }

    @Test("Accounts without Coding Plan use auto flash directly")
    func nonPlanRouteUsesAutoFlashOnly() {
        #expect(
            AgentApprovalExplanationRouting.someIMModels()
                == [SomeIMManagedModel.autoFlash]
        )
    }

    @Test("Approval explanation surfaces the provider's response message")
    @MainActor
    func providerFailureKeepsActionableMessage() {
        let error = AgentClientError.serverStatus(
            AgentProviderHTTPError(
                statusCode: 400,
                method: "POST",
                url: "https://some.im/v1/chat/completions",
                providerID: AgentProviderPreset.someIMID,
                model: SomeIMManagedModel.autoFlash,
                requestSummary: "test",
                requestBody: "{}",
                responseBody: #"{"error":"model not configured"}"#
            )
        )

        let message = AppState.friendlyMessage(for: error)
        #expect(message.contains("HTTP 400"))
        #expect(message.contains("model not configured"))
    }

    private static func commandCall(_ command: String) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: "call-1",
            toolName: "run_command",
            arguments: ["command": .string(command), "_sandbox": .string("escalated")],
            risk: .write,
            status: .pendingApproval
        )
    }

    @Test("Explanation payload carries the whole long command, not the 80-char card summary")
    @MainActor
    func payloadKeepsFullLongCommand() {
        let tail = "echo | timeout 10 openssl s_client -servername share.example.net -connect share.example.net:443"
        let command = "ssh -o BatchMode=yes root@host.example.net '"
            + String(repeating: "journalctl -u svc --since -24h --no-pager | grep -i error | tail -n 5; ", count: 12)
            + tail + "'"
        let payload = AgentApprovalExplanationPrompt.userPayload(for: Self.commandCall(command))

        #expect(payload.contains(tail))
        #expect(!payload.contains(AgentApprovalExplanationPrompt.truncationMarkerPrefix))
        #expect(!payload.contains("_sandbox"))
        #expect(!payload.contains("自动安全检查"))
    }

    @Test("Oversized values are cut by the host with an explicit marker")
    @MainActor
    func oversizedValueIsMarked() {
        let limit = AgentApprovalExplanationPrompt.argumentValueCharacterLimit
        let command = String(repeating: "a", count: limit + 500)
        let payload = AgentApprovalExplanationPrompt.userPayload(for: Self.commandCall(command))

        #expect(payload.contains(AgentApprovalExplanationPrompt.truncationMarkerPrefix))
        #expect(payload.contains("500"))
    }

    @Test("Credentials are redacted before the command reaches the explanation model")
    @MainActor
    func payloadRedactsCredentials() {
        let payload = AgentApprovalExplanationPrompt.userPayload(
            for: Self.commandCall("curl -H 'Authorization: Bearer sk-live-SECRETVALUE123456' https://api.example.com")
        )
        #expect(!payload.contains("SECRETVALUE123456"))
    }

    @Test("An unreachable judge is stated as the reason, not blamed on the command")
    @MainActor
    func payloadStatesJudgeMiss() {
        let payload = AgentApprovalExplanationPrompt.userPayload(
            for: Self.commandCall("ls"), judgeMiss: .unreachable
        )
        #expect(payload.contains("自动安全检查"))
        #expect(payload.contains("没有连上"))
    }
}

@Suite
struct AgentSafetyJudgeRetryTests {
    @Test("Only gateway/server hiccups and fast network errors are retried", arguments: [
        ("http 502", 1.0, true),
        ("http 503", 1.0, true),
        ("http 429", 1.0, true),
        ("network error", 1.0, true),
        ("network error", 35.0, false),
        ("http 502", 20.0, false),
        ("http 400", 1.0, false),
        ("http 401", 1.0, false),
        ("no verdict", 1.0, false),
        ("no judge configured", 0.0, false),
    ])
    func retryPolicy(reason: String, duration: Double, expected: Bool) {
        #expect(AgentSafetyJudgeRetry.shouldRetry(reason: reason, attemptDuration: duration) == expected)
    }

    @Test("Miss ledger expires, clears, and stays bounded")
    func missLedger() {
        var ledger = AgentSafetyJudgeMissLedger()
        let now = Date()
        ledger.record(.unreachable, toolName: "run_command", command: "ls", now: now)
        #expect(ledger.miss(toolName: "run_command", command: "ls", now: now) == .unreachable)
        #expect(ledger.miss(toolName: "run_command", command: "ls -la", now: now) == nil)
        #expect(ledger.miss(toolName: "run_command", command: "ls",
            now: now.addingTimeInterval(AgentSafetyJudgeMissLedger.ttl + 1)) == nil)
        ledger.clear(toolName: "run_command", command: "ls")
        #expect(ledger.miss(toolName: "run_command", command: "ls", now: now) == nil)

        for index in 0...(AgentSafetyJudgeMissLedger.capacity + 5) {
            ledger.record(.unconfigured, toolName: "run_command", command: "cmd \(index)",
                now: now.addingTimeInterval(TimeInterval(index)))
        }
        #expect(ledger.miss(toolName: "run_command", command: "cmd 0",
            now: now.addingTimeInterval(100)) == nil)
        #expect(ledger.miss(toolName: "run_command",
            command: "cmd \(AgentSafetyJudgeMissLedger.capacity + 5)",
            now: now.addingTimeInterval(100)) == .unconfigured)
    }
}
