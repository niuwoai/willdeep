//
//  CollaborationConnectorSettingsTests.swift
//  XeditTests
//
//  Regression tests for collaboration connector settings.
//

import XCTest
@testable import WillDeep

final class CollaborationConnectorSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CollaborationConnectorSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        CollaborationConnectorSettingsStore.reset(defaults: defaults)
    }

    override func tearDown() {
        CollaborationConnectorSettingsStore.reset(defaults: defaults)
        TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultSettingsIncludeKnownPlatforms() {
        let settings = CollaborationConnectorSettingsStore.load(defaults: defaults)
        let platforms = settings.connectors.map(\.platform)

        XCTAssertEqual(platforms, CollaborationConnectorPlatform.allCases)
        XCTAssertEqual(settings.connector(for: .feishu).authMode, .officialLarkCLI)
        XCTAssertEqual(settings.connector(for: .dingtalk).authMode, .officialMCP)
        XCTAssertEqual(settings.connector(for: .wechatClaw).authMode, .desktopAutomation)
    }

    func testNormalizationBackfillsMissingPlatformsAndDropsUnsupportedCapabilities() {
        let settings = CollaborationConnectorSettings(connectors: [
            CollaborationConnectorConfig(
                platform: .wechatClaw,
                enabledCapabilities: [.createDocs, .desktopAutomation]
            )
        ]).normalized

        XCTAssertEqual(settings.connectors.count, CollaborationConnectorPlatform.allCases.count)
        XCTAssertEqual(settings.connector(for: .wechatClaw).enabledCapabilities, [.desktopAutomation])
        XCTAssertTrue(settings.connector(for: .feishu).enabledCapabilities.contains(.createDocs))
    }

    func testStorePersistsConnectorMetadata() {
        var connector = CollaborationConnectorConfig(platform: .feishu)
        connector.isEnabled = true
        connector.appID = " cli_123 "
        connector.authorizationURL = " https://example.com/oauth "
        connector.defaultChat = "oc_test"
        connector.enabledCapabilities = [.sendMessages, .createDocs]

        CollaborationConnectorSettingsStore.upsert(connector, defaults: defaults)

        let saved = CollaborationConnectorSettingsStore.load(defaults: defaults).connector(for: .feishu)
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(saved.appID, "cli_123")
        XCTAssertEqual(saved.authorizationURL, "https://example.com/oauth")
        XCTAssertEqual(saved.defaultChat, "oc_test")
        XCTAssertEqual(saved.enabledCapabilities, [.sendMessages, .createDocs])
    }

    func testPrepareAuthorizationFillsRedirectAndKeychainReference() {
        var connector = CollaborationConnectorConfig(platform: .feishu)
        connector.authMode = .oauth
        connector.appID = "cli_test"
        connector.authorizationURL = "https://example.com/oauth"

        let request = CollaborationConnectorOAuthCoordinator.prepareAuthorization(
            for: connector,
            defaults: defaults
        )

        XCTAssertEqual(request.connector.redirectURI, "https://fly.niuwoai.com/oauth/feishu/callback")
        XCTAssertEqual(
            CollaborationConnectorOAuthCoordinator.localCallbackURI(for: .feishu),
            "willdeep://oauth/feishu/callback"
        )
        XCTAssertEqual(
            request.connector.credentialReference,
            CollaborationConnectorOAuthCoordinator.credentialReference(platform: .feishu, kind: .clientSecret)
        )
        XCTAssertEqual(request.connector.connectionState, .ready)
        XCTAssertEqual(CollaborationConnectorOAuthCoordinator.pendingState(for: .feishu, defaults: defaults), request.state)
        XCTAssertEqual(request.authorizationURL?.host, "example.com")
    }

    func testPrepareAuthorizationUsesDefaultFeishuQRCodeURL() throws {
        var connector = CollaborationConnectorConfig(platform: .feishu)
        connector.authMode = .oauth
        connector.appID = " cli_test "

        let request = CollaborationConnectorOAuthCoordinator.prepareAuthorization(
            for: connector,
            defaults: defaults
        )

        let url = try XCTUnwrap(request.authorizationURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(url.host, "open.feishu.cn")
        XCTAssertEqual(url.path, "/open-apis/authen/v1/index")
        XCTAssertEqual(request.connector.authorizationURL, "https://open.feishu.cn/open-apis/authen/v1/index")
        XCTAssertEqual(queryItems["app_id"], "cli_test")
        XCTAssertNil(queryItems["client_id"])
        XCTAssertEqual(queryItems["redirect_uri"], "https://fly.niuwoai.com/oauth/feishu/callback")
        XCTAssertEqual(queryItems["state"], request.state)
    }

    func testPrepareAuthorizationUsesCloudSetupQRCodeURLWithoutAppID() throws {
        var connector = CollaborationConnectorConfig(platform: .feishu)
        connector.authMode = .oauth

        let request = CollaborationConnectorOAuthCoordinator.prepareAuthorization(
            for: connector,
            defaults: defaults
        )

        let url = try XCTUnwrap(request.authorizationURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(url.host, "fly.niuwoai.com")
        XCTAssertEqual(url.path, "/connectors/feishu/setup")
        XCTAssertEqual(request.connector.connectionState, .ready)
        XCTAssertEqual(queryItems["state"], request.state)
        XCTAssertEqual(queryItems["relay_callback"], "https://fly.niuwoai.com/oauth/feishu/callback")
        XCTAssertEqual(queryItems["desktop_callback"], "willdeep://oauth/feishu/callback")
        XCTAssertNil(queryItems["app_id"])
    }

    func testHandleOAuthCallbackRequiresPendingState() {
        var connector = CollaborationConnectorConfig(platform: .feishu)
        connector.appID = "cli_test"
        let request = CollaborationConnectorOAuthCoordinator.prepareAuthorization(
            for: connector,
            defaults: defaults
        )
        CollaborationConnectorSettingsStore.upsert(request.connector, defaults: defaults)

        let callbackURL = URL(string: "willdeep://oauth/feishu/callback?code=auth_code&state=\(request.state)")!
        XCTAssertTrue(CollaborationConnectorOAuthCoordinator.handleCallback(callbackURL, defaults: defaults))

        let saved = CollaborationConnectorSettingsStore.load(defaults: defaults).connector(for: .feishu)
        XCTAssertEqual(saved.connectionState, .needsReview)
        XCTAssertEqual(CollaborationConnectorOAuthCoordinator.pendingState(for: .feishu, defaults: defaults), "")
    }
}
