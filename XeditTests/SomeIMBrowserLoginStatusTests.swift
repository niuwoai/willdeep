//
//  SomeIMBrowserLoginStatusTests.swift
//  WillDeepTests
//
//  Split from AgentToolIntegrationTests.swift to keep files under the
//  repository file-size limit. some.im browser login pairing, credential
//  persistence, coding plan subscription, and relay-region probing.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct SomeIMBrowserLoginStatusTests {
    @Test("connected account portal opens the some.im customer page")
    func testCustomerPortalURL() {
        #expect(SomeIMClient.customerPortalURL.absoluteString == "https://some.im/customer")
    }

    @Test("browser login request always opens some.im control plane")
    func testBrowserLoginRequestUsesSomeIMControlPlane() throws {
        let request = try SomeIMClient.makeBrowserLoginRequest(
            settings: SomeIMIntegrationSettings(baseURL: "https://api.niuwoai.com/v1")
        )
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "some.im")
        #expect(components.path == "/customer/login")
        #expect(query["client_id"] == "willdeep")
        #expect(query["code"] == request.code)
        #expect(query["device_code"] == request.code)
        #expect(query["willdeep_device_code"] == request.code)
        #expect(request.code.range(of: #"^WD-[A-Z2-9]{4}-[A-Z2-9]{4}$"#, options: .regularExpression) != nil)
        #expect(query["pair_token"] == request.pairToken)
        #expect(query["willdeep_pair_token"] == request.pairToken)
        #expect(query["next"]?.contains("pair_token=\(request.pairToken)") == true)
    }

    @Test("browser login status accepts nested camelCase credentials")
    @MainActor
    func testBrowserLoginStatusAcceptsNestedCamelCaseCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "a", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/public/client-login/browser-status")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "state": "connected",
                "credentials": {
                  "apiKey": "sk-test-browser-login",
                  "sessionToken": "session-test-browser-login",
                  "defaultModel": "someim-auto-flash",
                  "customer": {
                    "email": "qa@example.com",
                    "tenantID": "tenant-1",
                    "balanceUSD": "1.25",
                    "creditsPerUSD": "100000"
                  }
                }
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0001",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account?.email == "qa@example.com")
        #expect(SomeIMIntegrationStore.loadAPIKey() == "sk-test-browser-login")
        #expect(SomeIMIntegrationStore.loadSessionToken() == "session-test-browser-login")
    }

    @Test("browser login status accepts completed-style server states")
    @MainActor
    func testBrowserLoginStatusAcceptsCompletedServerState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "e", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"code":0,"data":{"status":"completed","api_key":"sk-test-completed","email":"completed@example.com"}}"#.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0005",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account?.email == "completed@example.com")
        #expect(SomeIMIntegrationStore.loadAPIKey() == "sk-test-completed")
    }

    @Test("browser login status accepts current some.im connected payload")
    @MainActor
    func testBrowserLoginStatusAcceptsCurrentSomeIMConnectedPayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "f", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "status": "connected",
                "api_key": "sk-test-current-payload",
                "token": "session-test-current-payload",
                "default_model": "gpt-5",
                "account": {
                  "email": "current@example.com",
                  "tenant_id": "tenant-current",
                  "credits": "123456",
                  "credits_per_usd": "100000"
                }
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0006",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account?.email == "current@example.com")
        #expect(result.account?.tenantID == "tenant-current")
        #expect(result.account?.credits == "123456")
        #expect(result.account?.defaultModel == "gpt-5")
        #expect(SomeIMIntegrationStore.loadAPIKey() == "sk-test-current-payload")
        #expect(SomeIMIntegrationStore.loadSessionToken() == "session-test-current-payload")
    }

    @Test("account refresh hydrates nickname and avatar from current some.im profile")
    @MainActor
    func testAccountRefreshHydratesCurrentSomeIMProfile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        SomeIMIntegrationStore._setTestSharedAPIKeyWithoutNotification("sk-test-profile")
        #expect(SomeIMIntegrationStore.saveSessionToken("session-test-profile"))
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch request.url?.path {
            case "/v1/account/balance":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-profile")
                let body = #"{"tenant_id":"tenant-profile","currency":"USD","balance":"41.8","balance_updated_at_unix_micros":"123"}"#.data(using: .utf8)!
                return (response, body)
            case "/api/v1/customer/me":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-test-profile")
                let body = """
                {
                  "code": 0,
                  "data": {
                    "tenant": {"id": "tenant-profile"},
                    "user": {
                      "email": "profile@example.com",
                      "nickname": "hey",
                      "avatar_url": "https://img.niuwoai.com/avatar.png"
                    }
                  }
                }
                """.data(using: .utf8)!
                return (response, body)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let account = try await SomeIMClient.fetchAccountBalance(
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            apiKey: "sk-test-profile",
            session: session
        )

        #expect(account.email == "profile@example.com")
        #expect(account.nickname == "hey")
        #expect(account.avatarURL == "https://img.niuwoai.com/avatar.png")
        #expect(account.profileUpdatedAt != nil)
    }

    @Test("browser login status accepts flat credentials without nested account")
    @MainActor
    func testBrowserLoginStatusAcceptsFlatCredentialsWithoutNestedAccount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "d", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
            #expect(query["code"] == "WD-TEST-0004")
            #expect(query["device_code"] == "WD-TEST-0004")
            #expect(query["willdeep_device_code"] == "WD-TEST-0004")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "status": "connected",
                "api_token": "sk-test-browser-flat",
                "customer_session_token": "session-test-browser-flat",
                "email": "flat@example.com",
                "credits": "9900000",
                "default_model": "someim-auto-flash"
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0004",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account?.email == "flat@example.com")
        #expect(result.account?.credits == "9900000")
        #expect(SomeIMIntegrationStore.loadAPIKey() == "sk-test-browser-flat")
        #expect(SomeIMIntegrationStore.loadSessionToken() == "session-test-browser-flat")
    }

    @Test("browser login status preserves connected state when credentials are missing")
    @MainActor
    func testBrowserLoginStatusPreservesConnectedWhenCredentialsAreMissing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "b", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "status": "connected"
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0002",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account == nil)
        #expect(SomeIMIntegrationStore.loadAPIKey().isEmpty)
    }

    @Test("browser login reports local credential save failure separately")
    @MainActor
    func testBrowserLoginReportsCredentialSaveFailureSeparately() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        SomeIMIntegrationStore._setTestSharedSessionPersistFailure(true)
        SomeIMIntegrationStore._setTestPrivateFallbackPersistFailure(true)
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore._setTestSharedSessionPersistFailure(false)
            SomeIMIntegrationStore._setTestPrivateFallbackPersistFailure(false)
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "g", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "status": "connected",
                "api_key": "sk-test-save-failure",
                "token": "session-test-save-failure",
                "account": {
                  "email": "save-failure@example.com"
                }
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0007",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .credentialSaveFailed)
        #expect(result.account == nil)
        #expect(SomeIMIntegrationStore.loadAccount() == nil)
        #expect(SomeIMIntegrationStore.loadAPIKey().isEmpty)
    }

    @Test("browser login falls back to app keychain when shared session write fails")
    @MainActor
    func testBrowserLoginFallsBackToPrivateKeychainWhenSharedSessionWriteFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        SomeIMIntegrationStore._setTestSharedSessionPersistFailure(true)
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore._setTestSharedSessionPersistFailure(false)
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "h", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "status": "connected",
                "api_key": "sk-test-private-fallback",
                "token": "session-test-private-fallback",
                "account": {
                  "email": "fallback@example.com",
                  "tenant_id": "tenant-fallback"
                }
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0008",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account?.email == "fallback@example.com")
        #expect(SomeIMIntegrationStore.loadAPIKey() == "sk-test-private-fallback")
        #expect(SomeIMIntegrationStore.loadSessionToken() == "session-test-private-fallback")
    }

    @Test("browser login does not mark account connected without api key")
    @MainActor
    func testBrowserLoginDoesNotMarkAccountConnectedWithoutAPIKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        configureWritableSomeIMSessionStoreForTest()
        SomeIMIntegrationStore.logout()
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
            SomeIMIntegrationStore.logout()
            restoreSomeIMSessionStoreAfterTest()
        }

        let pairToken = String(repeating: "c", count: 64)
        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pairToken)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "status": "connected",
                "account": {
                  "email": "qa-no-key@example.com",
                  "credits": "4200000",
                  "defaultModel": "someim-auto-flash"
                }
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let request = SomeIMBrowserLoginRequest(
            code: "WD-TEST-0003",
            pairToken: pairToken,
            url: URL(string: "https://some.im/customer/login")!,
            createdAt: Date()
        )
        let result = try await SomeIMClient.checkBrowserLoginStatus(
            request: request,
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            session: session
        )

        #expect(result.state == .connected)
        #expect(result.account == nil)
        #expect(SomeIMIntegrationStore.loadAccount() == nil)
        #expect(SomeIMIntegrationStore.loadAPIKey().isEmpty)
    }

    @Test("coding plan subscription fetch detects active plan")
    func testCodingPlanSubscriptionFetchDetectsActivePlan() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
        }

        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.url?.host == "some.im")
            #expect(request.url?.path == "/api/v1/customer/plan/subscription")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-plan")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "code": 0,
              "data": {
                "subscription": {
                  "plan_id": "plan-pro",
                  "plan_name": "pro",
                  "plan_display_name": "Coding Pro",
                  "period_end": "2099-01-01T00:00:00Z",
                  "status": "active"
                }
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let status = try await SomeIMClient.fetchCodingPlanStatus(
            settings: SomeIMIntegrationSettings(baseURL: SomeIMRelayRegion.chinaBaseURL),
            sessionToken: "session-plan",
            session: session
        )

        #expect(status.isActiveNow)
        #expect(status.planID == "plan-pro")
        #expect(status.planName == "Coding Pro")
        #expect(status.periodEnd != nil)
    }

    @Test("coding plan subscription fetch requires a customer session")
    func testCodingPlanSubscriptionFetchRequiresCustomerSession() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        await #expect(throws: URLError.self) {
            _ = try await SomeIMClient.fetchCodingPlanStatus(
                settings: SomeIMIntegrationSettings(baseURL: SomeIMRelayRegion.chinaBaseURL),
                sessionToken: "",
                session: session
            )
        }
    }

    @Test("coding plan subscription fetch treats null subscription as no plan")
    func testCodingPlanSubscriptionFetchTreatsNullAsNoPlan() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
        }

        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/customer/plan/subscription")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"code":0,"data":{"subscription":null}}"#.data(using: .utf8)!
            return (response, body)
        }

        let status = try await SomeIMClient.fetchCodingPlanStatus(
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            sessionToken: "session-none",
            session: session
        )

        #expect(!status.isActiveNow)
        #expect(status.planID == nil)
    }

    @Test(
        "some.im relay route treats any China country probe as authoritative",
        arguments: [
            CountryProbeTestCase(someIMCountry: "CN", ipipLocation: "日本 东京", myIPLACountry: "JP", expectedBaseURL: SomeIMRelayRegion.chinaBaseURL),
            CountryProbeTestCase(someIMCountry: "US", ipipLocation: "中国 浙江 杭州", myIPLACountry: "JP", expectedBaseURL: SomeIMRelayRegion.chinaBaseURL),
            CountryProbeTestCase(someIMCountry: "US", ipipLocation: "日本 东京", myIPLACountry: "CN", expectedBaseURL: SomeIMRelayRegion.chinaBaseURL),
            CountryProbeTestCase(someIMCountry: "US", ipipLocation: "日本 东京", myIPLACountry: "JP", expectedBaseURL: SomeIMRelayRegion.internationalBaseURL)
        ]
    )
    @MainActor
    func testAutomaticRelayRouteUsesCombinedCountryProbes(testCase: CountryProbeTestCase) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SomeIMBrowserLoginMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SomeIMBrowserLoginMockURLProtocol.handler = nil
        }

        SomeIMBrowserLoginMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch request.url?.host {
            case "some.im":
                #expect(request.url?.absoluteString == "https://some.im/api/v1/public/client-location")
                let body = try JSONSerialization.data(withJSONObject: [
                    "code": 0,
                    "data": ["country": testCase.someIMCountry]
                ])
                return (response, body)
            case "myip.ipip.net":
                #expect(request.url?.path == "")
                return (response, Data("当前 IP：203.0.113.10  来自于：\(testCase.ipipLocation)".utf8))
            case "api.myip.la":
                #expect(request.url?.path == "/en")
                #expect(request.url?.query == "json")
                let body = try JSONSerialization.data(withJSONObject: [
                    "ip": "203.0.113.10",
                    "location": [
                        "country_code": testCase.myIPLACountry,
                        "country_name": testCase.myIPLACountry == "CN" ? "China" : "Japan"
                    ]
                ])
                return (response, body)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let resolvedBaseURL = try await SomeIMClient.resolveAutomaticRelayBaseURL(session: session)
        #expect(resolvedBaseURL == testCase.expectedBaseURL)
    }

    @Test("some.im video model defaults to Seedance 2.0")
    @MainActor
    func testDefaultVideoModel() {
        let settings = SomeIMIntegrationSettings(preferredVideoModel: "", preferredVideoModels: []).normalized
        #expect(settings.preferredVideoModel == "seedance-2.0")
        #expect(settings.preferredVideoModels.first == "seedance-2.0")
    }
}

struct CountryProbeTestCase: Sendable, CustomTestStringConvertible {
    let someIMCountry: String
    let ipipLocation: String
    let myIPLACountry: String
    let expectedBaseURL: String

    var testDescription: String {
        "some.im=\(someIMCountry), ipip=\(ipipLocation), myip.la=\(myIPLACountry)"
    }
}

/// The defaults suite the current test installed. The suite is `.serialized`,
/// so one slot is enough.
@MainActor private var someIMTestDefaults: (suite: UserDefaults, name: String)?

/// Gives the test its own defaults suite and an in-memory shared session.
/// `logout()` and browser login write the settings `enabled` flag and the
/// account cache; without a suite of its own a test shares them with every
/// other test in the process.
@MainActor
private func configureWritableSomeIMSessionStoreForTest() {
    let name = SomeIMIntegrationStore.xctestDefaultsSuitePrefix + UUID().uuidString
    if let suite = UserDefaults(suiteName: name) {
        someIMTestDefaults = (suite, name)
        SomeIMIntegrationStore._setTestDefaultsOverride(suite)
    }
    SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
}

@MainActor
private func restoreSomeIMSessionStoreAfterTest() {
    SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false)
    SomeIMIntegrationStore._setTestDefaultsOverride(nil)
    if let (suite, name) = someIMTestDefaults {
        TestDefaultsHygiene.cleanup(suite: suite, named: name)
        someIMTestDefaults = nil
    }
}

private final class SomeIMBrowserLoginMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
