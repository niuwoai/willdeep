//
//  AgentApprovalExplanationTests.swift
//  WillDeepTests
//
//  Regression coverage for the lightweight model route used by approval cards.
//

import Testing
@testable import WillDeep

@Suite
struct AgentApprovalExplanationTests {
    @Test("Coding Plan explanation uses the configured model and falls back to auto flash")
    func codingPlanRouteUsesKnownModelNames() {
        let models = AgentApprovalExplanationRouting.someIMModels(hasCodingPlan: true)

        #expect(models == [SomeIMManagedModel.codingPlanLow, SomeIMManagedModel.autoFlash])
        #expect(models.allSatisfy { !$0.contains("/flow") })
        #expect(models.allSatisfy {
            SomeIMManagedModel.allowlist.contains($0) || $0 == SomeIMManagedModel.autoFlash
        })
    }

    @Test("Accounts without Coding Plan use auto flash directly")
    func nonPlanRouteUsesAutoFlashOnly() {
        #expect(
            AgentApprovalExplanationRouting.someIMModels(hasCodingPlan: false)
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
                model: SomeIMManagedModel.codingPlanLow,
                requestSummary: "test",
                requestBody: "{}",
                responseBody: #"{"error":"model not configured"}"#
            )
        )

        let message = AppState.friendlyMessage(for: error)
        #expect(message.contains("HTTP 400"))
        #expect(message.contains("model not configured"))
    }
}
