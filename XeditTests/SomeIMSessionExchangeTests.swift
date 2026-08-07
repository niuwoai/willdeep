import Foundation
import Testing
@testable import WillDeep

/// Renewal must fire on an expired session and on nothing else: retrying a
/// network blip through the exchange endpoint turns every transient failure
/// into extra auth traffic, while failing to retry a real expiry leaves the
/// account stuck showing credits with no name or avatar.
@Suite
@MainActor
struct SomeIMSessionExchangeTests {
    @Test("an expired or rejected session is recognized as renewable")
    func authFailuresTriggerRenewal() {
        #expect(SomeIMClient.isAuthenticationFailure(AgentToolError.httpFailed(401, "unauthorized")))
        #expect(SomeIMClient.isAuthenticationFailure(AgentToolError.httpFailed(403, "forbidden")))
        #expect(SomeIMClient.isAuthenticationFailure(URLError(.userAuthenticationRequired)))
    }

    @Test("server faults and network blips do not trigger renewal")
    func nonAuthFailuresDoNotTriggerRenewal() {
        // A 500 means the server is unwell, not that the token died.
        #expect(!SomeIMClient.isAuthenticationFailure(AgentToolError.httpFailed(500, "boom")))
        #expect(!SomeIMClient.isAuthenticationFailure(AgentToolError.httpFailed(429, "slow down")))
        #expect(!SomeIMClient.isAuthenticationFailure(AgentToolError.httpFailed(404, "not found")))
        #expect(!SomeIMClient.isAuthenticationFailure(URLError(.timedOut)))
        #expect(!SomeIMClient.isAuthenticationFailure(URLError(.notConnectedToInternet)))
        #expect(!SomeIMClient.isAuthenticationFailure(AgentClientError.invalidResponse))
    }

    @Test("exchanging without a stored api_key fails instead of calling out")
    func exchangeRequiresAPIKey() async {
        // The api_key is the only credential the exchange can present; with
        // none stored there is nothing to try.
        guard SomeIMIntegrationStore.loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A developer machine may hold a real login; the guard under test
            // only concerns the empty case.
            return
        }
        await #expect(throws: AgentClientError.self) {
            try await SomeIMClient.exchangeSessionToken(
                settings: SomeIMIntegrationSettings(),
                session: .shared
            )
        }
    }
}
