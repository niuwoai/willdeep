//
//  AgentToolIntegrationTests.swift
//  WillDeepTests
//
//  Split from XeditTests.swift to keep the broad app test suite under the
//  repository file-size limit while keeping Agent tool regressions grouped.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentContextBuilderPromptTests {
    @Test("stable prompt discourages small Markdown tables")
    func testStablePromptDiscouragesSmallMarkdownTables() {
        let prompt = AgentContextBuilder.stableSystemPromptPrefix(toolsEnabled: true)

        #expect(prompt.contains("For small datasets (about 6 items or fewer), avoid Markdown tables"))
        #expect(prompt.contains("unless the user explicitly asks for a table"))
    }

    @Test("stable prompt requires queue inspection before optional heavy work")
    func testStablePromptRequiresQueueInspectionBeforeOptionalHeavyWork() {
        let prompt = AgentContextBuilder.stableSystemPromptPrefix(toolsEnabled: true, promptProfile: .extended)

        #expect(prompt.contains("list_queued_tasks"))
        #expect(prompt.contains("Before running expensive compile/test/archive/release/deploy commands"))
        #expect(prompt.contains("defer that heavy work unless the user explicitly asked for it now"))
    }
}

@Suite(.serialized)
struct AgentQueuedTaskToolTests {
    @Test("list_queued_tasks reports session queue and project build guard queue")
    @MainActor
    func testListQueuedTasksReportsSessionAndBuildQueues() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepQueuedTaskToolTests-\(UUID().uuidString)", isDirectory: true)
        let queueDirectory = workspace.appendingPathComponent(".codex-build/queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let buildEntry: [String: Any] = [
            "id": "queued-build-1",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "name": "xedit-tests",
            "kind": "xcode-test",
            "fingerprint": "abcdef1234567890",
            "command": ["xcodebuild", "test", "-scheme", "Xedit"],
            "created_at": Date().timeIntervalSince1970,
            "created_at_iso": ISO8601DateFormatter().string(from: Date())
        ]
        let buildData = try JSONSerialization.data(withJSONObject: buildEntry, options: [.prettyPrinted])
        try buildData.write(to: queueDirectory.appendingPathComponent("queued-build-1.json"))

        let runtimeID = UUID()
        let mediaRegistry = AgentMediaTaskRegistry(
            fileURL: workspace.appendingPathComponent("media-tasks.json", isDirectory: false)
        )
        let mediaTask = mediaRegistry.create(
            provider: .someIM,
            kind: .imageGeneration,
            title: "Queued illustration",
            runtimeID: runtimeID,
            status: .processing
        )
        let queuedMessage = AgentQueuedMessage(text: "用户后续还要继续修发布文案")
        let queuedDispatch = AgentQueuedDispatchSnapshot(
            userMessageID: UUID(),
            text: "provider slot 等待中的下一步",
            imageCount: 0,
            textAttachmentCount: 1,
            skillCount: 0,
            providerID: "some.im",
            enqueuedAt: Date().addingTimeInterval(-12)
        )
        let context = AgentToolContext(
            rootDirectory: workspace,
            runtimeID: runtimeID,
            mediaTaskRegistry: mediaRegistry,
            sessionQueueSnapshotProvider: {
                AgentSessionQueueSnapshot(
                    queuedMessages: [queuedMessage],
                    pendingDispatches: [queuedDispatch]
                )
            }
        )

        let result = try await AgentToolRunner.run(
            name: "list_queued_tasks",
            arguments: [:],
            context: context
        )

        #expect(result.summary.contains("queued user work: 1"))
        #expect(result.payload.contains("defer_heavy_actions_recommended: true"))
        #expect(result.payload.contains("用户后续还要继续修发布文案"))
        #expect(result.payload.contains("provider=some.im"))
        #expect(result.payload.contains(mediaTask.displayHandle))
        #expect(result.payload.contains("xedit-tests"))
        #expect(result.payload.contains("\"project_build_guard_queue\""))
    }

    @Test("list_workspace_sessions returns current workspace session snapshots")
    @MainActor
    func testListWorkspaceSessionsReturnsSnapshots() async throws {
        let sessionID = UUID()
        let context = AgentToolContext(
            rootDirectory: nil,
            workspaceSessionsSnapshotProvider: {
                [
                    AgentWorkspaceSessionSnapshot(
                        id: sessionID,
                        title: "修复登录流程",
                        workspaceRootPath: "/tmp/WillDeepProject",
                        workspaceDisplayName: "WillDeepProject",
                        isActive: true,
                        isPinned: true,
                        isArchived: false,
                        isResponding: false,
                        isAwaitingProviderSlot: true,
                        queuedMessageCount: 2,
                        updatedAt: Date(timeIntervalSince1970: 1_800),
                        lastActivityAt: Date(timeIntervalSince1970: 1_700),
                        interactionMode: .goal,
                        approvalMode: .smart,
                        executionAgent: .willDeep,
                        titleIsUserSet: true
                    )
                ]
            }
        )

        let result = try await AgentToolRunner.run(
            name: "list_workspace_sessions",
            arguments: [:],
            context: context
        )

        #expect(result.summary == "1 workspace session")
        #expect(result.payload.contains("修复登录流程"))
        #expect(result.payload.contains("provider-queued"))
        #expect(result.payload.contains("queued_messages=2"))
        #expect(result.payload.contains("\"interaction_mode\":\"goal\""))
    }

    @Test("suggest_session_title returns flash-backed suggestion snapshot")
    @MainActor
    func testSuggestSessionTitleReturnsSnapshot() async throws {
        let context = AgentToolContext(
            rootDirectory: nil,
            sessionTitleSuggestionProvider: {
                AgentSessionTitleSuggestionSnapshot(
                    currentTitle: "旧标题",
                    suggestedTitle: "整理发布队列",
                    modelID: "someim-auto-flash"
                )
            }
        )

        let result = try await AgentToolRunner.run(
            name: "suggest_session_title",
            arguments: [:],
            context: context
        )

        #expect(result.summary.contains("整理发布队列"))
        #expect(result.payload.contains("\"current_title\":\"旧标题\""))
        #expect(result.payload.contains("\"suggested_title\":\"整理发布队列\""))
        #expect(result.payload.contains("\"rename_recommended\":true"))
        #expect(result.payload.contains("someim-auto-flash"))
    }
}

@Suite
struct SlashCommandInteractionTests {
    @Test("slash workflow metadata distinguishes required optional and immediate commands")
    @MainActor
    func argumentModes() {
        let appState = AppState()
        let commands = SlashCommand.builtIn(state: appState)

        let research = commands.first { $0.title == "/research" }
        let bugHunt = commands.first { $0.title == "/bug-hunt" }
        let clear = commands.first { $0.title == "/clear" }

        #expect(research?.argumentMode.requiresArguments == true)
        #expect(research?.argumentMode.placeholder == "research question…")
        #expect(bugHunt?.argumentMode.acceptsArguments == true)
        #expect(bugHunt?.argumentMode.requiresArguments == false)
        #expect(clear?.argumentMode == SlashCommandArgumentMode.none)
    }

    @Test("slash invocation parser separates the exact command from its arguments")
    func invocationParsing() throws {
        let command = SlashCommand(
            id: "research",
            title: "/research",
            subtitle: "Research",
            symbol: "magnifyingglass",
            argumentMode: .required(placeholder: "question")
        ) { _ in }

        let withArguments = try #require(
            SlashCommand.invocation(in: "/research   cache behavior", commands: [command])
        )
        #expect(withArguments.command.id == "research")
        #expect(withArguments.args == "cache behavior")

        let staged = try #require(
            SlashCommand.invocation(in: "/research ", commands: [command])
        )
        #expect(staged.args.isEmpty)
        #expect(SlashCommand.invocation(in: "/researcher topic", commands: [command]) == nil)
        #expect(SlashCommand.invocation(in: "please /research topic", commands: [command]) == nil)
    }
}

@Suite(.serialized)
struct SomeIMBrowserLoginStatusTests {
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
            settings: SomeIMIntegrationSettings(baseURL: "https://some.im/v1"),
            sessionToken: "session-plan",
            session: session
        )

        #expect(status.isActiveNow)
        #expect(status.planID == "plan-pro")
        #expect(status.planName == "Coding Pro")
        #expect(status.periodEnd != nil)
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

private func configureWritableSomeIMSessionStoreForTest() {
    SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
}

private func restoreSomeIMSessionStoreAfterTest() {
    SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false)
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

extension WillDeepTests {
    // MARK: - Agent tools

    @Test("grep_files matches a regex across workspace files and respects include filter")
    @MainActor
    func testGrepFilesMatchesRegexWithInclude() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_grep_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "func alpha() {}\nlet beta = 1\n".write(
            to: workspace.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8
        )
        try "function gamma(){}\nconst delta = 1;\n".write(
            to: workspace.appendingPathComponent("sample.js"), atomically: true, encoding: .utf8
        )

        let context = AgentToolContext(rootDirectory: workspace)
        let result = try await AgentToolRunner.run(
            name: "grep_files",
            arguments: [
                "pattern": .string("^(func|function)\\s+\\w+"),
                "include": .string("*.swift")
            ],
            context: context
        )

        #expect(result.payload.contains("Sample.swift"))
        #expect(result.payload.contains("alpha"))
        #expect(!result.payload.contains("gamma"))
    }

    @Test("grep_files rejects invalid regex with a descriptive error")
    @MainActor
    func testGrepFilesRejectsInvalidRegex() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_grep_bad_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        await #expect(throws: AgentToolError.self) {
            try await AgentToolRunner.run(
                name: "grep_files",
                arguments: ["pattern": .string("[unterminated")],
                context: context
            )
        }
    }

    @Test("encodeChatRequest echoes assistant reasoning_content back to the provider")
    func testReasoningContentRoundTrip() throws {
        // Empty reasoning must not emit the key (some providers reject empty strings).
        let withoutReasoning = AgentMessage(role: .assistant, content: "Hi.")
        let dataWithout = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [withoutReasoning],
            tools: []
        )
        let jsonWithout = String(data: dataWithout, encoding: .utf8) ?? ""
        #expect(!jsonWithout.contains("reasoning_content"))

        // Non-empty reasoning MUST be present in the assistant message.
        // DashScope's thinking-mode 400's without it.
        let withReasoning = AgentMessage(
            role: .assistant,
            content: "The answer is 42.",
            reasoningContent: "I considered alternatives and concluded 42."
        )
        let dataWith = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [withReasoning],
            tools: []
        )
        let jsonWith = String(data: dataWith, encoding: .utf8) ?? ""
        #expect(jsonWith.contains("reasoning_content"))
        #expect(jsonWith.contains("I considered alternatives"))

        // The field must only attach to assistant messages — a user
        // role with reasoningContent set (shouldn't happen, but defend)
        // doesn't leak it.
        var sneakyUser = AgentMessage(role: .user, content: "hello")
        sneakyUser.reasoningContent = "secret"
        let dataUser = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [sneakyUser],
            tools: []
        )
        let jsonUser = String(data: dataUser, encoding: .utf8) ?? ""
        #expect(!jsonUser.contains("secret"))
    }

    @Test("SafeCommand classifies common read-only commands as alwaysSafe")
    func testSafeCommandAllowlist() {
        // Single safe commands.
        #expect(SafeCommand.classify(command: "cat README.md") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "head -n 50 src/main.rs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "rg \"AgentSettingsStore\" Xedit") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "ls -la") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pwd") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "wc -l Sources/*.swift") == .alwaysSafe)

        // git read-only subcommands.
        #expect(SafeCommand.classify(command: "git diff") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git log --oneline -10") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git show HEAD") == .alwaysSafe)

        // git config writes must NOT be auto-approved.
        #expect(SafeCommand.classify(command: "git config user.email rocky@example.com") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git config --add safe.directory /tmp/foo") == .needsJudgment)

        // git stash without args (writes) must NOT be auto-approved.
        #expect(SafeCommand.classify(command: "git stash") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git stash list") == .alwaysSafe)

        // Common build/dev commands are low-risk workspace operations:
        // they may write build artifacts, but should not require a manual
        // approval click in smart/goal flows.
        #expect(SafeCommand.classify(command: "go build -o bin/metaserver . 2>&1") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "go test ./...") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "go env -w GOPROXY=https://proxy.golang.org") == .needsJudgment)
        #expect(SafeCommand.classify(command: "yarn run dev") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn build") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn install") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn add pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn --registry https://registry.yarnpkg.com add pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm run build") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm install pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm install --save-dev pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm --registry https://registry.npmjs.org install pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm ci") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm install -g pptxgenjs") == .needsJudgment)
        #expect(SafeCommand.classify(command: "pnpm run typecheck") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pnpm install") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pnpm add pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm publish") == .needsJudgment)
    }

    @Test("SafeCommand: shell wrappers with harmless sentinel commands auto-approve")
    func testSafeCommandShellWrapperSentinel() {
        #expect(SafeCommand.classify(command: #"/bin/sh -lc "echo DOCKER_DONE""#) == .alwaysSafe)
        #expect(SafeCommand.classify(command: #"bash -c "printf '%s\n' DOCKER_DONE""#) == .alwaysSafe)
        #expect(SafeCommand.classify(command: #"env PATH=/usr/bin:/bin zsh -lc "echo DOCKER_DONE""#) == .alwaysSafe)

        #expect(SafeCommand.classify(command: #"bash -lc "rm -rf /tmp/build""#) == .alwaysDangerous)
        #expect(SafeCommand.classify(command: #"bash -lc "cat /etc/passwd""#) == .needsJudgment)
    }

    @Test("SafeCommand pipelines: every segment must be safe for the chain to auto-approve")
    func testSafeCommandPipelines() {
        // Two safe segments → safe.
        #expect(SafeCommand.classify(command: "git diff | head -50") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "rg foo | wc -l") == .alwaysSafe)
        // A dangerous segment poisons the whole chain.
        #expect(SafeCommand.classify(command: "git diff && rm -rf node_modules") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "cat a.txt; sudo rm /tmp/x") == .alwaysDangerous)
        // An unknown segment downgrades safe → needsJudgment.
        #expect(SafeCommand.classify(command: "cat a.txt | xargs cargo run") == .needsJudgment)
    }

    @Test("SafeCommand rejects redirections and command substitution")
    func testSafeCommandRejectsRedirectionAndSubstitution() {
        #expect(SafeCommand.classify(command: "cat foo > bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "echo $(rm -rf /)") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ls `pwd`") == .alwaysDangerous)
        // Harmless stderr redirection should still be classified as safe.
        #expect(SafeCommand.classify(command: "git status 2>/dev/null") == .alwaysSafe)
    }

    @Test("SafeCommand: shell 控制流 + whois 等只读网络命令自动放行")
    func testSafeCommandShellControlFlow() {
        // 用户实测案例：纯只读 whois 循环此前落到 LLM judge 又被拒，
        // 次次人工审批。for 头 / do 前缀 / whois / done 现在全部静态放行。
        #expect(SafeCommand.classify(
            command: "for ext in io ai app dev co net org; do echo \"=== deepcoder.$ext ===\"; whois \"deepcoder.$ext\" 2>&1 | grep -iE \"no match|not found|status\"; done"
        ) == .alwaysSafe)

        // 控制流关键字本身无负载。
        #expect(SafeCommand.classify(command: "while read line; do echo \"$line\"; done") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "if grep -q TODO a.swift; then echo found; fi") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "time git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "time rm -rf /tmp/x") == .alwaysDangerous)

        // 关键字剥掉后负载照常受走查约束——危险负载一票否决。
        #expect(SafeCommand.classify(command: "for f in a b; do rm \"$f\"; done") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "if true; then sudo reboot; fi") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "while true; do curl http://x.example; done") == .alwaysDangerous)

        // 未知负载仍然降级到 needsJudgment，不会因为有 for 头就放行。
        #expect(SafeCommand.classify(command: "for f in a b; do mycustomtool \"$f\"; done") == .needsJudgment)

        // whois 与 dig/host 同族，直接安全。
        #expect(SafeCommand.classify(command: "whois example.com") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "whois example.com 2>&1 | grep -i status") == .alwaysSafe)
    }

    @Test("SafeCommand rejects find with -delete or -exec")
    func testSafeCommandFindRules() {
        #expect(SafeCommand.classify(command: "find . -name '*.swift'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' -delete") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -name '*.log' -exec rm {} ;") == .alwaysDangerous)
    }

    // MARK: - rc3 token-level hardening

    @Test("SafeCommand: token-level rm detection catches pipeline tails")
    func testSafeCommandTokenLevelRmInPipeline() {
        // Pre-rc3 the pipeline tail `xargs rm` survived because the
        // substring needle `"rm "` only matched if `rm` had a trailing
        // space and was followed by an arg; the lowercased(+" ") trick
        // worked on segments like `rm -rf` but not on `xargs rm` where
        // `rm` was at the start of the second tokens slot.
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' | xargs rm") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' | xargs rm -rf") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -print0 | xargs -0 rm -rf") == .alwaysDangerous)
        // Same shape with `kill` — pre-rc3 needed `"kill "` to match;
        // `... | kill 1234` slipped through. Token check fixes it.
        #expect(SafeCommand.classify(command: "ps aux | grep node | awk '{print $2}' | xargs kill -9") == .alwaysDangerous)
    }

    @Test("SafeCommand: word-boundary kills 'perm'/'armchair' false positives")
    func testSafeCommandFalsePositivesGone() {
        // Pre-rc3 substring match on `"rm "` flagged `"perm "` and
        // anything else containing the literal substring. Token level
        // matching needs `rm` to be its own token.
        // (These don't reach .alwaysSafe — they're not in the allowlist —
        // but they must no longer hit the dangerous path.)
        #expect(SafeCommand.classify(command: "perm /tmp/foo") != .alwaysDangerous)
        #expect(SafeCommand.classify(command: "harmless-tool --opt val") != .alwaysDangerous)
        // Real allowlist word that visually contains "ls" but is its
        // own token must still be safe.
        #expect(SafeCommand.classify(command: "ls -la") == .alwaysSafe)
    }

    @Test("SafeCommand: cp/ln dangerous only when a flag is present")
    func testSafeCommandCpLnFlagGate() {
        // Pre-rc3 `"cp -"` substring meant `cp -r` was caught (yes) but
        // `cp src dst` was correctly NOT marked dangerous. We preserve
        // that nuance after tokenization.
        #expect(SafeCommand.classify(command: "cp -r foo bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "cp -R foo bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ln -s a b") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ln -sf a b") == .alwaysDangerous)
        // Plain forms fall through to needsJudgment (not auto-run).
        #expect(SafeCommand.classify(command: "cp foo bar") == .needsJudgment)
        #expect(SafeCommand.classify(command: "ln a b") == .needsJudgment)
    }

    @Test("SafeCommand: low-risk creation commands auto-approve")
    func testSafeCommandWorkspaceCreate() {
        // mkdir/touch/mktemp write, but only create — auto-approve so the
        // agent doesn't stall on `mkdir -p build/`.
        #expect(SafeCommand.classify(command: "mkdir build") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "mkdir -p src/a/b") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "touch README.md") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "mktemp -d") == .alwaysSafe)
        // A destructive token anywhere in the pipeline still wins.
        #expect(SafeCommand.classify(command: "mkdir foo && rm -rf bar") == .alwaysDangerous)
        // Redirection out of a creation command is still refused.
        #expect(SafeCommand.classify(command: "touch foo > /etc/passwd") == .alwaysDangerous)
    }

    @Test("SafeCommand: dangerousSubstrings cover token-less shapes")
    func testSafeCommandDangerousSubstrings() {
        // Fork bomb — no whitespace, tokenize returns one giant token,
        // substring scan catches it.
        #expect(SafeCommand.classify(command: ":(){:|:&};:") == .alwaysDangerous)
        // dd if= — the `=` glues the dangerous bit into the first token.
        #expect(SafeCommand.classify(command: "dd if=/dev/zero of=/dev/sda bs=1m") == .alwaysDangerous)
        // mkfs.* family — `mkfs.ext4`, `mkfs.hfs` etc.
        #expect(SafeCommand.classify(command: "mkfs.ext4 /dev/sda1") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "mkfs.hfs /dev/disk2") == .alwaysDangerous)
    }

    @Test("SafeCommand: `su` joins sudo/doas as privilege escalation")
    func testSafeCommandSuAddedToTokens() {
        // Added in rc3 alongside sudo/doas — equally dangerous and the
        // pre-rc3 needle list missed it.
        #expect(SafeCommand.classify(command: "su - root") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "su -c 'whoami'") == .alwaysDangerous)
    }

    @Test("SafeCommand treats cd/pushd/popd as alwaysSafe")
    func testSafeCommandCdAllowed() {
        // The common "navigate then read" chain the agent emits.
        #expect(SafeCommand.classify(command: "cd /tmp/proj && git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "cd /tmp/proj && git status --short | grep '^\\(M\\|A\\|D\\|R\\|C\\)' | head -20") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "cd ~") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pushd /tmp && ls && popd") == .alwaysSafe)
        // Command substitution must still kill the whole line — that
        // gate sits above the per-token check.
        #expect(SafeCommand.classify(command: "cd $(rm -rf /)") == .alwaysDangerous)
    }

    // MARK: - Tool call grouping

    private func makeCall(
        _ name: String,
        status: AgentToolCallStatus = .succeeded,
        arguments: [String: AgentJSONValue] = [:]
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: name,
            arguments: arguments,
            risk: .read,
            status: status
        )
    }

    @Test("AgentToolCallGrouping merges consecutive same-kind calls")
    func testToolCallGroupingMergesAdjacent() {
        let calls = [
            makeCall("run_command"),
            makeCall("run_command"),
            makeCall("run_command")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 3)
        #expect(segments[0].kind.groupTitle(3) == "已运行 3 条命令")
    }

    @Test("AgentToolCallGrouping merges visible terminal operations")
    func testToolCallGroupingMergesVisibleTerminalOperations() {
        let calls = [
            makeCall("terminal_send_command"),
            makeCall("terminal_snapshot"),
            makeCall("terminal_send_control")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .terminalOperation)
        #expect(segments[0].count == 3)
        #expect(segments[0].title == "已执行 3 次终端操作")
    }

    @Test("AgentToolCallGrouping splits when kind changes")
    func testToolCallGroupingSplitsOnKindChange() {
        let calls = [
            makeCall("run_command"),
            makeCall("read_file"),
            makeCall("grep_files"),
            makeCall("run_command")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 1)
        #expect(segments[1].kind == .fileExploration)
        #expect(segments[1].count == 2)
        #expect(segments[2].kind == .runCommand)
        #expect(segments[2].count == 1)
        #expect(segments[1].title == "已读取 1 个文件 · 已搜索代码")
    }

    @Test("AgentToolActivitySummary counts exploration searches and commands")
    func testToolActivitySummaryCountsTurnActivity() {
        let calls = [
            makeCall("read_file", arguments: ["path": .string("README.md")]),
            makeCall("read_file", arguments: ["path": .string("README.md")]),
            makeCall("list_directory", arguments: ["path": .string("Xedit")]),
            makeCall("grep_files", arguments: ["pattern": .string("Agent")]),
            makeCall("git_status"),
            makeCall("run_command", arguments: ["command": .string("git diff --stat")])
        ]

        let summary = AgentToolActivitySummary(calls: calls)

        #expect(summary.readFileCount == 1)
        #expect(summary.listedDirectoryCount == 1)
        #expect(summary.exploredPathCount == 2)
        #expect(summary.searchCount == 1)
        #expect(summary.gitStatusCount == 1)
        #expect(summary.commandCount == 1)
        #expect(summary.explorationText == "已读取 1 个文件 · 已浏览 1 个目录 · 已搜索代码 · 已查看 Git 状态")
        #expect(summary.commandText == "已运行 1 条命令")
    }

    @Test("AgentToolCallGrouping never merges ask_user even when adjacent")
    func testToolCallGroupingKeepsAskUserStandalone() {
        let calls = [
            makeCall("ask_user", status: .awaitingUserAnswer),
            makeCall("ask_user", status: .awaitingUserAnswer)
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.kind == .askUser })
        #expect(segments.allSatisfy { $0.count == 1 })
    }

    @Test("AgentToolCallGrouping treats unknown tools as their own .other kind")
    func testToolCallGroupingUnknownKindGroupsBySameName() {
        let calls = [
            makeCall("mystery_tool"),
            makeCall("mystery_tool"),
            makeCall("other_tool")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 1)
    }

    @Test("tool approval clicked before waiter registration is delivered")
    @MainActor
    func testToolApprovalClickedBeforeWaiterRegistrationIsDelivered() async throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let call = AgentToolCall(
            messageID: UUID(),
            externalID: "call-approve-before-waiter",
            toolName: "terminal_send_command",
            arguments: ["command": .string("kubectl -n tokenhub rollout status deploy/tokenhub")],
            risk: .write,
            status: .pendingApproval
        )
        appState.agentToolCalls = [call]

        appState.approveAgentToolCall(id: call.id)

        #expect(appState.hasPendingAgentToolDecision(id: call.id))
        let decision = await appState.awaitToolDecision(for: runtime, forCallID: call.id)
        if case .approved = decision {
            // Expected path.
        } else {
            Issue.record("Expected approved decision, got \(decision)")
        }
        #expect(!appState.hasPendingAgentToolDecision(id: call.id))
        #expect(runtime.toolCalls.first?.status == .running)
    }

    @Test("tool approval resumes only the matching waiter")
    @MainActor
    func testToolApprovalResumesOnlyMatchingWaiter() async throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let first = AgentToolCall(
            messageID: UUID(),
            externalID: "call-first",
            toolName: "run_command",
            arguments: ["command": .string("deploy first")],
            risk: .write,
            status: .pendingApproval
        )
        let second = AgentToolCall(
            messageID: UUID(),
            externalID: "call-second",
            toolName: "run_command",
            arguments: ["command": .string("deploy second")],
            risk: .write,
            status: .pendingApproval
        )
        appState.agentToolCalls = [first, second]

        let firstWait = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: first.id)
        }
        for _ in 0..<3 {
            await Task.yield()
        }

        #expect(runtime.toolDecisionWaiterCallID == first.id)
        appState.approveAgentToolCall(id: second.id)
        #expect(runtime.toolDecisionWaiterCallID == first.id)
        #expect(appState.hasPendingAgentToolDecision(id: second.id))

        appState.approveAgentToolCall(id: first.id)
        let firstDecision = await firstWait.value
        if case .approved = firstDecision {
            // Expected path.
        } else {
            Issue.record("Expected first call to be approved, got \(firstDecision)")
        }

        let secondDecision = await appState.awaitToolDecision(for: runtime, forCallID: second.id)
        if case .approved = secondDecision {
            // Expected path.
        } else {
            Issue.record("Expected second call to be approved, got \(secondDecision)")
        }
    }

    // MARK: - Usage stats

    private func makeSession(
        modelID: String?,
        providerID: String? = nil,
        providerDisplayName: String? = nil,
        messages: [AgentMessage]
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            title: "test",
            workspaceRootPath: nil,
            modelID: modelID,
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            createdAt: Date(),
            updatedAt: Date(),
            messages: messages
        )
    }

    private func userMessage(_ text: String, at date: Date) -> AgentMessage {
        AgentMessage(role: .user, content: text, createdAt: date)
    }

    private func assistantMessage(_ text: String, usage: Int?, at date: Date) -> AgentMessage {
        AgentMessage(role: .assistant, content: text, usageTokens: usage, createdAt: date)
    }

    private func meteredAssistantMessage(
        prompt: Int,
        completion: Int,
        cachedPrompt: Int = 0,
        cacheWritePrompt: Int = 0
    ) -> AgentMessage {
        AgentMessage(
            role: .assistant,
            content: "ok",
            usageTokens: prompt + completion,
            promptTokens: prompt,
            completionTokens: completion,
            cachedPromptTokens: cachedPrompt,
            cacheWritePromptTokens: cacheWritePrompt
        )
    }

    @Test("AgentUsageStats overview totals across sessions and prefers real usage")
    func testUsageStatsBasicTotals() {
        let now = Date()
        let calendar = Calendar.current
        let session = makeSession(modelID: "gpt-4.1", messages: [
            userMessage("hello", at: now),
            assistantMessage("hi", usage: 100, at: now),
            userMessage("hello again", at: now),
            // No real usage → fall back to chars/4 estimate (≈ 20/4 = 5)
            assistantMessage(String(repeating: "x", count: 20), usage: nil, at: now)
        ])
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.sessionCount == 1)
        #expect(stats.messageCount == 4)
        #expect(stats.hasAnyRealUsage == true)
        // 100 (real) + 5 (estimate from 20 chars) ≥ 105 plus the
        // user messages and system-prompt baseline are 0 for users
        // (estimator only on assistant in production? our estimate
        // function is applied to all messages without usage — verify).
        #expect(stats.totalTokens >= 100)
        #expect(stats.favoriteModel == "gpt-4.1")
        _ = calendar
    }

    @Test("AgentUsageStats measures persisted work ledgers and used capabilities")
    func testUsageStatsTracksWorkAndCapabilityData() {
        let now = Date()
        let toolCalls = [
            AgentMessageToolCall(externalID: "read", toolName: "read_file", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "command", toolName: "run_command", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "research", toolName: "web_search", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "image", toolName: "generate_image", argumentsJSON: "{}")
        ]
        let session = AgentSession(
            title: "dashboard work",
            workspaceRootPath: "/tmp/dashboard-work",
            createdAt: now,
            updatedAt: now,
            messages: [
                userMessage("build the dashboard", at: now),
                AgentMessage(role: .assistant, content: "working", toolCalls: toolCalls, createdAt: now),
                AgentMessage(role: .workflowReport, content: "", createdAt: now)
            ],
            agentEditedPaths: ["Xedit/AgentUsageStats.swift", "Xedit/AgentStatusIndicators.swift"],
            agentArtifactPaths: ["docs/dashboard-notes.md"]
        )

        let stats = AgentUsageStats.overview(for: [session], now: now)
        let capabilityCounts = Dictionary(
            uniqueKeysWithValues: AgentUsageStats.capabilityUsage(for: [session]).map { ($0.capability, $0.callCount) }
        )

        #expect(stats.userTurnCount == 1)
        #expect(stats.toolCallCount == 4)
        #expect(stats.editedFileCount == 2)
        #expect(stats.artifactCount == 1)
        #expect(stats.workflowCount == 1)
        #expect(stats.workspaceCount == 1)
        #expect(capabilityCounts[.workspace] == 1)
        #expect(capabilityCounts[.terminal] == 1)
        #expect(capabilityCounts[.research] == 1)
        #expect(capabilityCounts[.media] == 1)
    }

    @Test("AgentUsageStats builds this week's deliverables and explicit failure review")
    func testUsageStatsBuildsWorkbenchRows() {
        let calendar = Calendar(identifier: .gregorian)
        let now = ISO8601DateFormatter().date(from: "2026-07-13T08:00:00Z")!
        let recent = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: nil,
            providerDisplayName: nil,
            createdAt: now,
            updatedAt: now,
            messages: [
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 0,
                    toolCallNames: ["run_command"],
                    toolCallExternalIDs: ["command-1"],
                    createdAt: now
                ),
                AgentUsageMessageSnapshot(
                    role: .tool,
                    contentCharacterCount: 0,
                    toolCallID: "command-1",
                    toolCallStatus: .failed,
                    toolErrorMessage: "Command exited with status 1",
                    createdAt: now
                )
            ],
            artifactPaths: ["reports/weekly-summary.md"]
        )
        let old = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: nil,
            providerDisplayName: nil,
            createdAt: now.addingTimeInterval(-14 * 86_400),
            updatedAt: now.addingTimeInterval(-14 * 86_400),
            messages: [],
            artifactPaths: ["reports/old-summary.md"]
        )

        let deliverables = AgentUsageStats.weeklyDeliverables(for: [recent, old], now: now, calendar: calendar)
        let failures = AgentUsageStats.failedToolCallReview(for: [recent, old], now: now, calendar: calendar)

        #expect(deliverables.map(\.displayName) == ["weekly-summary.md"])
        #expect(deliverables.first?.sessionCount == 1)
        #expect(failures.count == 1)
        #expect(failures.first?.toolName == "run_command")
        #expect(failures.first?.errorSummary == "Command exited with status 1")
    }

    @Test("AgentUsageStats labels managed-routing sessions 省心托管, leaves legacy nils as unknown-model")
    func testUsageStatsManagedRoutingModelLabel() {
        let now = Date()
        func assistant(_ tokens: Int) -> AgentUsageMessageSnapshot {
            AgentUsageMessageSnapshot(
                role: .assistant,
                contentCharacterCount: 40,
                usageTokens: tokens,
                createdAt: now
            )
        }
        // Managed session: modelID is nil (cleared at persist because routing
        // is per-turn) but isManagedRouting is true → one "省心托管" row.
        let managed = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im",
            createdAt: now,
            updatedAt: now,
            messages: [assistant(100)],
            isManagedRouting: true
        )
        // Legacy session: modelID also nil, but NOT managed → must stay
        // unknown-model, never fold into 省心托管.
        let legacy = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im (Rocky's relay)",
            createdAt: now,
            updatedAt: now,
            messages: [assistant(50)],
            isManagedRouting: false
        )
        let rows = AgentUsageStats.modelUsage(for: [managed, legacy])
        let managedRow = rows.first { $0.modelID == "省心托管" }
        let unknownRow = rows.first { $0.modelID == "unknown-model" }
        #expect(managedRow != nil)
        #expect(managedRow?.messageCount == 1)
        #expect(managedRow?.providerName == "some.im")
        #expect(unknownRow != nil)
        #expect(unknownRow?.messageCount == 1)
        #expect(unknownRow?.providerName == "some.im")
    }

    @Test("AgentUsageStats current streak counts contiguous days ending today")
    func testUsageStatsCurrentStreak() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: today)!
        let oldDay = calendar.date(byAdding: .day, value: -10, to: today)!

        let messages = [
            userMessage("a", at: oldDay),
            userMessage("b", at: dayBefore),
            userMessage("c", at: yesterday),
            userMessage("d", at: today)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.activeDays == 4)
        #expect(stats.currentStreak == 3)
        #expect(stats.longestStreak == 3)
    }

    @Test("AgentUsageStats current streak preserves yesterday run when today is empty")
    func testUsageStatsCurrentStreakPreservesYesterdayRunWhenTodayEmpty() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!

        let messages = [
            userMessage("a", at: dayBefore),
            userMessage("b", at: yesterday)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.currentStreak == 2)
        #expect(stats.longestStreak == 2)
    }

    @Test("AgentUsageStats current streak is zero after missing yesterday and today")
    func testUsageStatsCurrentStreakZeroAfterGap() {
        let calendar = Calendar.current
        let now = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now))!

        let messages = [
            userMessage("a", at: threeDaysAgo),
            userMessage("b", at: twoDaysAgo)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.currentStreak == 0)
        #expect(stats.longestStreak == 2)
    }

    @Test("AgentUsageStats streaks stay all-time when dashboard range is filtered")
    func testUsageStatsStreaksIgnoreDashboardRange() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let messages = (0..<31).map { offset in
            userMessage(
                "day \(offset)",
                at: calendar.date(byAdding: .day, value: -offset, to: today)!
            )
        }
        let fullSnapshot = AgentUsageSessionSnapshot(
            session: makeSession(modelID: nil, messages: messages)
        )
        var filteredSnapshot = fullSnapshot
        filteredSnapshot.messages = fullSnapshot.messages.filter {
            $0.createdAt >= calendar.date(byAdding: .hour, value: -24, to: now)!
        }

        let stats = AgentUsageStats.overview(
            for: [filteredSnapshot],
            allTimeStreakSessions: [fullSnapshot],
            now: now
        )

        #expect(stats.activeDays <= 2)
        #expect(stats.currentStreak == 31)
        #expect(stats.longestStreak == 31)
    }

    @Test("AgentUsageStats heatmap returns weekCount × 7 cells in chronological order")
    func testUsageStatsHeatmapShape() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        let messages = [
            userMessage("a", at: today),
            userMessage("b", at: today),
            userMessage("c", at: calendar.date(byAdding: .day, value: -3, to: today)!)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let cells = AgentUsageStats.heatmap(for: [session], weekCount: 4, now: now)

        #expect(cells.count == 4)
        for column in cells { #expect(column.count == 7) }

        // Flatten to find today's cell and assert it counts 2.
        let flat = cells.flatMap { $0 }
        let todayCell = flat.first { calendar.isDate($0.date, inSameDayAs: today) }
        #expect(todayCell?.count == 2)
    }

    @Test("AgentUsageStats falls back to built-in public prices for custom GPT models")
    func testUsageStatsPublicPriceFallbackForGPTModels() {
        let session = makeSession(
            modelID: "openai/gpt-5.5",
            providerID: "custom",
            providerDisplayName: "Relay",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 200_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        #expect(row?.providerID == "custom")
        #expect(row?.modelID == "openai/gpt-5.5")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 34.1) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for DeepSeek aliases")
    func testUsageStatsPublicPriceFallbackForDeepSeekAliases() {
        let session = makeSession(
            modelID: "deepseek-chat",
            providerID: "openai-compatible",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 500_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        #expect(row?.modelID == "deepseek-chat")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 0.3514) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for Qwen models")
    func testUsageStatsPublicPriceFallbackForQwenModels() {
        let session = makeSession(
            modelID: "qwen-plus",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        #expect(row?.modelID == "qwen-plus")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 0.39) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for Kimi models")
    func testUsageStatsPublicPriceFallbackForKimiModels() {
        let session = makeSession(
            modelID: "kimi-k2.6",
            providerID: "openai-compatible",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 500_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first
        let expected = 30.8 / 7.2

        #expect(row?.modelID == "kimi-k2.6")
        #expect(abs((row?.estimatedCostUSD ?? 0) - expected) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for Moonshot V1 models")
    func testUsageStatsPublicPriceFallbackForMoonshotModels() {
        let session = makeSession(
            modelID: "moonshot-v1-8k",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first
        let expected = 12.0 / 7.2

        #expect(row?.modelID == "moonshot-v1-8k")
        #expect(abs((row?.estimatedCostUSD ?? 0) - expected) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for GLM models")
    func testUsageStatsPublicPriceFallbackForGLMModels() {
        let session = makeSession(
            modelID: "glm-4.5",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first
        let expected = 2.8 / 7.2

        #expect(row?.modelID == "glm-4.5")
        #expect(abs((row?.estimatedCostUSD ?? 0) - expected) < 0.000_001)
    }

    @Test("AgentUsageStats keeps delegated external CLI usage separate")
    func testUsageStatsSeparatesDelegatedExternalUsage() {
        let delegated = AgentMessage(
            role: .assistant,
            content: "done by codex",
            origin: .delegatedExternal,
            originLabel: "Codex"
        )
        let session = makeSession(
            modelID: "gpt-5",
            providerID: "openai",
            messages: [
                meteredAssistantMessage(prompt: 1_000, completion: 200, cachedPrompt: 500),
                delegated
            ]
        )

        let rows = AgentUsageStats.modelUsage(for: [session])
        let native = rows.first { $0.providerID == "openai" }
        let external = rows.first { $0.providerID == "delegated-external" }

        #expect(native?.messageCount == 1)
        #expect(native?.cacheHitRate == 0.5)
        #expect(external?.modelID == "Codex")
        #expect(external?.isDelegatedExternal == true)
        #expect(external?.estimatedCostUSD == nil)
    }

    @Test("AgentContextBuilder keeps a stable prefix before dynamic context")
    func testAgentContextBuilderStablePrefix() {
        let first = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project-a"),
            openedFileURL: URL(fileURLWithPath: "/tmp/project-a/A.swift"),
            fileContent: "let a = 1",
            selectedText: "",
            language: nil,
            toolsEnabled: true,
            approvalMode: .smart,
            globalRules: nil
        )
        let second = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project-b"),
            openedFileURL: URL(fileURLWithPath: "/tmp/project-b/B.swift"),
            fileContent: "let b = 2",
            selectedText: "b",
            language: nil,
            toolsEnabled: true,
            approvalMode: .requestEveryTime,
            globalRules: nil
        )
        let stable = AgentContextBuilder.stableSystemPromptPrefix(toolsEnabled: true)
        let firstDiagnostics = AgentContextBuilder.cacheDiagnostics(for: first, toolsEnabled: true)
        let secondDiagnostics = AgentContextBuilder.cacheDiagnostics(for: second, toolsEnabled: true)

        #expect(first.hasPrefix(stable))
        #expect(second.hasPrefix(stable))
        #expect(firstDiagnostics.hash == secondDiagnostics.hash)
        #expect(firstDiagnostics.stableCharacters == stable.count)
        #expect(stable.contains("Reply in Simplified Chinese."))
        #expect(stable.contains("never hardcode user-visible JSX/TSX strings"))
        #expect(stable.contains("For small datasets (about 6 items or fewer), avoid Markdown tables"))
        #expect(stable.contains("Reference code as `path/to/file.swift:42`"))
        #expect(stable.contains("batch them into one assistant turn"))
        #expect(stable.contains("Never log, echo, persist, or expose secrets"))
    }

    @Test("AgentSystemPromptProfile picks prompt size from model capability")
    func testAgentSystemPromptProfileAutoSelection() {
        #expect(AgentSystemPromptProfile.automatic(modelID: "claude-opus-4.8", providerID: "claude") == .extended)
        #expect(AgentSystemPromptProfile.automatic(modelID: "gpt-5-codex", providerID: "openai") == .extended)
        #expect(AgentSystemPromptProfile.automatic(modelID: "deepseek-v4-flash", providerID: "deepseek") == .compact)
        #expect(AgentSystemPromptProfile.automatic(modelID: "claude-sonnet-4.5", providerID: "claude") == .standard)
    }

    @Test("AgentContextBuilder collects nested project instruction files in scope order")
    func testAgentContextBuilderNestedProjectRules() throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_rules_\(UUID().uuidString)")
        let nested = workspace.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "Root overview".write(
            to: workspace.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Root agent rule".write(
            to: workspace.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Feature agent rule".write(
            to: nested.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: workspace,
            openedFileURL: nested.appendingPathComponent("View.swift"),
            fileContent: "",
            selectedText: "",
            language: nil,
            toolsEnabled: true,
            globalRules: nil
        )

        let readmeIndex = try #require(prompt.range(of: "Root overview")?.lowerBound)
        let rootRuleIndex = try #require(prompt.range(of: "Root agent rule")?.lowerBound)
        let featureRuleIndex = try #require(prompt.range(of: "Feature agent rule")?.lowerBound)
        let dynamicIndex = try #require(prompt.range(of: "=== Dynamic Turn Context ===")?.lowerBound)

        #expect(readmeIndex < rootRuleIndex)
        #expect(rootRuleIndex < featureRuleIndex)
        #expect(featureRuleIndex < dynamicIndex)
        #expect(prompt.contains("# Sources/Feature/AGENTS.md"))
    }

    @Test("long tool results are summarized before entering model context")
    func testLongToolResultsAreSummarizedForModelContext() {
        let call = AgentMessageToolCall(
            externalID: "tool-1",
            toolName: "run_command",
            argumentsJSON: "{\"command\":\"make test\"}"
        )
        let assistant = AgentMessage(role: .assistant, content: "", toolCalls: [call])
        let longOutput = String(repeating: "build log line\n", count: 400)
        let tool = AgentMessage(role: .tool, content: longOutput, toolCallID: "tool-1")
        let messages = [
            AgentMessage(role: .user, content: "run tests"),
            assistant,
            tool
        ]

        let collapsed = AppState.collapseOldToolResults(in: messages)
        let collapsedTool = collapsed.last?.content ?? ""

        #expect(collapsedTool.contains("[tool result summarized for model context]"))
        #expect(collapsedTool.contains("tool: run_command"))
        #expect(collapsedTool.contains("Full tool output remains available"))
    }

    @Test("agent tool registry escalates dangerous run_command invocations to .danger")
    func testRunCommandRiskEscalatesForDestructiveShell() {
        let benignRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("ls -la")]
        )
        let dangerousRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("rm -rf build/output")]
        )
        let forcePushRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git push --force origin main")]
        )
        let forcePushWithDirectoryRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C /Users/rocky/Sites/Xedit push --force origin main")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )

        #expect(benignRisk == .read)
        #expect(dangerousRisk == .danger)
        #expect(forcePushRisk == .danger)
        #expect(forcePushWithDirectoryRisk == .danger)
    }

    @Test("run_command classifies cd plus read-only commands as read risk")
    func testRunCommandRiskAllowsReadOnlyShellChains() {
        let gitDiffRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git diff")]
        )
        let grepRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Sources; rg \"AgentTool\" .")]
        )
        let writeAfterCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git add AgentTools.swift")]
        )
        let unsafeCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd .. && git diff")]
        )
        let redirectedReadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git diff > /tmp/out.patch")]
        )
        let harmlessRedirectionRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git status 2>/dev/null")]
        )
        let goBuildRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd /Users/rocky/Sites/Xedit && go build -o bin/metaserver . 2>&1")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let yarnDevRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("yarn run dev")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmInstallRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("npm install left-pad")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmRegistryInstallRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("npm --registry https://registry.npmjs.org install left-pad")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmGlobalInstallRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("npm install -g left-pad")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let redirectedDecision = AgentSandboxPolicy.commandDecision(
            command: "cd Xedit && git diff > /tmp/out.patch",
            rootDirectory: nil
        )
        let harmlessRedirectionDecision = AgentSandboxPolicy.commandDecision(
            command: "cd Xedit && git status 2>/dev/null",
            rootDirectory: nil
        )
        let goBuildDecision = AgentSandboxPolicy.commandDecision(
            command: "cd /Users/rocky/Sites/Xedit && go build -o bin/metaserver . 2>&1",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmInstallDecision = AgentSandboxPolicy.commandDecision(
            command: "npm install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmRegistryInstallDecision = AgentSandboxPolicy.commandDecision(
            command: "npm --registry https://registry.npmjs.org install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmGlobalInstallDecision = AgentSandboxPolicy.commandDecision(
            command: "npm install -g left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let heredocDecision = AgentSandboxPolicy.commandDecision(
            command: """
            cat > Sources/App/main.go << 'GOEOF'
            package main

            import "fmt"

            func main() {
                fmt.Println("$(literal shell-looking text in generated code)")
            }
            GOEOF
            """,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-test-workspace")
        )

        #expect(gitDiffRisk == .read)
        #expect(grepRisk == .read)
        #expect(writeAfterCDRisk == .write)
        #expect(unsafeCDRisk == .write)
        #expect(redirectedDecision.mode == .workspaceWrite)
        #expect(redirectedDecision.requiresTypedConfirmation == false)
        #expect(harmlessRedirectionDecision.mode == .readOnly)
        #expect(harmlessRedirectionDecision.requiresTypedConfirmation == false)
        #expect(heredocDecision.mode == .workspaceWrite)
        #expect(heredocDecision.requiresTypedConfirmation == false)
        #expect(redirectedReadRisk == .write)
        #expect(harmlessRedirectionRisk == .read)
        #expect(goBuildRisk == .write)
        #expect(yarnDevRisk == .write)
        #expect(npmInstallRisk == .write)
        #expect(npmRegistryInstallRisk == .write)
        #expect(npmGlobalInstallRisk == .write)
        #expect(goBuildDecision.mode == .workspaceWrite)
        #expect(goBuildDecision.requiresTypedConfirmation == false)
        #expect(npmInstallDecision.mode == .workspaceWriteNetwork)
        #expect(npmInstallDecision.requiresTypedConfirmation == false)
        #expect(npmRegistryInstallDecision.mode == .workspaceWriteNetwork)
        #expect(npmRegistryInstallDecision.requiresTypedConfirmation == false)
        #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm --registry https://registry.npmjs.org install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(npmGlobalInstallDecision.mode == .workspaceWrite)
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm install -g left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm publish",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
    }

    @Test("run_command allows workspace absolute cd for read-only commands")
    func testRunCommandRiskAllowsWorkspaceAbsoluteReadOnlyShellChains() {
        let workspace = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit").standardizedFileURL
        let sourceDirectory = workspace.appendingPathComponent("Xedit").standardizedFileURL

        let gitDiffRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd \(workspace.path) && git diff")],
            rootDirectory: workspace
        )
        let rgRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd \(sourceDirectory.path) && rg AgentTool .")],
            rootDirectory: workspace
        )
        let gitDashCRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C \(workspace.path) diff -- Xedit/AgentTools.swift")],
            rootDirectory: workspace
        )
        let outsideCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd /tmp && git diff")],
            rootDirectory: workspace
        )
        let outsideGitDashCRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C /tmp diff")],
            rootDirectory: workspace
        )
        let outsideReadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cat /etc/passwd")],
            rootDirectory: workspace
        )
        let sshTimeRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(#"ssh someuser@some-machine "time""#)],
            rootDirectory: workspace
        )
        let sshGitStatusRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(#"ssh -p 2222 someuser@some-machine "git status --short""#)],
            rootDirectory: workspace
        )
        let sshDangerRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(#"ssh someuser@some-machine "rm -rf /tmp/build""#)],
            rootDirectory: workspace
        )
        let sshInteractiveRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("ssh someuser@some-machine")],
            rootDirectory: workspace
        )
        let curlGetRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -fsSL https://example.com/install.sh")],
            rootDirectory: workspace
        )
        let curlHeadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -I https://example.com")],
            rootDirectory: workspace
        )
        let curlPostRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -X POST https://example.com/api")],
            rootDirectory: workspace
        )
        let curlOutputRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -o payload.txt https://example.com")],
            rootDirectory: workspace
        )
        let curlMetadataRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl http://169.254.169.254/latest/meta-data/")],
            rootDirectory: workspace
        )

        #expect(gitDiffRisk == .read)
        #expect(rgRisk == .read)
        #expect(gitDashCRisk == .read)
        #expect(outsideCDRisk == .write)
        #expect(outsideGitDashCRisk == .write)
        #expect(outsideReadRisk == .write)
        #expect(sshTimeRisk == .read)
        #expect(sshGitStatusRisk == .read)
        #expect(sshDangerRisk == .danger)
        #expect(sshInteractiveRisk == .write)
        #expect(curlGetRisk == .read)
        #expect(curlHeadRisk == .read)
        #expect(curlPostRisk == .write)
        #expect(curlOutputRisk == .write)
        #expect(curlMetadataRisk == .write)
    }

    @Test("run_command uses home directory when no workspace is bound")
    @MainActor
    func testRunCommandUsesHomeDirectoryWithoutWorkspace() async throws {
        let context = AgentToolContext(rootDirectory: nil)
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("pwd"),
                "timeout_seconds": .number(5)
            ],
            context: context
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(result.payload.contains(home))
    }

    @Test("run_command drains large output without hanging")
    @MainActor
    func testRunCommandDrainsLargeOutput() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_run_command_output_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        // Timeout sized for CI: the GitHub Actions macos-26 runner
        // takes ~5s to spawn ruby + write 200 KB to stdout (this test
        // failed rc5 at 5.186s against the previous 5s budget). Local
        // M-series machines finish in ~200ms so this only matters as
        // headroom. The test's intent ("doesn't hang on a full pipe")
        // is unchanged — the assertion still requires exit 0 + the
        // `[truncated]` marker; the timeout is only the upper bound
        // for "this command actually ran".
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("/usr/bin/ruby -e 'STDOUT.write(\"x\" * 200000)'"),
                "timeout_seconds": .number(30)
            ],
            context: context
        )

        #expect(result.summary.hasPrefix("exit 0"))
        #expect(result.payload.contains("[truncated]"))
    }

    @Test("run_command exposes common user binary paths")
    func testRunCommandUsesSupplementalShellPath() {
        // Originally this ran `printf '%s' "$PATH"` through run_command and
        // asserted on the output. That's flaky on CI: run_command goes through
        // `sandbox-exec`, and on the virtualized GitHub macOS runner seatbelt
        // does not reliably propagate the injected PATH to the child `/bin/sh`
        // — the test passes locally but fails in CI with an empty $PATH.
        // Assert the deterministic injection logic instead: `shellEnvironment`
        // is exactly the environment run_command hands the child process, so
        // testing it covers the same intent without depending on seatbelt's
        // env passing inside CI virtualization.
        let environment = AgentToolRunner.shellEnvironment(from: ["PATH": "/usr/bin:/bin"])
        let path = environment["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        // Pre-existing entries are preserved; supplemental dirs are appended.
        #expect(path.contains("/usr/bin"))
    }

    @Test("apply_patch queues a right-side patch proposal without writing files")
    @MainActor
    func testApplyPatchQueuesProposalWithoutWritingFiles() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_apply_patch_tool_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let diff = """
        --- a/Sample.swift
        +++ b/Sample.swift
        @@ -1 +1 @@
        -let value = 1
        +let value = 2
        """

        var queuedProposal: AgentPatchProposal?
        let context = AgentToolContext(
            rootDirectory: workspace,
            patchProposalSink: { title, diff, _ in
                let proposal = AgentPatchProposal(
                    messageID: UUID(),
                    title: title ?? "Agent Patch",
                    diff: diff
                )
                queuedProposal = proposal
                return proposal
            }
        )

        let result = try await AgentToolRunner.run(
            name: "apply_patch",
            arguments: [
                "title": .string("Update sample"),
                "diff": .string(diff)
            ],
            context: context
        )

        #expect(queuedProposal?.title == "Update sample")
        #expect(queuedProposal?.diff == diff)
        #expect(result.summary == "patch queued: 1 file")
        #expect(result.payload.contains("No files were modified"))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 1\n")
    }

    @Test("apply_patch auto-applies through existing patch applier in Goal and workspace access modes")
    @MainActor
    func testApplyPatchAutoAppliesInGoalAndWorkspaceAccessModes() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_apply_patch_auto_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Sample.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let appState = AppState(rootDirectory: workspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let proposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Auto update sample",
            diff: """
            --- a/Sample.swift
            +++ b/Sample.swift
            @@ -1 +1 @@
            -let value = 1
            +let value = 2
            """,
            autoApplySource: .goalMode
        )

        #expect(proposal.status == .applied)
        #expect(proposal.statusMessage == "Auto-applied by Goal mode")
        #expect(runtime.patchProposals.first?.status == .applied)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 2\n")

        let workspaceAccessProposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Workspace access update",
            diff: """
            --- a/Sample.swift
            +++ b/Sample.swift
            @@ -1 +1 @@
            -let value = 2
            +let value = 3
            """,
            autoApplySource: .workspaceAccess
        )

        #expect(workspaceAccessProposal.status == .applied)
        #expect(workspaceAccessProposal.statusMessage == "Auto-applied by workspace access approval")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 3\n")
    }

    @Test("apply_patch auto-applies clean tracked files but queues dirty tracked files")
    @MainActor
    func testApplyPatchAutoAppliesOnlyCleanTrackedFiles() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_apply_patch_clean_tracked_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        func runGit(_ arguments: [String]) {
            let result = AppState.runGitCommand(arguments: arguments, in: workspace)
            #expect(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        }

        runGit(["init"])
        runGit(["config", "user.email", "tests@example.invalid"])
        runGit(["config", "user.name", "WillDeep Tests"])

        let cleanURL = workspace.appendingPathComponent("Clean.swift")
        let dirtyURL = workspace.appendingPathComponent("Dirty.swift")
        try "let clean = 1\n".write(to: cleanURL, atomically: true, encoding: .utf8)
        try "let dirty = 1\n".write(to: dirtyURL, atomically: true, encoding: .utf8)
        runGit(["add", "Clean.swift", "Dirty.swift"])
        runGit(["commit", "-m", "initial"])

        let appState = AppState(rootDirectory: workspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let cleanProposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Clean tracked update",
            diff: """
            --- a/Clean.swift
            +++ b/Clean.swift
            @@ -1 +1 @@
            -let clean = 1
            +let clean = 2
            """
        )

        #expect(cleanProposal.status == .applied)
        #expect(cleanProposal.statusMessage == "Auto-applied because edited files are tracked and clean in git")
        #expect(try String(contentsOf: cleanURL, encoding: .utf8) == "let clean = 2\n")

        try "let dirty = 2\n".write(to: dirtyURL, atomically: true, encoding: .utf8)
        let dirtyProposal = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Dirty tracked update",
            diff: """
            --- a/Dirty.swift
            +++ b/Dirty.swift
            @@ -1 +1 @@
            -let dirty = 2
            +let dirty = 3
            """
        )

        #expect(dirtyProposal.status == .pending)
        #expect(dirtyProposal.statusMessage == nil)
        #expect(try String(contentsOf: dirtyURL, encoding: .utf8) == "let dirty = 2\n")
    }

    @Test("pending patch proposals auto-resolve before the next message in autonomous modes")
    @MainActor
    func testPendingPatchProposalsAutoResolveBeforeNextMessageInAutonomousModes() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_pending_patch_auto_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let goalFileURL = workspace.appendingPathComponent("Goal.swift")
        let workspaceFileURL = workspace.appendingPathComponent("Workspace.swift")
        let manualFileURL = workspace.appendingPathComponent("Manual.swift")
        try "let value = 1\n".write(to: goalFileURL, atomically: true, encoding: .utf8)
        try "let value = 1\n".write(to: workspaceFileURL, atomically: true, encoding: .utf8)
        try "let value = 1\n".write(to: manualFileURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        runtime.interactionMode = .goal
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Goal pending",
                diff: """
                --- a/Goal.swift
                +++ b/Goal.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .applied)
        #expect(runtime.patchProposals.last?.statusMessage == "Auto-applied by Goal mode")
        #expect(try String(contentsOf: goalFileURL, encoding: .utf8) == "let value = 2\n")

        runtime.interactionMode = .normal
        runtime.approvalMode = .workspaceAccess
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Workspace access pending",
                diff: """
                --- a/Workspace.swift
                +++ b/Workspace.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .applied)
        #expect(runtime.patchProposals.last?.statusMessage == "Auto-applied by workspace access approval")
        #expect(try String(contentsOf: workspaceFileURL, encoding: .utf8) == "let value = 2\n")

        runtime.approvalMode = .smart
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Manual pending",
                diff: """
                --- a/Manual.swift
                +++ b/Manual.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .rejected)
        #expect(runtime.patchProposals.last?.statusMessage == "Superseded by a newer message.")
        #expect(try String(contentsOf: manualFileURL, encoding: .utf8) == "let value = 1\n")
    }

    @Test("apply_patch is advertised in extended prompt and tool registry")
    func testApplyPatchPromptAndRegistrySurface() {
        let descriptor = AgentToolRegistry.descriptor(for: "apply_patch")
        #expect(descriptor?.risk == .read)
        #expect(descriptor?.description.contains("patch card INLINE IN THE CHAT") == true)

        let prompt = AgentContextBuilder.stableSystemPromptPrefix(
            toolsEnabled: true,
            promptProfile: .extended
        )
        #expect(prompt.contains("Extended tool capability map"))
        #expect(prompt.contains("apply_patch validates a unified diff"))
        #expect(prompt.contains("right-side review panel"))
    }

    @Test("quick open skips dependency directories")
    func testQuickOpenSkipsDependencyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_quick_open_skip_\(UUID().uuidString)", isDirectory: true)
        let nodeModules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("App.swift")
        let dependency = nodeModules.appendingPathComponent("dep.swift")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "dependency".write(to: dependency, atomically: true, encoding: .utf8)

        let urls = AppState.quickOpenFileURLs(in: tempDir)

        #expect(urls.map(\.lastPathComponent).contains("App.swift"))
        #expect(!urls.map(\.lastPathComponent).contains("dep.swift"))
    }

    @Test("folder text operations skip dependency directories")
    func testTextFileURLsSkipDependencyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_text_file_skip_\(UUID().uuidString)", isDirectory: true)
        let nodeModules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("Source.swift")
        let dependency = nodeModules.appendingPathComponent("Dependency.swift")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "dependency".write(to: dependency, atomically: true, encoding: .utf8)

        let paths = AppState.textFileURLs(in: tempDir).map(\.lastPathComponent)

        #expect(paths.contains("Source.swift"))
        #expect(!paths.contains("Dependency.swift"))
    }

    @Test("agent list_directory skips dependency directories")
    func testAgentListDirectorySkipsDependencyDirectories() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_agent_list_skip_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "source".write(to: workspace.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let result = try await AgentToolRunner.run(
            name: "list_directory",
            arguments: ["path": .string(".")],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.payload.contains("App.swift"))
        #expect(!result.payload.contains("node_modules"))
    }

}
