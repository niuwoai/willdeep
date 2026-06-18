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

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CollaborationConnectorSettingsTests.\(UUID().uuidString)")
        CollaborationConnectorSettingsStore.reset(defaults: defaults)
    }

    override func tearDown() {
        CollaborationConnectorSettingsStore.reset(defaults: defaults)
        defaults = nil
        super.tearDown()
    }

    func testDefaultSettingsIncludeKnownPlatforms() {
        let settings = CollaborationConnectorSettingsStore.load(defaults: defaults)
        let platforms = settings.connectors.map(\.platform)

        XCTAssertEqual(platforms, CollaborationConnectorPlatform.allCases)
        XCTAssertEqual(settings.connector(for: .feishu).authMode, .oauth)
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
